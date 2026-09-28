import AppKit
import Defaults
import ImageIO
import Sauce
import SwiftData
import Vision

@Model
class HistoryItem {
  static let maximumPinnedItems = 10

  static var supportedPins: Set<String> {
    // "a" reserved for select all
    // "q" reserved for quit
    // "v" reserved for paste
    // "w" reserved for close window
    // "z" reserved for undo/redo
    var keys = Set([
      "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l",
      "m", "n", "o", "p", "r", "s", "t", "u", "x", "y"
    ])

    if let deleteKey = KeyChord.deleteKey,
       let character = Sauce.shared.character(for: Int(deleteKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }

    if let pinKey = KeyChord.pinKey,
       let character = Sauce.shared.character(for: Int(pinKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }
    if let previewKey = KeyChord.previewKey,
       let character = Sauce.shared.character(for: Int(previewKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }

    return keys
  }

  @MainActor
  static var availablePins: [String] {
    availablePins(in: History.shared.all.compactMap {
      if $0.isPinned { return $0.item }
      return nil
    })
  }

  @MainActor
  static func availablePins(in items: [HistoryItem]) -> [String] {
    guard items.count < maximumPinnedItems else {
      return []
    }
    let assignedPins = Set(items.compactMap(\.pin))
    return Array(supportedPins.subtracting(assignedPins))
  }

  @MainActor
  static var randomAvailablePin: String { availablePins.randomElement() ?? "" }

  private static let transientTypes: [String] = [
    NSPasteboard.PasteboardType.modified.rawValue,
    NSPasteboard.PasteboardType.fromMaccy.rawValue,
    NSPasteboard.PasteboardType.linkPresentationMetadata.rawValue,
    NSPasteboard.PasteboardType.customWebKitPasteboardData.rawValue,
    NSPasteboard.PasteboardType.source.rawValue,
    NSPasteboard.PasteboardType.customChromiumWebData.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceUrl.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceToken.rawValue,
    NSPasteboard.PasteboardType.notesRichText.rawValue
  ]
  private static let imageTypes: [NSPasteboard.PasteboardType] = StorageType.images.types

  var application: String?
  var firstCopiedAt: Date = Date.now
  var lastCopiedAt: Date = Date.now
  var numberOfCopies: Int = 1
  var pin: String?
  var title = ""

  @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
  var contents: [HistoryItemContent] = []

  init(contents: [HistoryItemContent] = []) {
    self.firstCopiedAt = firstCopiedAt
    self.lastCopiedAt = lastCopiedAt
    self.contents = contents
  }

  func supersedes(_ item: HistoryItem) -> Bool {
    return item.contents
      .filter { content in
        !Self.transientTypes.contains(content.type)
      }
      .allSatisfy { content in
        contents.contains(where: { $0.hasSamePayload(as: content) })
      }
  }

  func generateTitle() -> String {
    guard !hasImage else {
      return ""
    }

    // 1k characters is trade-off for performance
    var title = previewableText
      .shortened(to: 1_000)
      .removingScalarsUnsafeForTitleLayout()

    if Defaults[.showSpecialSymbols] {
      if let range = title.range(of: "^ +", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      if let range = title.range(of: " +$", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      title = title
        .replacingOccurrences(of: "\n", with: "⏎")
        .replacingOccurrences(of: "\t", with: "⇥")
    } else {
      title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return title
  }

  var previewableText: String {
    if !fileURLs.isEmpty {
      fileURLs
        .compactMap { $0.absoluteString.removingPercentEncoding }
        .joined(separator: "\n")
    } else if let text = text, !text.isEmpty {
      text
    } else if let rtf = rtf, !rtf.string.isEmpty {
      rtf.string
    } else if let html = html, !html.string.isEmpty {
      html.string
    } else {
      title
    }
  }

  var fileURLs: [URL] {
    guard !universalClipboardText else {
      return []
    }

    return allContentData([.fileURL])
      .compactMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
  }

  var htmlData: Data? { contentData([.html]) }
  var html: NSAttributedString? {
    guard let data = htmlData else {
      return nil
    }

    return NSAttributedString(html: data, documentAttributes: nil)
  }

  var imageData: Data? {
    var data: Data?
    data = contentData(Self.imageTypes)
    if data == nil, universalClipboardImage, let url = fileURLs.first {
      data = try? Data(contentsOf: url)
    }

    return data
  }

  var hasImage: Bool { !imageContents.isEmpty || universalClipboardImage }

  var image: NSImage? {
    guard let data = imageData else {
      return nil
    }

    return NSImage(data: data)
  }

  var imagePixelSize: NSSize? {
    if let content = imageContents.first,
       let width = content.pixelWidth,
       let height = content.pixelHeight {
      return NSSize(width: width, height: height)
    }

    guard let data = imageData,
          let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
          ] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
      return nil
    }

    return NSSize(width: width, height: height)
  }

  var thumbnailImage: NSImage? {
    thumbnailImage(maximumSize: NSSize(width: 340, height: 40))
  }

  func thumbnailImage(maximumSize: NSSize) -> NSImage? {
    guard let content = imageContents.first else {
      return nil
    }

    if let identifier = content.externalPayloadIdentifier {
      let logicalSize = logicalImageSize(for: content)
      return PayloadStore.shared.thumbnail(
        identifier: identifier,
        logicalImageSize: logicalSize,
        maximumSize: maximumSize
      )
    }

    return content.data.flatMap(Self.makeThumbnailImage(from:))
  }

  func previewImage(maximumPixelSize: Int) -> NSImage? {
    guard let content = imageContents.first else {
      return nil
    }

    if let identifier = content.externalPayloadIdentifier {
      return PayloadStore.shared.previewImage(
        identifier: identifier,
        type: content.type,
        logicalImageSize: logicalImageSize(for: content),
        maximumPixelSize: maximumPixelSize
      )
    }

    guard let data = content.data,
          let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
          ] as CFDictionary),
          let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCache: false
          ] as CFDictionary) else {
      return nil
    }

    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
  }

  var rtfData: Data? { contentData([.rtf]) }
  var rtf: NSAttributedString? {
    guard let data = rtfData else {
      return nil
    }

    return NSAttributedString(rtf: data, documentAttributes: nil)
  }

  var text: String? {
    guard let data = contentData([.string]) else {
      return nil
    }

    return String(data: data, encoding: .utf8)
  }

  var modified: Int? {
    guard let data = contentData([.modified]),
          let modified = String(data: data, encoding: .utf8) else {
      return nil
    }

    return Int(modified)
  }

  var fromMaccy: Bool { contentData([.fromMaccy]) != nil }
  var universalClipboard: Bool { contentData([.universalClipboard]) != nil }

  private var universalClipboardImage: Bool { universalClipboard && fileURLs.first?.pathExtension == "jpeg" }
  private var universalClipboardText: Bool {
    universalClipboard && contentData([.html, .tiff, .png, .jpeg, .rtf, .string, .heic]) != nil
  }

  private func contentData(_ types: [NSPasteboard.PasteboardType]) -> Data? {
    let content = contents.first(where: { content in
      return types.contains(NSPasteboard.PasteboardType(content.type))
    })

    return content?.data
  }

  private func allContentData(_ types: [NSPasteboard.PasteboardType]) -> [Data] {
    return contents
      .filter { types.contains(NSPasteboard.PasteboardType($0.type)) }
      .compactMap(\.data)
  }

  @MainActor
  func recognizeTextOnDemand() async -> String {
    guard hasImage, let data = imageData else {
      return ""
    }

    let recognizedText = await Task.detached(priority: .userInitiated) {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .fast

      do {
        try VNImageRequestHandler(data: data).perform([request])
      } catch {
        return ""
      }

      let observations = request.results ?? []
      return observations
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
    }.value

    title = recognizedText
    return recognizedText
  }

  private var imageContents: [HistoryItemContent] {
    contents.filter { content in
      Self.imageTypes.contains(NSPasteboard.PasteboardType(content.type))
    }
  }

  private func logicalImageSize(for content: HistoryItemContent) -> NSSize? {
    guard let width = content.logicalWidth, let height = content.logicalHeight else {
      return nil
    }
    return NSSize(width: width, height: height)
  }

  private static func makeThumbnailImage(from data: Data) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [
      kCGImageSourceShouldCache: false
    ] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: PayloadStore.thumbnailMaximumPixelSize,
        kCGImageSourceShouldCache: false
      ] as CFDictionary) else {
      return nil
    }

    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }
}
