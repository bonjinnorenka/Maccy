import Foundation
import ImageIO
import XCTest
@testable import Maccy

final class PayloadStoreTests: XCTestCase {
  private var rootURL: URL!
  private var store: PayloadStore!

  override func setUp() {
    super.setUp()
    rootURL = FileManager.default.temporaryDirectory
      .appending(path: "MaccyPayloadStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    store = PayloadStore(rootURL: rootURL)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: rootURL)
    super.tearDown()
  }

  func testImageOriginalBytesAndThumbnailAreStoredSeparately() throws {
    let fixtureURL = Bundle(for: type(of: self)).url(forResource: "guy", withExtension: "jpeg")!
    let original = try Data(contentsOf: fixtureURL)
    let content = HistoryItemContent(type: "public.jpeg", value: original, using: store)

    XCTAssertNil(content.value)
    XCTAssertEqual(content.data(using: store), original)
    XCTAssertEqual(content.payloadByteCount, original.count)
    XCTAssertNotNil(content.externalPayloadIdentifier)

    let identifier = try XCTUnwrap(content.externalPayloadIdentifier)
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.originalURL(for: identifier, type: content.type).path))

    let source = try XCTUnwrap(CGImageSourceCreateWithURL(store.previewURL(for: identifier) as CFURL, nil))
    let thumbnail = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertLessThanOrEqual(thumbnail.width, PayloadStore.thumbnailMaximumPixelSize)
    XCTAssertLessThanOrEqual(thumbnail.height, PayloadStore.thumbnailMaximumPixelSize)
  }

  func testLargeTextAndRichTextUseExternalFiles() throws {
    let largeText = Data(String(repeating: "x", count: PayloadStore.externalPayloadThreshold).utf8)
    let text = HistoryItemContent(type: "public.utf8-plain-text", value: largeText, using: store)
    let richText = HistoryItemContent(type: "public.rtf", value: largeText, using: store)

    XCTAssertNil(text.value)
    XCTAssertNil(richText.value)
    XCTAssertEqual(text.data(using: store), largeText)
    XCTAssertEqual(richText.data(using: store), largeText)
    XCTAssertEqual(store.originalURL(for: try XCTUnwrap(text.externalPayloadIdentifier), type: text.type).pathExtension, "txt")
    XCTAssertEqual(store.originalURL(for: try XCTUnwrap(richText.externalPayloadIdentifier), type: richText.type).pathExtension, "rtf")
  }

  func testSmallTextStaysInline() {
    let text = Data("small clipboard text".utf8)
    let content = HistoryItemContent(type: "public.utf8-plain-text", value: text, using: store)

    XCTAssertNil(content.externalPayloadIdentifier)
    XCTAssertEqual(content.value, text)
    XCTAssertEqual(content.data(using: store), text)
  }

  func testMultipleImageRepresentationsArePreserved() throws {
    let tiffBytes = Data([0x49, 0x49, 0x2A, 0x00, 0x10])
    let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
    let tiff = HistoryItemContent(type: "public.tiff", value: tiffBytes, using: store)
    let png = HistoryItemContent(type: "public.png", value: pngBytes, using: store)

    XCTAssertNotEqual(tiff.externalPayloadIdentifier, png.externalPayloadIdentifier)
    XCTAssertEqual(tiff.data(using: store), tiffBytes)
    XCTAssertEqual(png.data(using: store), pngBytes)
    XCTAssertEqual(store.originalURL(for: try XCTUnwrap(tiff.externalPayloadIdentifier), type: tiff.type).pathExtension, "tiff")
    XCTAssertEqual(store.originalURL(for: try XCTUnwrap(png.externalPayloadIdentifier), type: png.type).pathExtension, "png")
  }

  func testReconciliationRemovesOnlyUnreferencedFilesAndStaleTemporaries() throws {
    let referenced = try store.store(Data("kept".utf8), type: "public.utf8-plain-text")
    let orphanIdentifier = UUID().uuidString.lowercased()
    let orphanDirectory = rootURL.appending(path: orphanIdentifier, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: false)

    let pendingDirectory = rootURL.appending(path: ".pending-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -7_200)],
      ofItemAtPath: pendingDirectory.path
    )

    let removedCount = try store.removeUnreferenced(keeping: [referenced.identifier])

    XCTAssertEqual(removedCount, 2)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: store.originalURL(for: referenced.identifier, type: "public.utf8-plain-text").deletingLastPathComponent().path
    ))
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDirectory.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDirectory.path))
  }

  func testThumbnailCacheHasEightMiBLimitAndCanBePurged() throws {
    XCTAssertEqual(PayloadStore.thumbnailCacheLimit, 8 * 1024 * 1024)

    let fixtureURL = Bundle(for: type(of: self)).url(forResource: "guy", withExtension: "jpeg")!
    let payload = try store.store(Data(contentsOf: fixtureURL), type: "public.jpeg")
    XCTAssertNotNil(store.thumbnail(identifier: payload.identifier))
    store.clearThumbnailCache()
    XCTAssertNotNil(store.thumbnail(identifier: payload.identifier))
  }
}
