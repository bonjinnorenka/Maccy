import Foundation
import CryptoKit
import SwiftData

@Model
class HistoryItemContent {
  var type: String = ""
  var value: Data?
  var externalPayloadIdentifier: String?
  var payloadByteCount: Int = 0
  var payloadDigest: Data?
  var pixelWidth: Int?
  var pixelHeight: Int?
  var logicalWidth: Double?
  var logicalHeight: Double?

  @Relationship
  var item: HistoryItem?

  init(type: String, value: Data? = nil, using store: PayloadStore = .shared) {
    self.type = type
    self.value = nil
    self.externalPayloadIdentifier = nil
    self.payloadByteCount = 0
    self.payloadDigest = nil
    self.pixelWidth = nil
    self.pixelHeight = nil
    self.logicalWidth = nil
    self.logicalHeight = nil

    guard let value else {
      return
    }

    payloadByteCount = value.count
    payloadDigest = Data(SHA256.hash(data: value))
    if store.shouldExternalize(type: type, byteCount: value.count),
       let metadata = try? store.store(value, type: type) {
      externalPayloadIdentifier = metadata.identifier
      payloadByteCount = metadata.byteCount
      payloadDigest = metadata.digest
      pixelWidth = metadata.pixelWidth
      pixelHeight = metadata.pixelHeight
      logicalWidth = metadata.logicalWidth
      logicalHeight = metadata.logicalHeight
    } else {
      self.value = value
    }
  }

  /// Returns bytes only for the duration of the caller's operation. External payloads
  /// are deliberately not memoized on this SwiftData model.
  var data: Data? {
    data(using: .shared)
  }

  func data(using store: PayloadStore) -> Data? {
    if let value {
      return value
    }
    guard let externalPayloadIdentifier else {
      return nil
    }
    return store.readOriginal(identifier: externalPayloadIdentifier, type: type)
  }

  func hasSamePayload(as other: HistoryItemContent) -> Bool {
    guard type == other.type else {
      return false
    }

    if let value, let otherValue = other.value {
      return value == otherValue
    }

    if payloadByteCount == other.payloadByteCount,
       let payloadDigest,
       let otherDigest = other.payloadDigest {
      return payloadDigest == otherDigest
    }

    return data == other.data
  }

  /// Replaces an edited payload and returns the old file identifier for cleanup after save.
  @discardableResult
  func replacePayload(with newValue: Data?, using store: PayloadStore = .shared) throws -> String? {
    let oldIdentifier = externalPayloadIdentifier
    guard let newValue else {
      value = nil
      externalPayloadIdentifier = nil
      payloadByteCount = 0
      payloadDigest = nil
      pixelWidth = nil
      pixelHeight = nil
      logicalWidth = nil
      logicalHeight = nil
      return oldIdentifier
    }

    if store.shouldExternalize(type: type, byteCount: newValue.count) {
      let metadata = try store.store(newValue, type: type)
      value = nil
      externalPayloadIdentifier = metadata.identifier
      payloadByteCount = metadata.byteCount
      payloadDigest = metadata.digest
      pixelWidth = metadata.pixelWidth
      pixelHeight = metadata.pixelHeight
      logicalWidth = metadata.logicalWidth
      logicalHeight = metadata.logicalHeight
    } else {
      value = nil
      externalPayloadIdentifier = nil
      value = newValue
      payloadByteCount = newValue.count
      payloadDigest = Data(SHA256.hash(data: newValue))
      pixelWidth = nil
      pixelHeight = nil
      logicalWidth = nil
      logicalHeight = nil
    }

    return oldIdentifier
  }
}
