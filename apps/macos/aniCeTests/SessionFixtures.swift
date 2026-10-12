// SPDX-License-Identifier: GPL-3.0-or-later
// Loads independent session fixtures and constructs shared deterministic native test engines.
import CryptoKit
import AppKit
import Foundation
import XCTest
import SwiftUI
import Observation

@testable import aniCe

struct SessionFixtures {
  func root(_ name: String = "session-vectors") throws -> [String: Any] {
    let bundleUrl = Bundle(for: SessionTests.self).url(forResource: name, withExtension: "json")
    let repoUrl = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("protocol/test-vectors")
    let candidates = [
      bundleUrl,
      repoUrl.appendingPathComponent("\(name).json"),
      repoUrl.appendingPathComponent("transfer/\(name).json"),
      repoUrl.appendingPathComponent("media/\(name).json"),
      repoUrl.appendingPathComponent("lan/\(name).json"),
    ].compactMap { $0 }
    guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
      throw SessionFailure.malformed
    }
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }
  func hex(_ text: String) throws -> Data {
    guard text.count % 2 == 0 else { throw SessionFailure.malformed }
    var bytes = Data()
    for i in stride(from: 0, to: text.count, by: 2) {
      let start = text.index(text.startIndex, offsetBy: i)
      guard let value = UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16) else {
        throw SessionFailure.malformed
      }
      bytes.append(value)
    }
    return bytes
  }
  func b(_ row: [String: Any], _ name: String) throws -> Data {
    try hex(XCTUnwrap(row[name + "Hex"] as? String))
  }
  func identity(_ row: [String: Any], _ name: String) throws -> DeviceIdentity {
    let r = try XCTUnwrap(row[name] as? [String: Any])
    let bytes = try b(r, "public")
    let json: [String: Any] = [
      "identitySchemaVersion": 1, "algorithm": "ECDSA_P256_SHA256",
      "deviceId": try XCTUnwrap(r["deviceId"] as? String), "deviceName": "Fixture",
      "platform": try XCTUnwrap(r["platform"] as? String), "publicKey": bytes.base64EncodedString(),
      "fingerprint": try XCTUnwrap(r["fingerprintHex"] as? String),
    ]
    return try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: json))
  }
  func engine(
    _ row: [String: Any], server: Bool,
    trusted: (@Sendable () async throws -> [DeviceIdentity])? = nil,
    current: (@Sendable () async throws -> DeviceIdentity)? = nil,
    signer: (@Sendable (Data) async throws -> SignedIdentityPayload)? = nil,
    selected: DeviceIdentity? = nil,
    now: @escaping @Sendable () -> TimeInterval = { 0 }
  ) throws -> SessionHandshakeEngine {
    let local = try identity(row, server ? "responder" : "initiator")
    let peer = try identity(row, server ? "initiator" : "responder")
    let stage = server ? 2 : 3
    let input = try b(row, "signingInput\(stage)")
    let signature = try SessionSignature.coseToDer(b(row, "signature\(stage)"))
    return try SessionHandshakeEngine(
      local: local, responder: server, trusted: trusted ?? { [peer] },
      currentIdentity: current ?? { local },
      signer: signer ?? { message in
        XCTAssertEqual(message, input)
        return SignedIdentityPayload(identity: local, signature: signature)
      }, selectedPeer: selected ?? (server ? nil : peer),
      ephemeral: P256.KeyAgreement.PrivateKey(rawRepresentation: b(row, server ? "y" : "x")),
      connectionId: b(row, server ? "cr" : "ci"), now: now)
  }
  func reject(_ expected: SessionFailure, _ body: () async throws -> Void) async throws {
    do {
      try await body()
      XCTFail("Expected \(expected)")
    } catch let error as SessionFailure { XCTAssertEqual(error, expected) }
  }
}
