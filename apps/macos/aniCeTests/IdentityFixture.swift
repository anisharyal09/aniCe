// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies pairing contracts, durable trust and exclusive BLE ownership across native lifecycle faults.
import CryptoKit
import Foundation
import XCTest

@testable import aniCe

final class PairingMemoryIdentity: IdentityStorage, @unchecked Sendable {
  var record: IdentityRecord?
  var keys: [String: P256.Signing.PrivateKey] = [:]
  var signatures = 0
  func loadRecord() throws -> IdentityRecord? { record }
  func saveRecord(_ record: IdentityRecord) throws { self.record = record }
  func keyTags() throws -> [String] { Array(keys.keys) }
  func key(tag: String) throws -> StoredPublicKey? {
    keys[tag].map {
      StoredPublicKey(bytes: $0.publicKey.x963Representation, protection: .keychainSoftware)
    }
  }
  func createKey(tag: String) throws -> StoredPublicKey {
    let k = P256.Signing.PrivateKey()
    keys[tag] = k
    return StoredPublicKey(bytes: k.publicKey.x963Representation, protection: .keychainSoftware)
  }
  func sign(tag: String, message: Data) throws -> Data {
    signatures += 1
    return try keys[tag]!.signature(for: message).derRepresentation
  }
  func deleteKey(tag: String) throws { keys.removeValue(forKey: tag) }
}

actor PairingBus {
  var messages: [Data] = []
  var events: [String] = []
  func send(_ data: Data) { messages.append(data) }
  func event(_ name: String) { events.append(name) }
  func take() -> [Data] {
    let result = messages
    messages.removeAll()
    return result
  }
  func names() -> [String] { events }
}