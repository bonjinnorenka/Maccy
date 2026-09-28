import Foundation
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    guard let enumerator = FileManager.default.enumerator(
      at: PayloadStore.supportDirectory,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
    ) else {
      return ""
    }

    let bytes = enumerator.compactMap { $0 as? URL }.reduce(Int64.zero) { total, fileURL in
      guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true else {
        return total
      }
      return total + Int64(values.fileSize ?? 0)
    }
    return bytes > 0 ? ByteCountFormatter().string(fromByteCount: bytes) : ""
  }

  let payloadStore = PayloadStore.shared

  private let url = PayloadStore.supportDirectory
    .appending(path: "Storage", directoryHint: .isDirectory)
    .appending(path: "Storage.sqlite")

  init() {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    } catch {
      fatalError("Cannot create storage directory: \(error.localizedDescription).")
    }

    var config = ModelConfiguration(url: url)

    #if DEBUG
    if AppDelegate.isTesting {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
    } catch let error {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }

    do {
      _ = try cleanupOrphanedContents()
      _ = try pruneHistory(
        maximumCount: 30,
        maximumPins: HistoryItem.maximumPinnedItems
      )
      _ = try reconcilePayloadFiles()
    } catch {
      // Failed removals are retried on the next launch. Payloads referenced by the
      // database are always preserved if a cleanup pass cannot complete.
    }
  }

  func cleanupOrphanedContents() throws -> Int {
    let descriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.item == nil }
    )
    let count = try context.fetchCount(descriptor)
    guard count > 0 else {
      return 0
    }

    try context.delete(
      model: HistoryItemContent.self,
      where: #Predicate { $0.item == nil }
    )
    context.processPendingChanges()
    try context.save()

    return count
  }

  func reconcilePayloadFiles() throws -> Int {
    var descriptor = FetchDescriptor<HistoryItemContent>()
    descriptor.propertiesToFetch = [\HistoryItemContent.externalPayloadIdentifier]
    let contents = try context.fetch(descriptor)
    let identifiers = Set(contents.compactMap(\.externalPayloadIdentifier))
    return try payloadStore.removeUnreferenced(keeping: identifiers)
  }

  func pruneHistory(maximumCount: Int, maximumPins: Int) throws -> Int {
    let pinLimit = min(maximumCount, maximumPins)
    var pinnedCount = try context.fetchCount(FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin != nil }
    ))

    var removedCount = 0
    while pinnedCount > pinLimit {
      var descriptor = FetchDescriptor<HistoryItem>(
        predicate: #Predicate { $0.pin != nil },
        sortBy: [SortDescriptor(\.lastCopiedAt, order: .forward)]
      )
      descriptor.fetchLimit = min(pinnedCount - pinLimit, 64)
      let victims = try context.fetch(descriptor)
      guard !victims.isEmpty else { break }
      let identifiers = delete(victims)
      context.processPendingChanges()
      try context.save()
      identifiers.forEach(payloadStore.remove(identifier:))
      pinnedCount -= victims.count
      removedCount += victims.count
    }

    var totalCount = try context.fetchCount(FetchDescriptor<HistoryItem>())
    while totalCount > maximumCount {
      let overflow = totalCount - maximumCount
      var descriptor = FetchDescriptor<HistoryItem>(
        predicate: #Predicate { $0.pin == nil },
        sortBy: [SortDescriptor(\.lastCopiedAt, order: .forward)]
      )
      descriptor.fetchLimit = min(overflow, 64)
      let victims = try context.fetch(descriptor)
      guard !victims.isEmpty else { break }
      let identifiers = delete(victims)
      context.processPendingChanges()
      try context.save()
      identifiers.forEach(payloadStore.remove(identifier:))
      totalCount -= victims.count
      removedCount += victims.count
    }

    return removedCount
  }

  private func delete(_ items: [HistoryItem]) -> Set<String> {
    var identifiers = Set<String>()
    for item in items {
      for content in item.contents {
        if let identifier = content.externalPayloadIdentifier {
          identifiers.insert(identifier)
        }
        context.delete(content)
      }
      item.contents = []
      context.delete(item)
    }
    return identifiers
  }

  // Titles stored before the sanitization in `HistoryItem.generateTitle()` may
  // contain scalars that hang CoreText on macOS 26. Such an item makes Maccy
  // spin at 100% CPU on every launch without ever drawing its window, so the
  // store has to be healed before the history is first rendered.
  // See https://github.com/p0deje/Maccy/issues/1520.
  func sanitizeTitles() throws -> Int {
    var descriptor = FetchDescriptor<HistoryItem>(
      sortBy: [SortDescriptor(\HistoryItem.lastCopiedAt, order: .reverse)]
    )
    descriptor.fetchLimit = 30
    let items = try context.fetch(descriptor)
    var count = 0

    for item in items where item.title.containsScalarsUnsafeForTitleLayout {
      item.title = item.title.removingScalarsUnsafeForTitleLayout()
      count += 1
    }

    guard count > 0 else {
      return 0
    }

    context.processPendingChanges()
    try context.save()

    return count
  }
}
