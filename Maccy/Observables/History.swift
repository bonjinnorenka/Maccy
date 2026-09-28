// swiftlint:disable file_length
import AppKit.NSRunningApplication
import Defaults
import Foundation
import Logging
import Observation
import Sauce
import Settings
import SwiftData

@Observable
class History: ItemsContainer { // swiftlint:disable:this type_body_length
  static let shared = History()
  let logger = Logger(label: "com.ryuheiyamazawa.MaccyLite")

  var items: [HistoryItemDecorator] = []
  var pasteStack: PasteStack?

  var pinnedItems: [HistoryItemDecorator] { items.filter(\.isPinned) }
  var unpinnedItems: [HistoryItemDecorator] { items.filter(\.isUnpinned) }

  var searchQuery: String = "" {
    didSet {
      throttler.throttle { [self] in
        updateItems(search.search(string: searchQuery, within: all))

        if searchQuery.isEmpty {
          AppState.shared.navigator.select(item: unpinnedItems.first)
        } else {
          AppState.shared.navigator.highlightFirst()
        }

        AppState.shared.popup.needsResize = true
      }
    }
  }

  var pressedShortcutItem: HistoryItemDecorator? {
    guard let event = NSApp.currentEvent else {
      return nil
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)

    guard HistoryItemAction(modifierFlags) != .unknown else {
      return nil
    }

    let key = Sauce.shared.key(for: Int(event.keyCode))
    return items.first { $0.shortcuts.contains(where: { $0.key == key }) }
  }

  private let search = Search()
  private let sorter = Sorter()
  private let throttler = Throttler(minimumDelay: 0.2)

  @ObservationIgnored
  private var sessionLog: [Int: HistoryItem] = [:]

  // The distinction between `all` and `items` is the following:
  // - `all` stores all history items, even the ones that are currently hidden by a search
  // - `items` stores only visible history items, updated during a search
  @ObservationIgnored
  var all: [HistoryItemDecorator] = []

  init() {
    Task {
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        updateShortcuts()
      }
    }

    Task {
      for await _ in Defaults.updates(.sortBy, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.pinTo, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.size, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        for item in items {
          await updateTitle(item: item, title: item.item.generateTitle())
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        for item in items {
          await item.cleanupImages()
        }
      }
    }
  }

  @MainActor
  func load() async throws {
    let maximumCount = effectiveHistorySize
    let maximumPins = min(HistoryItem.maximumPinnedItems, maximumCount)
    _ = try Storage.shared.pruneHistory(maximumCount: maximumCount, maximumPins: maximumPins)

    var pinnedDescriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin != nil },
      sortBy: fetchSortDescriptors
    )
    pinnedDescriptor.fetchLimit = maximumPins
    let pinned = try Storage.shared.context.fetch(pinnedDescriptor)

    var unpinnedDescriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin == nil },
      sortBy: fetchSortDescriptors
    )
    unpinnedDescriptor.fetchLimit = max(0, maximumCount - pinned.count)
    let unpinned = try Storage.shared.context.fetch(unpinnedDescriptor)
    let results = pinned + unpinned
    all = sorter.sort(results).map { HistoryItemDecorator($0) }
    items = all

    updateShortcuts()
    // Ensure that panel size is proper *after* loading all items.
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func limitHistorySize(to maxSize: Int) {
    while all.count > maxSize {
      guard let oldest = all
        .filter(\.isUnpinned)
        .min(by: { $0.item.lastCopiedAt < $1.item.lastCopiedAt })
        ?? all.min(by: { $0.item.lastCopiedAt < $1.item.lastCopiedAt }) else {
        break
      }
      delete(oldest)
    }
  }

  private var effectiveHistorySize: Int { min(max(Defaults[.size], 1), 30) }

  private var fetchSortDescriptors: [SortDescriptor<HistoryItem>] {
    switch Defaults[.sortBy] {
    case .firstCopiedAt:
      [SortDescriptor(\.firstCopiedAt, order: .reverse)]
    case .numberOfCopies:
      [SortDescriptor(\.numberOfCopies, order: .reverse)]
    case .lastCopiedAt:
      [SortDescriptor(\.lastCopiedAt, order: .reverse)]
    }
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    logger.info("Inserting a clipboard history item")
    Storage.shared.context.insert(item)
    Storage.shared.context.processPendingChanges()
    try Storage.shared.context.save()
  }

  @discardableResult
  @MainActor
  func add(_ item: HistoryItem) -> HistoryItemDecorator {
    if #available(macOS 15.0, *) {
      try? History.shared.insertIntoStorage(item)
    } else {
      // On macOS 14 the history item needs to be inserted into storage directly after creating it.
      // It was already inserted after creation in Clipboard.swift
    }

    var removedItemIndex: Int?
    if let existingHistoryItem = findSimilarItem(item) {
      let modifiedItem = isModified(item)
      var payloadIdentifiersToRemove = Set<String>()
      if modifiedItem == nil {
        payloadIdentifiersToRemove.formUnion(transferContents(from: existingHistoryItem, to: item))
      }
      item.firstCopiedAt = existingHistoryItem.firstCopiedAt
      item.numberOfCopies += existingHistoryItem.numberOfCopies
      item.pin = existingHistoryItem.pin
      item.title = existingHistoryItem.title
      if !item.fromMaccy {
        item.application = existingHistoryItem.application
      }
      logger.info("Removing duplicate clipboard history item")
      removedItemIndex = all.firstIndex(where: { $0.item == existingHistoryItem })
      if let removedItemIndex {
        cleanup(all[removedItemIndex])
      }
      payloadIdentifiersToRemove.formUnion(deleteFromStorage(existingHistoryItem))
      Storage.shared.context.processPendingChanges()
      do {
        try Storage.shared.context.save()
        payloadIdentifiersToRemove.forEach(Storage.shared.payloadStore.remove(identifier:))
      } catch {
        logger.error("Failed to save duplicate history cleanup: \(String(reflecting: error))")
      }
      if let removedItemIndex {
        all.remove(at: removedItemIndex)
      }
    } else {
      Task {
        Notifier.notify(body: item.title, sound: .write)
      }
    }

    // Remove exceeding items. Do this after the item is added to avoid removing something
    // if a duplicate was found as then the size already stayed the same.
    limitHistorySize(to: effectiveHistorySize - 1)

    sessionLog[Clipboard.shared.changeCount] = item

    var itemDecorator: HistoryItemDecorator
    if let pin = item.pin {
      itemDecorator = HistoryItemDecorator(item, shortcuts: KeyShortcut.create(character: pin))
      if let removedItemIndex {
        // If pin to bottom -> last element should be inserted to the removedItemIndex - 1
        // Or to the last all array place.
        all.insert(itemDecorator, at: min(removedItemIndex, all.count))
      }
    } else {
      itemDecorator = HistoryItemDecorator(item)

      let sortedItems = sorter.sort(all.map(\.item) + [item])
      if let index = sortedItems.firstIndex(of: item) {
        all.insert(itemDecorator, at: index)
      }

      items = all
      updateUnpinnedShortcuts()
      AppState.shared.popup.needsResize = true
    }

    return itemDecorator
  }

  @MainActor
  private func withLogging(_ msg: String, _ block: () throws -> Void) rethrows {
    func dataCounts() -> String {
      let historyItemCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>())
      let historyContentCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItemContent>())
      return "HistoryItem=\(historyItemCount ?? 0) HistoryItemContent=\(historyContentCount ?? 0)"
    }

    logger.info("\(msg) Before: \(dataCounts())")
    try? block()
    logger.info("\(msg) After: \(dataCounts())")
  }

  @MainActor
  func clear() {
    withLogging("Clearing history") {
      let unpinnedItems = all.filter(\.isUnpinned)
      let identifiers = Set(unpinnedItems.flatMap { $0.item.contents.compactMap(\.externalPayloadIdentifier) })
      all.forEach { item in
        if item.isUnpinned {
          cleanup(item)
        }
      }
      all.removeAll(where: \.isUnpinned)
      sessionLog.removeValues { $0.pin == nil }
      items = all

      do {
        try Storage.shared.context.transaction {
          try Storage.shared.context.delete(
            model: HistoryItem.self,
            where: #Predicate { $0.pin == nil }
          )
          try Storage.shared.context.delete(
            model: HistoryItemContent.self,
            where: #Predicate { $0.item?.pin == nil }
          )
        }
        Storage.shared.context.processPendingChanges()
        try Storage.shared.context.save()
        identifiers.forEach(Storage.shared.payloadStore.remove(identifier:))
        _ = try Storage.shared.reconcilePayloadFiles()
      } catch {
        logger.error("Failed to clear unpinned history: \(String(reflecting: error))")
      }
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func clearAll() {
    withLogging("Clearing all history") {
      all.forEach { item in
        cleanup(item)
      }
      all.removeAll()
      sessionLog.removeAll()
      items = all

      do {
        let context = Storage.shared.context
        try context.transaction {
          // Bulk deletion cannot remove children with live inverse relationships.
          try context.delete(
            model: HistoryItemContent.self,
            where: #Predicate { $0.item == nil }
          )
          try context.delete(model: HistoryItem.self)
          try context.delete(model: HistoryItemContent.self)
        }
        context.processPendingChanges()
        try context.save()
        _ = try Storage.shared.reconcilePayloadFiles()
      } catch {
        logger.error("Failed to clear storage: \(String(reflecting: error))")
      }
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func delete(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    cleanup(item)
    var payloadIdentifiers = Set<String>()
    withLogging("Removing history item") {
      payloadIdentifiers = deleteFromStorage(item.item)
      Storage.shared.context.processPendingChanges()
      do {
        try Storage.shared.context.save()
        payloadIdentifiers.forEach(Storage.shared.payloadStore.remove(identifier:))
      } catch {
        logger.error("Failed to save history item deletion: \(String(reflecting: error))")
      }
    }

    all.removeAll { $0 == item }
    items.removeAll { $0 == item }
    sessionLog.removeValues { $0 == item.item }

    updateUnpinnedShortcuts()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func transferContents(from existingItem: HistoryItem, to newItem: HistoryItem) -> Set<String> {
    let discardedIdentifiers = deleteContents(of: newItem)
    newItem.contents = existingItem.contents
    existingItem.contents = []
    return discardedIdentifiers
  }

  @MainActor
  private func deleteFromStorage(_ item: HistoryItem) -> Set<String> {
    let identifiers = deleteContents(of: item)
    Storage.shared.context.delete(item)
    return identifiers
  }

  @MainActor
  private func deleteContents(of item: HistoryItem) -> Set<String> {
    let contents = item.contents
    item.contents = []
    contents.forEach(Storage.shared.context.delete)
    return Set(contents.compactMap(\.externalPayloadIdentifier))
  }

  @MainActor
  private func cleanup(_ item: HistoryItemDecorator) {
    item.cleanupImages()
  }

  @MainActor
  func select(_ item: HistoryItemDecorator?, flags modifierFlags: NSEvent.ModifierFlags) {
    guard let item else {
      return
    }

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      if Defaults[.pasteByDefault] {
        Clipboard.shared.paste()
      }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  @MainActor
  func startPasteStack(selection: inout Selection<HistoryItemDecorator>, flags modifierFlags: NSEvent.ModifierFlags) {
    guard AppState.shared.multiSelectionEnabled else { return }
    guard let item = selection.first else { return }
    PasteStack.initializeIfNeeded()

    let stack = PasteStack(items: selection.items, modifierFlags: modifierFlags)
    pasteStack = stack

    logger.info("Initialising PasteStack with \(stack.items.count) items")
    logger.info("Copying the selected clipboard item from PasteStack")

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  func handlePasteStack() {
    guard let stack = pasteStack else {
      return
    }

    guard !stack.items.isEmpty else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("PasteStack pasted one clipboard item")

    stack.items.removeFirst()

    guard let item = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("Copying the next clipboard item from PasteStack; \(stack.items.count) items remain")

    Task {
      if stack.modifierFlags.isEmpty {
        await Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      } else {
        switch HistoryItemAction(stack.modifierFlags) {
        case .copy:
          await Clipboard.shared.copy(item.item)
        case .paste:
          await Clipboard.shared.copy(item.item)
        case .pasteWithoutFormatting:
          await Clipboard.shared.copy(item.item, removeFormatting: true)
        case .unknown:
          return
        }
      }
    }
  }

  func interruptPasteStack() {
    guard pasteStack != nil else {
      return
    }
    logger.info("Interrupting PasteStack")
    pasteStack = nil
  }

  @MainActor
  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }
    if item.isUnpinned && pinnedItems.count >= HistoryItem.maximumPinnedItems {
      return
    }

    item.togglePin()

    let sortedItems = sorter.sort(all.map(\.item))
    if let currentIndex = all.firstIndex(of: item),
       let newIndex = sortedItems.firstIndex(of: item.item) {
      all.remove(at: currentIndex)
      all.insert(item, at: newIndex)
    }

    items = all

    searchQuery = ""
    updateUnpinnedShortcuts()
    if item.isUnpinned {
      AppState.shared.navigator.scrollTarget = item.id
    }
  }

  @MainActor
  private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    if let duplicate = all.first(where: { $0.item != item && $0.item.supersedes(item) }) {
      return duplicate.item
    }

    return isModified(item)
  }

  private func isModified(_ item: HistoryItem) -> HistoryItem? {
    if let modified = item.modified, sessionLog.keys.contains(modified) {
      return sessionLog[modified]
    }

    return nil
  }

  private func updateItems(_ newItems: [Search.SearchResult]) {
    items = newItems.map { result in
      let item = result.object
      item.highlight(searchQuery, result.ranges)

      return item
    }

    updateUnpinnedShortcuts()
  }

  private func updateShortcuts() {
    for item in pinnedItems {
      if let pin = item.item.pin {
        item.shortcuts = KeyShortcut.create(character: pin)
      }
    }

    updateUnpinnedShortcuts()
  }

  @MainActor
  private func updateTitle(item: HistoryItemDecorator, title: String) {
    item.title = title
    item.item.title = title
  }

  private func updateUnpinnedShortcuts() {
    let visibleUnpinnedItems = unpinnedItems.filter(\.isVisible)
    for item in visibleUnpinnedItems {
      item.shortcuts = []
    }

    var index = 1
    for item in visibleUnpinnedItems.prefix(9) {
      item.shortcuts = KeyShortcut.create(character: String(index))
      index += 1
    }
  }
}
