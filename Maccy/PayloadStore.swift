import AppKit
import CryptoKit
import Foundation
import ImageIO

struct PayloadMetadata {
  let identifier: String
  let byteCount: Int
  let digest: Data
  let pixelWidth: Int?
  let pixelHeight: Int?
  let logicalWidth: Double?
  let logicalHeight: Double?
}

/// Stores payload bytes outside SwiftData and keeps only decoded, small thumbnails in memory.
final class PayloadStore {
  static let thumbnailCacheLimit = 8 * 1024 * 1024
  static let thumbnailMaximumPixelSize = 256
  static let externalPayloadThreshold = 64 * 1024

  static let shared = PayloadStore(rootURL: defaultRootURL)

  static var supportDirectory: URL {
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.ryuheiyamazawa.MaccyLite"
    return URL.applicationSupportDirectory.appending(path: bundleIdentifier, directoryHint: .isDirectory)
  }

  static var defaultRootURL: URL {
    supportDirectory.appending(path: "Payloads", directoryHint: .isDirectory)
  }

  static let imageTypes: Set<String> = [
    "public.tiff", "public.png", "public.jpeg", "public.heic"
  ]

  let rootURL: URL

  private let cache = NSCache<NSString, NSImage>()
  private let memoryPressureSource: DispatchSourceMemoryPressure

  init(rootURL: URL) {
    self.rootURL = rootURL
    cache.totalCostLimit = Self.thumbnailCacheLimit

    let pressureSource = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical],
      queue: .main
    )
    pressureSource.setEventHandler { [weak cache] in
      cache?.removeAllObjects()
    }
    pressureSource.resume()
    memoryPressureSource = pressureSource
  }

  func shouldExternalize(type: String, byteCount: Int) -> Bool {
    Self.imageTypes.contains(type) || byteCount >= Self.externalPayloadThreshold
  }

  func store(_ data: Data, type: String) throws -> PayloadMetadata {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

    let identifier = UUID().uuidString.lowercased()
    let temporaryURL = rootURL.appending(path: ".pending-\(identifier)", directoryHint: .isDirectory)
    let finalURL = directoryURL(for: identifier)
    try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: false)

    do {
      let originalURL = temporaryURL.appending(path: "original.\(Self.fileExtension(for: type))")
      try data.write(to: originalURL, options: .atomic)

      var pixelWidth: Int?
      var pixelHeight: Int?
      var logicalWidth: Double?
      var logicalHeight: Double?
      if Self.imageTypes.contains(type),
         let source = CGImageSourceCreateWithData(data as CFData, [
           kCGImageSourceShouldCache: false
         ] as CFDictionary) {
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
          pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
          pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
          let dpiX = max(1, (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72)
          let dpiY = max(1, (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? dpiX)
          logicalWidth = pixelWidth.map { Double($0) * 72 / dpiX }
          logicalHeight = pixelHeight.map { Double($0) * 72 / dpiY }
        }

        if let thumbnail = Self.makeThumbnail(from: source) {
          try Self.writePNG(thumbnail, to: temporaryURL.appending(path: "preview.png"))
        }
      }

      // Moving a completed directory within Payloads publishes the original and
      // preview together. Startup recovery ignores pending directories that are
      // still being written and removes abandoned ones after they become stale.
      try fileManager.moveItem(at: temporaryURL, to: finalURL)

      return PayloadMetadata(
        identifier: identifier,
        byteCount: data.count,
        digest: Data(SHA256.hash(data: data)),
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        logicalWidth: logicalWidth,
        logicalHeight: logicalHeight
      )
    } catch {
      try? fileManager.removeItem(at: temporaryURL)
      throw error
    }
  }

  func readOriginal(identifier: String, type: String) -> Data? {
    try? Data(contentsOf: originalURL(for: identifier, type: type), options: .mappedIfSafe)
  }

  func originalURL(for identifier: String, type: String) -> URL {
    directoryURL(for: identifier).appending(path: "original.\(Self.fileExtension(for: type))")
  }

  func previewURL(for identifier: String) -> URL {
    directoryURL(for: identifier).appending(path: "preview.png")
  }

  func thumbnail(
    identifier: String,
    logicalImageSize: NSSize? = nil,
    maximumSize: NSSize = NSSize(width: 340, height: 40)
  ) -> NSImage? {
    let key = "\(identifier):\(Int(maximumSize.width))x\(Int(maximumSize.height))" as NSString
    if let image = cache.object(forKey: key) {
      return image
    }

    let url = previewURL(for: identifier)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [
      kCGImageSourceShouldCache: false
    ] as CFDictionary),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
        kCGImageSourceShouldCacheImmediately: true
      ] as CFDictionary) else {
      return nil
    }

    let naturalSize = logicalImageSize ?? NSSize(width: cgImage.width, height: cgImage.height)
    let ratio = min(maximumSize.width / naturalSize.width, maximumSize.height / naturalSize.height, 1)
    let displaySize = NSSize(
      width: naturalSize.width * ratio,
      height: naturalSize.height * ratio
    )
    let image = NSImage(cgImage: cgImage, size: displaySize)
    let cost = cgImage.bytesPerRow * cgImage.height
    cache.setObject(image, forKey: key, cost: cost)
    return image
  }

  func previewImage(
    identifier: String,
    type: String,
    logicalImageSize: NSSize?,
    maximumPixelSize: Int
  ) -> NSImage? {
    let url = originalURL(for: identifier, type: type)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [
      kCGImageSourceShouldCache: false
    ] as CFDictionary),
      let cgImage = Self.makeThumbnail(from: source, maximumPixelSize: max(1, maximumPixelSize)) else {
      return nil
    }

    return NSImage(
      cgImage: cgImage,
      size: logicalImageSize ?? NSSize(width: cgImage.width, height: cgImage.height)
    )
  }

  func remove(identifier: String) {
    // Keys also include the requested display size, so removing by identifier
    // requires purging the bounded thumbnail cache as a whole.
    cache.removeAllObjects()
    try? FileManager.default.removeItem(at: directoryURL(for: identifier))
  }

  func clearThumbnailCache() {
    cache.removeAllObjects()
  }

  /// Deletes only completed payload directories that the database no longer references.
  /// Pending directories are retained until they are at least one hour old.
  func removeUnreferenced(keeping identifiers: Set<String>, now: Date = .now) throws -> Int {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: rootURL.path) else {
      return 0
    }

    let urls = try fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
    )
    var removedCount = 0

    for url in urls {
      let name = url.lastPathComponent
      if name.hasPrefix(".pending-") {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        if let modified = values?.contentModificationDate,
           now.timeIntervalSince(modified) > 60 * 60 {
          try fileManager.removeItem(at: url)
          removedCount += 1
        }
        continue
      }

      guard UUID(uuidString: name) != nil, !identifiers.contains(name) else {
        continue
      }

      try fileManager.removeItem(at: url)
      removedCount += 1
    }

    clearThumbnailCache()
    return removedCount
  }

  private func directoryURL(for identifier: String) -> URL {
    rootURL.appending(path: identifier, directoryHint: .isDirectory)
  }

  private static func fileExtension(for type: String) -> String {
    switch type {
    case "public.tiff": "tiff"
    case "public.png": "png"
    case "public.jpeg": "jpeg"
    case "public.heic": "heic"
    case "public.html": "html"
    case "public.rtf": "rtf"
    case "public.utf8-plain-text": "txt"
    default: "bin"
    }
  }

  private static func makeThumbnail(
    from source: CGImageSource,
    maximumPixelSize: Int = thumbnailMaximumPixelSize
  ) -> CGImage? {
    CGImageSourceCreateThumbnailAtIndex(source, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
      kCGImageSourceShouldCache: false
    ] as CFDictionary)
  }

  private static func writePNG(_ image: CGImage, to url: URL) throws {
    let temporaryURL = url.appendingPathExtension("tmp")
    guard let destination = CGImageDestinationCreateWithURL(
      temporaryURL as CFURL,
      "public.png" as CFString,
      1,
      nil
    ) else {
      throw CocoaError(.fileWriteUnknown)
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: url)
  }
}
