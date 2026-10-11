// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies native session security and presentation readiness against fixtures and adversarial transitions.
import CryptoKit
import AppKit
import Foundation
import XCTest
import SwiftUI
import Observation

@testable import aniCe

final class SessionTests: XCTestCase, @unchecked Sendable {
  private let helper = SessionFixtures()
  func testFreshReconnectNeverReusesHandshakeOrExporter() async throws {
    let row = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    let i = try helper.identity(row, "initiator"), r = try helper.identity(row, "responder")
    func fresh(_ server: Bool) throws -> SessionHandshakeEngine {
      let local = server ? r : i, peer = server ? i : r
      let key = try P256.Signing.PrivateKey(rawRepresentation:
        helper.b(XCTUnwrap(row[server ? "responder" : "initiator"] as? [String: Any]), "private"))
      return try SessionHandshakeEngine(local: local, responder: server, trusted: { [peer] },
        currentIdentity: { local }, signer: {
          SignedIdentityPayload(identity: local, signature: try key.signature(for: $0).derRepresentation)
        }, selectedPeer: server ? nil : peer)
    }
    var messages = [Data](), exports = [Data](), keys = [Data](), ivs = [Data]()
    for _ in 0..<3 {
      let c = try fresh(false), s = try fresh(true)
      let m1 = try await c.initiate(), m2 = try await s.respond(m1)
      let m3 = try await c.authenticateResponder(m2), m4 = try await s.authenticateInitiator(m3)
      try await c.confirmResponder(m4)
      let context = try helper.b(row, "exportContext-session-id-0")
      let exported = try await c.export(context: context, length: 32)
      let remote = try await s.export(context: context, length: 32)
      XCTAssertEqual(exported, remote)
      XCTAssertFalse(messages.contains(m1)); XCTAssertFalse(exports.contains(exported))
      messages.append(m1); exports.append(exported)
      keys.append(try await c.export(context: helper.b(row, "exportContext-key-1"), length: 32))
      ivs.append(try await c.export(context: helper.b(row, "exportContext-iv-1"), length: 12))
      await c.close(); await s.close()
      try await helper.reject(.cancelled) { _ = try await c.export(context: Data(), length: 32) }
    }
    XCTAssertEqual(exports.count, 3)
    for index in 0..<3 {
      let record = try SessionRecordCodec.seal(key: keys[index], iv: ivs[index], id: exports[index],
        direction: 1, kind: .data, sequence: 0, plaintext: Data([42]))
      XCTAssertEqual(try SessionRecordCodec.open(key: keys[index], iv: ivs[index], id: exports[index],
        direction: 1, expected: 0, record: record).1, Data([42]))
      for other in 0..<3 where other != index {
        XCTAssertNotEqual(keys[index], keys[other])
        XCTAssertThrowsError(try SessionRecordCodec.open(key: keys[other], iv: ivs[other],
          id: exports[other], direction: 1, expected: 0, record: record)) {
          XCTAssertEqual($0 as? SessionFailure, .authentication)
        }
      }
    }
  }
  func testCompleteOracleHandshakesAndExporter() async throws {
    let fixtures = try helper.root()
    let rows = try XCTUnwrap(fixtures["valid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(rows.count, 3)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(fixtures["invalid"] as? [[String: Any]]).count, 15)
    for v in rows {
      let c = try helper.engine(v, server: false)
      let s = try helper.engine(v, server: true)
      XCTAssertEqual(
        try helper.b(v, "credentialI"),
        try SessionCbor.encode(SessionCrypto.credential(helper.identity(v, "initiator"))))
      XCTAssertEqual(
        try helper.b(v, "credentialR"),
        try SessionCbor.encode(SessionCrypto.credential(helper.identity(v, "responder"))))
      let m1 = try await c.initiate()
      XCTAssertEqual(m1, try helper.b(v, "message1"))
      let m2 = try await s.respond(m1)
      XCTAssertEqual(m2, try helper.b(v, "message2"))
      let m3 = try await c.authenticateResponder(m2)
      XCTAssertEqual(m3, try helper.b(v, "message3"))
      try await helper.reject(.state) {
        _ = try await self.helper.engine(v, server: false).export(context: Data(), length: 32)
      }
      let m4 = try await s.authenticateInitiator(m3)
      XCTAssertEqual(m4, try helper.b(v, "message4"))
      try await c.confirmResponder(m4)
      let cs = await c.stage
      let ss = await s.stage
      XCTAssertEqual(cs, .complete)
      XCTAssertEqual(ss, .complete)
      for (purpose, direction, length) in [
        ("key", 1, 32), ("key", 2, 32), ("iv", 1, 12), ("iv", 2, 12), ("session-id", 0, 32),
      ] {
        let context = try helper.b(v, "exportContext-\(purpose)-\(direction)")
        let ck = try await c.export(context: context, length: length)
        let sk = try await s.export(context: context, length: length)
        XCTAssertEqual(ck, try helper.b(v, "export-\(purpose)-\(direction)"))
        XCTAssertEqual(sk, ck)
      }
      await c.close()
      await s.close()
      try await helper.reject(.cancelled) { _ = try await c.export(context: Data(), length: 32) }
    }
  }
  func testEveryNegativeFixtureFailsClosed() async throws {
    let fixtures = try helper.root()
    let v = try XCTUnwrap((fixtures["valid"] as? [[String: Any]])?.first)
    let rows = try XCTUnwrap(fixtures["invalid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(rows.count, 15)
    for row in rows {
      let stage = try XCTUnwrap(row["stage"] as? Int)
      let expected = try XCTUnwrap(
        SessionFailure(rawValue: try XCTUnwrap(row["reason"] as? String)))
      let e = try helper.engine(v, server: stage == 1 || stage == 3)
      switch stage {
      case 2: _ = try await e.initiate()
      case 3: _ = try await e.respond(helper.b(v, "message1"))
      case 4:
        _ = try await e.initiate()
        _ = try await e.authenticateResponder(helper.b(v, "message2"))
      default: break
      }
      let wire = try helper.b(row, "wire")
      try await helper.reject(expected) {
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
      try await helper.reject(.cancelled) { _ = try await e.export(context: Data(), length: 32) }
    }
  }
  func testPublishedRfcComponents() throws {
    let v = try helper.root("rfc9529-components")
    XCTAssertEqual(
      try helper.b(v, "th2"),
      try SessionCrypto.hash(
        SessionCbor.sequence(.bytes(helper.b(v, "gy")), .bytes(SessionCrypto.hash(helper.b(v, "message1"))))))
    XCTAssertEqual(try helper.b(v, "prk"), try SessionCrypto.extract(helper.b(v, "th2"), helper.b(v, "z")))
    XCTAssertEqual(try helper.b(v, "mac2"), try SessionCrypto.kdf(helper.b(v, "prk"), 2, helper.b(v, "context2"), 32))
    XCTAssertEqual(
      try helper.b(v, "keystream2"),
      try SessionCrypto.kdf(helper.b(v, "prk"), 0, helper.b(v, "th2"), helper.b(v, "plaintext2").count))
    XCTAssertEqual(
      try helper.b(v, "th3"),
      try SessionCrypto.hash(
        SessionCbor.encode(.bytes(helper.b(v, "th2"))) + helper.b(v, "plaintext2") + helper.b(v, "credentialR")))
    XCTAssertEqual(
      try helper.b(v, "th4"),
      try SessionCrypto.hash(
        SessionCbor.encode(.bytes(helper.b(v, "th3"))) + helper.b(v, "plaintext3") + helper.b(v, "credentialI")))
    XCTAssertEqual(try helper.b(v, "prkOut"), try SessionCrypto.kdf(helper.b(v, "prk"), 7, helper.b(v, "th4"), 32))
    XCTAssertEqual(try helper.b(v, "prkExporter"), try SessionCrypto.kdf(helper.b(v, "prkOut"), 10, Data(), 32))
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
      XCTAssertThrowsError(try SessionCbor.decode(helper.hex(text))) {
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
    XCTAssertEqual(try SessionCbor.encode(map), try helper.hex("a202f408f5"))
    XCTAssertThrowsError(
      try SessionCbor.encode(
        .map([.init(.bytes(Data([1])), .bool(true)), .init(.bytes(Data([1])), .bool(false))])))
  }
  func testSignatureRangeAndPadding() throws {
    let order = try helper.hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
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
      XCTAssertThrowsError(try SessionSignature.derToCose(helper.hex(der))) {
        XCTAssertEqual($0 as? SessionFailure, .malformed)
      }
    }
  }
  func testTrustAndLifecycleFailures() async throws {
    let v = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    let peer = try helper.identity(v, "responder")
    let trust = SessionTestState(peers: [peer])
    let c = try helper.engine(v, server: false, trusted: { trust.peers() })
    _ = try await c.initiate()
    _ = try await c.authenticateResponder(helper.b(v, "message2"))
    trust.setPeers([])
    try await helper.reject(.untrustedPeer) { try await c.confirmResponder(self.helper.b(v, "message4")) }
    try await helper.reject(.untrustedPeer) {
      _ = try await self.helper.engine(v, server: false, trusted: { [peer, peer] }).initiate()
    }
    let wrong = try helper.identity(try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?[1]), "responder")
    try await helper.reject(.untrustedPeer) {
      _ = try await self.helper.engine(v, server: false, trusted: { [wrong] }).initiate()
    }
    let clock = SessionTestState(peers: [])
    let timed = try helper.engine(v, server: false, now: { clock.now() })
    _ = try await timed.initiate()
    clock.setNow(30)
    try await helper.reject(.expired) { try await timed.checkDeadline() }
    let replay = try helper.engine(v, server: false)
    _ = try await replay.initiate()
    _ = try await replay.authenticateResponder(helper.b(v, "message2"))
    try await helper.reject(.state) { _ = try await replay.authenticateResponder(self.helper.b(v, "message2")) }
  }
  func testResponderSelectionRejectsOtherTrustedPeersAndAmbiguity() async throws {
    let rows = try XCTUnwrap(helper.root()["valid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(rows.count, 3)
    let v = rows[0]
    let selected = try helper.identity(v, "initiator")
    let other = try helper.identity(rows[1], "initiator")
    XCTAssertNotEqual(selected.fingerprint, other.fingerprint)
    let accepted = try helper.engine(v, server: true, selected: selected)
    _ = try await accepted.respond(helper.b(v, "message1"))
    _ = try await accepted.authenticateInitiator(helper.b(v, "message3"))
    let authenticated = try await accepted.authenticatedPeer()
    XCTAssertEqual(authenticated.deviceId, selected.deviceId)
    XCTAssertEqual(authenticated.fingerprint, selected.fingerprint)
    let acceptedStage = await accepted.stage
    XCTAssertEqual(acceptedStage, .complete)
    await accepted.close()
    try await helper.reject(.cancelled) { _ = try await accepted.authenticatedPeer() }
    let wrong = try helper.engine(v, server: true, trusted: { [selected, other] }, selected: other)
    _ = try await wrong.respond(helper.b(v, "message1"))
    try await helper.reject(.untrustedPeer) {
      _ = try await wrong.authenticateInitiator(self.helper.b(v, "message3"))
    }
    let wrongStage = await wrong.stage
    XCTAssertEqual(wrongStage, .closed)
    let ambiguous = try helper.engine(
      v, server: true, trusted: { [selected, selected] }, selected: selected)
    _ = try await ambiguous.respond(helper.b(v, "message1"))
    try await helper.reject(.untrustedPeer) {
      _ = try await ambiguous.authenticateInitiator(self.helper.b(v, "message3"))
    }
    let revokedTrust = SessionTestState(peers: [selected])
    let revoked = try helper.engine(v, server: true, trusted: { revokedTrust.peers() }, selected: selected)
    _ = try await revoked.respond(helper.b(v, "message1"))
    _ = try await revoked.authenticateInitiator(helper.b(v, "message3"))
    revokedTrust.setPeers([])
    try await helper.reject(.untrustedPeer) { try await revoked.checkDeadline() }
  }
  func testCancellationDuringSigning() async throws {
    let v = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    let local = try helper.identity(v, "responder")
    let signature = try SessionSignature.coseToDer(helper.b(v, "signature2"))
    let gate = SessionSigningGate()
    let e = try helper.engine(
      v, server: true,
      signer: { _ in
        await gate.delay()
        return SignedIdentityPayload(identity: local, signature: signature)
      })
    let m1 = try helper.b(v, "message1")
    let task = Task { try await self.helper.reject(.cancelled) { _ = try await e.respond(m1) } }
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
      XCTAssertThrowsError(try SessionError.validate(helper.hex(wire)))
    }
    let v = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    let e = try helper.engine(v, server: false)
    _ = try await e.initiate()
    try await helper.reject(.authentication) { try await e.receiveError(SessionError.generic()) }
    let state = await e.stage
    XCTAssertEqual(state, .closed)
  }
  func testSigningDenialAndIdentityReplacementAreTerminal() async throws {
    let v = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    for server in [true, false] {
      let denied = try helper.engine(v, server: server, signer: { _ in throw IdentityError.accessDenied })
      do {
        if server {
          _ = try await denied.respond(helper.b(v, "message1"))
        } else {
          _ = try await denied.initiate()
          _ = try await denied.authenticateResponder(helper.b(v, "message2"))
        }
        XCTFail("Signing denial was ignored")
      } catch let error as IdentityError { XCTAssertEqual(error, .accessDenied) }
      let state = await denied.stage
      XCTAssertEqual(state, .closed)
      try await helper.reject(.cancelled) { _ = try await denied.export(context: Data(), length: 32) }
    }
    let replacement = try helper.identity(
      try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?[1]), "responder")
    let signature = try SessionSignature.coseToDer(helper.b(v, "signature2"))
    let replaced = try helper.engine(
      v, server: true,
      signer: { _ in
        SignedIdentityPayload(identity: replacement, signature: signature)
      })
    try await helper.reject(.cancelled) { _ = try await replaced.respond(self.helper.b(v, "message1")) }
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

/// Runs the packaged loader from the signed hosted app without sending valid playback commands.
