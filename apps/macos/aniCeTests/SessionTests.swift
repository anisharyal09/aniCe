// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import XCTest

@testable import aniCe

final class SessionTests: XCTestCase, @unchecked Sendable {
  func root(_ name: String = "session-vectors") throws -> [String: Any] {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
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
  func testFreshReconnectNeverReusesHandshakeOrExporter() async throws {
    let row = try XCTUnwrap((root()["valid"] as? [[String: Any]])?.first)
    let i = try identity(row, "initiator"), r = try identity(row, "responder")
    func fresh(_ server: Bool) throws -> SessionHandshakeEngine {
      let local = server ? r : i, peer = server ? i : r
      let key = try P256.Signing.PrivateKey(rawRepresentation:
        b(XCTUnwrap(row[server ? "responder" : "initiator"] as? [String: Any]), "private"))
      return try SessionHandshakeEngine(local: local, responder: server, trusted: { [peer] },
        currentIdentity: { local }, signer: {
          SignedIdentityPayload(identity: local, signature: try key.signature(for: $0).derRepresentation)
        }, selectedPeer: server ? nil : peer)
    }
    var messages = [Data](), exports = [Data]()
    for _ in 0..<3 {
      let c = try fresh(false), s = try fresh(true)
      let m1 = try await c.initiate(), m2 = try await s.respond(m1)
      let m3 = try await c.authenticateResponder(m2), m4 = try await s.authenticateInitiator(m3)
      try await c.confirmResponder(m4)
      let context = try b(row, "exportContext-session-id-0")
      let exported = try await c.export(context: context, length: 32)
      let remote = try await s.export(context: context, length: 32)
      XCTAssertEqual(exported, remote)
      XCTAssertFalse(messages.contains(m1)); XCTAssertFalse(exports.contains(exported))
      messages.append(m1); exports.append(exported)
      await c.close(); await s.close()
      try await reject(.cancelled) { _ = try await c.export(context: Data(), length: 32) }
    }
    XCTAssertEqual(exports.count, 3)
  }
  func testCompleteOracleHandshakesAndExporter() async throws {
    let fixtures = try root()
    let rows = try XCTUnwrap(fixtures["valid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(rows.count, 3)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(fixtures["invalid"] as? [[String: Any]]).count, 15)
    for v in rows {
      let c = try engine(v, server: false)
      let s = try engine(v, server: true)
      XCTAssertEqual(
        try b(v, "credentialI"),
        try SessionCbor.encode(SessionCrypto.credential(identity(v, "initiator"))))
      XCTAssertEqual(
        try b(v, "credentialR"),
        try SessionCbor.encode(SessionCrypto.credential(identity(v, "responder"))))
      let m1 = try await c.initiate()
      XCTAssertEqual(m1, try b(v, "message1"))
      let m2 = try await s.respond(m1)
      XCTAssertEqual(m2, try b(v, "message2"))
      let m3 = try await c.authenticateResponder(m2)
      XCTAssertEqual(m3, try b(v, "message3"))
      try await reject(.state) {
        _ = try await self.engine(v, server: false).export(context: Data(), length: 32)
      }
      let m4 = try await s.authenticateInitiator(m3)
      XCTAssertEqual(m4, try b(v, "message4"))
      try await c.confirmResponder(m4)
      let cs = await c.stage
      let ss = await s.stage
      XCTAssertEqual(cs, .complete)
      XCTAssertEqual(ss, .complete)
      for (purpose, direction, length) in [
        ("key", 1, 32), ("key", 2, 32), ("iv", 1, 12), ("iv", 2, 12), ("session-id", 0, 32),
      ] {
        let context = try b(v, "exportContext-\(purpose)-\(direction)")
        let ck = try await c.export(context: context, length: length)
        let sk = try await s.export(context: context, length: length)
        XCTAssertEqual(ck, try b(v, "export-\(purpose)-\(direction)"))
        XCTAssertEqual(sk, ck)
      }
      await c.close()
      await s.close()
      try await reject(.cancelled) { _ = try await c.export(context: Data(), length: 32) }
    }
  }
  func testEveryNegativeFixtureFailsClosed() async throws {
    let fixtures = try root()
    let v = try XCTUnwrap((fixtures["valid"] as? [[String: Any]])?.first)
    let rows = try XCTUnwrap(fixtures["invalid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(rows.count, 15)
    for row in rows {
      let stage = try XCTUnwrap(row["stage"] as? Int)
      let expected = try XCTUnwrap(
        SessionFailure(rawValue: try XCTUnwrap(row["reason"] as? String)))
      let e = try engine(v, server: stage == 1 || stage == 3)
      switch stage {
      case 2: _ = try await e.initiate()
      case 3: _ = try await e.respond(b(v, "message1"))
      case 4:
        _ = try await e.initiate()
        _ = try await e.authenticateResponder(b(v, "message2"))
      default: break
      }
      let wire = try b(row, "wire")
      try await reject(expected) {
        switch stage {
        case 1: _ = try await e.respond(wire)
        case 2: _ = try await e.authenticateResponder(wire)
        case 3: _ = try await e.authenticateInitiator(wire)
        case 4: try await e.confirmResponder(wire)
        default: XCTFail("Invalid fixture stage")
        }
      }
      let state = await e.stage
      XCTAssertEqual(state, .closed, row["name"] as? String ?? "")
      try await reject(.cancelled) { _ = try await e.export(context: Data(), length: 32) }
    }
  }
  func testPublishedRfcComponents() throws {
    let v = try root("rfc9529-components")
    XCTAssertEqual(
      try b(v, "th2"),
      try SessionCrypto.hash(
        SessionCbor.sequence(.bytes(b(v, "gy")), .bytes(SessionCrypto.hash(b(v, "message1"))))))
    XCTAssertEqual(try b(v, "prk"), try SessionCrypto.extract(b(v, "th2"), b(v, "z")))
    XCTAssertEqual(try b(v, "mac2"), try SessionCrypto.kdf(b(v, "prk"), 2, b(v, "context2"), 32))
    XCTAssertEqual(
      try b(v, "keystream2"),
      try SessionCrypto.kdf(b(v, "prk"), 0, b(v, "th2"), b(v, "plaintext2").count))
    XCTAssertEqual(
      try b(v, "th3"),
      try SessionCrypto.hash(
        SessionCbor.encode(.bytes(b(v, "th2"))) + b(v, "plaintext2") + b(v, "credentialR")))
    XCTAssertEqual(
      try b(v, "th4"),
      try SessionCrypto.hash(
        SessionCbor.encode(.bytes(b(v, "th3"))) + b(v, "plaintext3") + b(v, "credentialI")))
    XCTAssertEqual(try b(v, "prkOut"), try SessionCrypto.kdf(b(v, "prk"), 7, b(v, "th4"), 32))
    XCTAssertEqual(try b(v, "prkExporter"), try SessionCrypto.kdf(b(v, "prkOut"), 10, Data(), 32))
  }
  func testCBORCanonicalEncodingAndBounds() throws {
    for v in [
      SessionCBOR.text("Identity 🔒"), .bool(true), .bool(false), .integer(Int64.min),
      .integer(Int64.max),
    ] {
      XCTAssertEqual(v, try SessionCbor.decode(SessionCbor.encode(v)))
    }
    let data = try SessionCbor.encode(.bytes(Data(count: 4093)))
    XCTAssertEqual(data.count, 4096)
    XCTAssertEqual(try SessionCbor.decode(data), .bytes(Data(count: 4093)))
    for text in [
      "1800", "1bffffffffffffffff", "5f40ff", "a201000100", "a202000100", "61ff", "f6", "d840",
      "8201", "a1180100", "0000", "580100",
    ] {
      XCTAssertThrowsError(try SessionCbor.decode(hex(text))) {
        XCTAssertEqual($0 as? SessionFailure, .malformed)
      }
    }
    XCTAssertThrowsError(try SessionCbor.encode(.bytes(Data(count: 4094))))
    XCTAssertThrowsError(try SessionCbor.decode(Data(count: 4097)))
    XCTAssertEqual(try SessionCbor.decodeSequence(Data(count: 512)).count, 512)
    var nested = SessionCBOR.integer(0)
    for _ in 0..<8 { nested = .array([nested]) }
    XCTAssertEqual(nested, try SessionCbor.decode(SessionCbor.encode(nested)))
    XCTAssertThrowsError(try SessionCbor.decode(Data(repeating: 0x81, count: 9) + Data([0])))
    XCTAssertThrowsError(try SessionCbor.decodeSequence(Data(count: 513)))
    let map = SessionCBOR.map([.init(.integer(8), .bool(true)), .init(.integer(2), .bool(false))])
    XCTAssertEqual(try SessionCbor.encode(map), try hex("a202f408f5"))
    XCTAssertThrowsError(
      try SessionCbor.encode(
        .map([.init(.bytes(Data([1])), .bool(true)), .init(.bytes(Data([1])), .bool(false))])))
  }
  func testSignatureRangeAndPadding() throws {
    let order = try hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
    for scalar in [
      Data(count: 31) + Data([1]), Data([0x80]) + Data(count: 31),
      Data([0]) + Data(repeating: 0x7f, count: 31),
      order.dropLast() + Data([0x50]),
    ] {
      XCTAssertEqual(
        try SessionSignature.derToCose(SessionSignature.coseToDer(scalar + scalar)), scalar + scalar
      )
    }
    for raw in [
      Data(count: 64), order + Data(count: 31) + Data([1]),
      Data(repeating: 0xff, count: 32) + Data(count: 31) + Data([1]),
      Data(count: 63), Data(count: 65),
    ] {
      XCTAssertThrowsError(try SessionSignature.coseToDer(raw)) {
        XCTAssertEqual($0 as? SessionFailure, .malformed)
      }
    }
    for der in [
      "3006020100020101", "300702020001020101", "3006020180020101", "300602010102010100",
      "308106020101020101",
    ] {
      XCTAssertThrowsError(try SessionSignature.derToCose(hex(der))) {
        XCTAssertEqual($0 as? SessionFailure, .malformed)
      }
    }
  }
  func testTrustAndLifecycleFailures() async throws {
    let v = try XCTUnwrap((root()["valid"] as? [[String: Any]])?.first)
    let peer = try identity(v, "responder")
    let trust = SessionTestState(peers: [peer])
    let c = try engine(v, server: false, trusted: { trust.peers() })
    _ = try await c.initiate()
    _ = try await c.authenticateResponder(b(v, "message2"))
    trust.setPeers([])
    try await reject(.untrustedPeer) { try await c.confirmResponder(self.b(v, "message4")) }
    try await reject(.untrustedPeer) {
      _ = try await self.engine(v, server: false, trusted: { [peer, peer] }).initiate()
    }
    let wrong = try identity(try XCTUnwrap((root()["valid"] as? [[String: Any]])?[1]), "responder")
    try await reject(.untrustedPeer) {
      _ = try await self.engine(v, server: false, trusted: { [wrong] }).initiate()
    }
    let clock = SessionTestState(peers: [])
    let timed = try engine(v, server: false, now: { clock.now() })
    _ = try await timed.initiate()
    clock.setNow(30)
    try await reject(.expired) { try await timed.checkDeadline() }
    let replay = try engine(v, server: false)
    _ = try await replay.initiate()
    _ = try await replay.authenticateResponder(b(v, "message2"))
    try await reject(.state) { _ = try await replay.authenticateResponder(self.b(v, "message2")) }
  }
  func testResponderSelectionRejectsOtherTrustedPeersAndAmbiguity() async throws {
    let rows = try XCTUnwrap(root()["valid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(rows.count, 3)
    let v = rows[0]
    let selected = try identity(v, "initiator")
    let other = try identity(rows[1], "initiator")
    XCTAssertNotEqual(selected.fingerprint, other.fingerprint)
    let accepted = try engine(v, server: true, selected: selected)
    _ = try await accepted.respond(b(v, "message1"))
    _ = try await accepted.authenticateInitiator(b(v, "message3"))
    let authenticated = try await accepted.authenticatedPeer()
    XCTAssertEqual(authenticated.deviceId, selected.deviceId)
    XCTAssertEqual(authenticated.fingerprint, selected.fingerprint)
    let acceptedStage = await accepted.stage
    XCTAssertEqual(acceptedStage, .complete)
    await accepted.close()
    try await reject(.cancelled) { _ = try await accepted.authenticatedPeer() }
    let wrong = try engine(v, server: true, trusted: { [selected, other] }, selected: other)
    _ = try await wrong.respond(b(v, "message1"))
    try await reject(.untrustedPeer) {
      _ = try await wrong.authenticateInitiator(self.b(v, "message3"))
    }
    let wrongStage = await wrong.stage
    XCTAssertEqual(wrongStage, .closed)
    let ambiguous = try engine(
      v, server: true, trusted: { [selected, selected] }, selected: selected)
    _ = try await ambiguous.respond(b(v, "message1"))
    try await reject(.untrustedPeer) {
      _ = try await ambiguous.authenticateInitiator(self.b(v, "message3"))
    }
    let revokedTrust = SessionTestState(peers: [selected])
    let revoked = try engine(v, server: true, trusted: { revokedTrust.peers() }, selected: selected)
    _ = try await revoked.respond(b(v, "message1"))
    _ = try await revoked.authenticateInitiator(b(v, "message3"))
    revokedTrust.setPeers([])
    try await reject(.untrustedPeer) { try await revoked.checkDeadline() }
  }
  func testCancellationDuringSigning() async throws {
    let v = try XCTUnwrap((root()["valid"] as? [[String: Any]])?.first)
    let local = try identity(v, "responder")
    let signature = try SessionSignature.coseToDer(b(v, "signature2"))
    let gate = SessionSigningGate()
    let e = try engine(
      v, server: true,
      signer: { _ in
        await gate.delay()
        return SignedIdentityPayload(identity: local, signature: signature)
      })
    let m1 = try b(v, "message1")
    let task = Task { try await self.reject(.cancelled) { _ = try await e.respond(m1) } }
    await gate.waitEntered()
    await e.close()
    await gate.release()
    try await task.value
    let state = await e.stage
    XCTAssertEqual(state, .closed)
  }
  func testBoundedFatalErrors() async throws {
    try SessionError.validate(SessionError.generic())
    try SessionError.validate(SessionCbor.sequence(.integer(3), .bool(true)))
    try SessionError.validate(SessionCbor.sequence(.integer(2), .integer(5)))
    for wire in ["0000", "03f4", "0202", "01f5", "03f500"] {
      XCTAssertThrowsError(try SessionError.validate(hex(wire)))
    }
    let v = try XCTUnwrap((root()["valid"] as? [[String: Any]])?.first)
    let e = try engine(v, server: false)
    _ = try await e.initiate()
    try await reject(.authentication) { try await e.receiveError(SessionError.generic()) }
    let state = await e.stage
    XCTAssertEqual(state, .closed)
  }
  func testSigningDenialAndIdentityReplacementAreTerminal() async throws {
    let v = try XCTUnwrap((root()["valid"] as? [[String: Any]])?.first)
    for server in [true, false] {
      let denied = try engine(v, server: server, signer: { _ in throw IdentityError.accessDenied })
      do {
        if server {
          _ = try await denied.respond(b(v, "message1"))
        } else {
          _ = try await denied.initiate()
          _ = try await denied.authenticateResponder(b(v, "message2"))
        }
        XCTFail("Signing denial was ignored")
      } catch let error as IdentityError { XCTAssertEqual(error, .accessDenied) }
      let state = await denied.stage
      XCTAssertEqual(state, .closed)
      try await reject(.cancelled) { _ = try await denied.export(context: Data(), length: 32) }
    }
    let replacement = try identity(
      try XCTUnwrap((root()["valid"] as? [[String: Any]])?[1]), "responder")
    let signature = try SessionSignature.coseToDer(b(v, "signature2"))
    let replaced = try engine(
      v, server: true,
      signer: { _ in
        SignedIdentityPayload(identity: replacement, signature: signature)
      })
    try await reject(.cancelled) { _ = try await replaced.respond(self.b(v, "message1")) }
    let state = await replaced.stage
    XCTAssertEqual(state, .closed)
  }
}

private final class SessionTestState: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [DeviceIdentity]
  private var time: TimeInterval = 0
  init(peers: [DeviceIdentity]) { values = peers }
  func peers() -> [DeviceIdentity] { lock.withLock { values } }
  func setPeers(_ peers: [DeviceIdentity]) { lock.withLock { values = peers } }
  func now() -> TimeInterval { lock.withLock { time } }
  func setNow(_ now: TimeInterval) { lock.withLock { time = now } }
}
private actor SessionSigningGate {
  private var entered = false
  private var enterWaiter: CheckedContinuation<Void, Never>?
  private var releaseWaiter: CheckedContinuation<Void, Never>?
  func delay() async {
    entered = true
    enterWaiter?.resume()
    enterWaiter = nil
    await withCheckedContinuation { releaseWaiter = $0 }
  }
  func waitEntered() async { if !entered { await withCheckedContinuation { enterWaiter = $0 } } }
  func release() {
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}
