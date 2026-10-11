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
  @MainActor func testNavigationDeepLinkUpdatesContextBeforePresentationAndRetainsItAcrossTabs() {
    let navigation = ConnectionNavigation()
    XCTAssertEqual(navigation.destination, .home)
    navigation.destination = .settings
    navigation.details = true
    navigation.diagnostics = false
    var presentations = 0
    navigation.open(.devices, peer: "phone-a") {
      presentations += 1
      XCTAssertEqual(navigation.destination, .devices)
      XCTAssertEqual(navigation.focusedPeer, "phone-a")
      XCTAssertEqual(navigation.deviceRoute, .overview)
    }
    navigation.show(.settings)
    XCTAssertEqual(navigation.settingsRoute, .overview)
    navigation.settingsRoute = .identity
    navigation.show(.devices)
    navigation.show(.settings)
    XCTAssertEqual(navigation.settingsRoute, .identity)
    navigation.settingsRoute = .overview
    navigation.show(.devices)
    XCTAssertEqual(navigation.focusedPeer, "phone-a")
    XCTAssertTrue(navigation.details)
    XCTAssertFalse(navigation.diagnostics)
    navigation.open(.devices, route: .pairing) {
      presentations += 1
      XCTAssertEqual(navigation.deviceRoute, .pairing)
    }
    XCTAssertEqual(presentations, 2)
  }

  func testWindowAppearanceResolvesForcedAndSystemColors() {
    XCTAssertEqual(WindowAppearance.allCases.count, 3)
    for system in [ColorScheme.light, .dark] {
      XCTAssertEqual(WindowAppearance.light.colorScheme(system: system), .light)
      XCTAssertEqual(WindowAppearance.dark.colorScheme(system: system), .dark)
      XCTAssertEqual(WindowAppearance.system.colorScheme(system: system), system)
      XCTAssertEqual(WindowAppearance.stored("invalid").colorScheme(system: system), system)
    }
  }

  @MainActor func testSystemColorsFollowApplicationWhileWindowIsForced() async {
    let application = NSApplication.shared
    let previous = application.appearance
    defer { application.appearance = previous }
    application.appearance = NSAppearance(named: .darkAqua)
    let system = SystemAppearance(application: application)
    let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    window.appearance = NSAppearance(named: .aqua)
    XCTAssertEqual(system.colorScheme, .dark)
    XCTAssertEqual(WindowAppearance.light.colorScheme(system: system.colorScheme), .light)
    XCTAssertEqual(window.appearance?.name, .aqua)
    XCTAssertEqual(WindowAppearance.system.colorScheme(system: system.colorScheme), .dark)

    let changed = expectation(description: "System appearance updates SwiftUI colors")
    withObservationTracking { _ = system.colorScheme } onChange: { changed.fulfill() }
    application.appearance = NSAppearance(named: .aqua)
    await fulfillment(of: [changed], timeout: 2)
    XCTAssertEqual(system.colorScheme, .light)
    XCTAssertEqual(WindowAppearance.system.colorScheme(system: system.colorScheme), .light)
    XCTAssertEqual(WindowAppearance.dark.colorScheme(system: system.colorScheme), .dark)
    XCTAssertEqual(application.appearance?.name, .aqua)
  }

  func testSessionFailuresExposeReadableReasonsInsteadOfNSErrorCodes() {
    let failures: [SessionFailure] = [.malformed, .unsupportedProfile, .untrustedPeer, .authentication,
      .state, .cancelled, .expired, .controlTimeout]
    XCTAssertEqual(failures.count, 8)
    XCTAssertEqual(Set(failures.map(\.localizedDescription)).count, 8)
    for failure in failures {
      XCTAssertFalse(failure.localizedDescription.contains("SessionFailure"))
      XCTAssertFalse(failure.localizedDescription.contains("couldn’t be completed"))
      XCTAssertFalse(failure.localizedDescription.isEmpty)
    }
    XCTAssertEqual(SessionFailure.cancelled.localizedDescription, "The connection closed")
    XCTAssertEqual(SessionFailure.authentication.localizedDescription, "Device authentication failed")
  }
  @MainActor func testCompanionContextMenuKeepsLeftClickDistinctAndRoutesWithoutSessionActions() {
    XCTAssertTrue(CompanionHost.showsContextMenu(eventType: .rightMouseUp, modifiers: []))
    XCTAssertTrue(CompanionHost.showsContextMenu(eventType: .leftMouseUp, modifiers: [.control]))
    XCTAssertFalse(CompanionHost.showsContextMenu(eventType: .leftMouseUp, modifiers: []))
    XCTAssertFalse(CompanionHost.showsContextMenu(eventType: nil, modifiers: []))
    XCTAssertFalse(CompanionHost.showsContextMenu(eventType: .leftMouseUp, modifiers: [.shift]))
    let target = NSObject()
    let items = CompanionHost.makeMenu(target: target).items
    XCTAssertEqual(items.filter { !$0.isSeparatorItem }.map(\.title),
      ["Open aniCe", "Connection details", "Manage devices", "Quit aniCe"])
    XCTAssertEqual(items.filter(\.isSeparatorItem).count, 1)
    for item in items where !item.isSeparatorItem {
      XCTAssertTrue(item.target === target)
      XCTAssertNotNil(item.action)
    }
    XCTAssertEqual(Set(items.compactMap(\.action)).count, 4)
  }

  func testConnectionSummaryRequiresReadinessAcrossBothTransports() {
    let states = ["Disconnected", "Connecting", "Secured", "Failed"]
    var connected = 0, unready = 0
    for bluetooth in states {
      for lan in states {
        let result = ConnectionPresentation(bluetooth: bluetooth, lan: lan,
          bluetoothAllowing: bluetooth == "Connecting" || bluetooth == "Secured",
          lanAllowing: lan == "Connecting" || lan == "Secured", automatic: false)
        if bluetooth == "Secured" || lan == "Secured" {
          connected += 1
          XCTAssertTrue(result.connected)
          XCTAssertEqual(result.action, .disconnect)
          XCTAssertEqual(result.summary.contains("Bluetooth"), bluetooth == "Secured")
          XCTAssertEqual(result.summary.contains("Local network"), lan == "Secured")
        } else {
          unready += 1
          XCTAssertFalse(result.connected)
          XCTAssertFalse(result.summary.hasPrefix("Connected"))
        }
      }
    }
    XCTAssertEqual(connected, 7)
    XCTAssertEqual(unready, 9)
  }

  func testConnectionActionPreservesWaitingAndSecondaryFailure() {
    func presentation(_ bluetooth: String = "Disconnected", _ lan: String = "Disconnected",
      bleAllowing: Bool = false, lanAllowing: Bool = false, automatic: Bool = false) -> ConnectionPresentation {
      ConnectionPresentation(bluetooth: bluetooth, lan: lan, bluetoothAllowing: bleAllowing,
        lanAllowing: lanAllowing, automatic: automatic)
    }
    XCTAssertEqual(presentation().action, .allow)
    XCTAssertEqual(presentation("Failed").action, .retry)
    XCTAssertEqual(presentation(bleAllowing: true).summary, "Waiting for phone")
    XCTAssertEqual(presentation("Connecting", bleAllowing: true).action, .stop)
    XCTAssertEqual(presentation(automatic: true).summary, "Waiting nearby")
    XCTAssertEqual(presentation(automatic: true).action, .stop)
    XCTAssertEqual(presentation("Failed", "Secured", lanAllowing: true).summary, "Connected · Local network")
    XCTAssertEqual(presentation("Secured", "Failed", bleAllowing: true).action, .disconnect)
    XCTAssertEqual(presentation("Secured", "Connecting", bleAllowing: true, lanAllowing: true).summary,
      "Connected · Bluetooth")
  }

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
    var messages = [Data](), exports = [Data](), keys = [Data](), ivs = [Data]()
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
      keys.append(try await c.export(context: b(row, "exportContext-key-1"), length: 32))
      ivs.append(try await c.export(context: b(row, "exportContext-iv-1"), length: 12))
      await c.close(); await s.close()
      try await reject(.cancelled) { _ = try await c.export(context: Data(), length: 32) }
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

/// Runs the packaged loader from the signed hosted app without sending valid playback commands.
final class NowPlayingGateTests: XCTestCase, @unchecked Sendable {
  func testSandboxRemovalKeepsOriginalJournalDirectory() {
    let home = URL(fileURLWithPath: "/Users/test account", isDirectory: true)
    let directory = MacAppStorage.directory(home: home)
    XCTAssertEqual(directory.path, "/Users/test account/Library/Containers/io.github.anisharyal09.anice/Data/Library/Application Support/aniCe")
    XCTAssertNotEqual(directory.path, home.appendingPathComponent("Library/Application Support/aniCe").path)
  }

  func testPackagedWatchRejectsStaleAndOversizedCommandsAndExitsOnEOF() throws {
    let resources = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("NowPlaying")
    let library = resources.appendingPathComponent("libaniCeNowPlaying.dylib")
    XCTAssertTrue(FileManager.default.fileExists(atPath: library.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("GPL-LICENSE.txt").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("THIRD_PARTY_NOTICES.md").path))
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = [resources.appendingPathComponent("now-playing.pl").path, library.path, "watch_all"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let first = expectation(description: "initial native snapshot")
    let rejected = expectation(description: "stale and oversized requests rejected")
    rejected.expectedFulfillmentCount = 2
    let ended = expectation(description: "EOF terminates adapter")
    let lock = NSLock()
    let buffer = GateBuffer()
    output.fileHandleForReading.readabilityHandler = { file in
      let bytes = file.availableData
      lock.lock()
      defer { lock.unlock() }
      buffer.lines.append(bytes)
      guard buffer.lines.count <= 17 * 1024 * 1024 else { XCTFail("unbounded adapter output"); return }
      while let newline = buffer.lines.firstIndex(of: 10) {
        let line = buffer.lines.prefix(upTo: newline)
        buffer.lines.removeSubrange(...newline)
        guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
          XCTFail("invalid native reply"); continue
        }
        if let sent = row["sent"] as? Bool {
          XCTAssertFalse(sent)
          if buffer.rejectionCount < 2 { buffer.rejectionCount += 1; rejected.fulfill() }
        } else if !buffer.firstReceived {
          buffer.firstReceived = true
          XCTAssertNil(row["error"], "native loader did not produce a snapshot")
          XCTAssertNotNil(row["sources"])
          first.fulfill()
        }
      }
    }
    process.terminationHandler = { _ in ended.fulfill() }
    try process.run()
    defer {
      output.fileHandleForReading.readabilityHandler = nil
      try? input.fileHandleForWriting.close()
      if process.isRunning { process.terminate() }
    }
    wait(for: [first], timeout: 8)
    let stale = "play 2147483647 00000000-0000-0000-0000-000000000000 toggle\n"
    try input.fileHandleForWriting.write(contentsOf: Data((String(repeating: "x", count: 2049) + "\n" + stale).utf8))
    wait(for: [rejected], timeout: 5)
    try input.fileHandleForWriting.close()
    wait(for: [ended], timeout: 3)
    XCTAssertEqual(process.terminationStatus, 0)
  }
}

/// Mutable pipe state is protected by the test reader's lock.
private final class GateBuffer: @unchecked Sendable {
  var lines = Data()
  var firstReceived = false
  var rejectionCount = 0
}

final class MediaTests: XCTestCase {
  func testProgressScheduleBoundsAndStopsWhenInactive() {
    let start=Date(timeIntervalSince1970:100)
    let active=Array(MediaProgressSchedule(active:true).entries(from:start,mode:.normal).prefix(5))
    XCTAssertEqual(active.map { $0.timeIntervalSince(start) },[0,0.25,0.5,0.75,1])
    for mode: TimelineScheduleMode in [.normal,.lowFrequency] {
      XCTAssertEqual(Array(MediaProgressSchedule(active:false).entries(from:start,mode:mode).prefix(5)),[start])
    }
  }
  func testIndependentFixturesCanonicalEncodingAndNegativeInventory() throws {
    let helper=SessionTests(), root=try helper.root("media-vectors")
    let valid=try XCTUnwrap(root["valid"] as? [[String:Any]]), invalid=try XCTUnwrap(root["invalid"] as? [[String:Any]])
    XCTAssertGreaterThanOrEqual(valid.count,12); XCTAssertGreaterThanOrEqual(invalid.count,28)
    for row in valid {
      let bytes=try helper.b(row,"bytes"), message=try XCTUnwrap(MediaMessage.decode(bytes))
      XCTAssertEqual(message.kind,(row["kind"] as? NSNumber)?.int64Value)
      XCTAssertEqual(try message.encode(),bytes)
    }
    for row in invalid { XCTAssertThrowsError(try MediaMessage.decode(helper.b(row,"bytes")),row["name"] as? String ?? "") }
  }
  func testLocalProgressBoundsAndMissingDuration() {
    var media=MediaPlayback();media.position=10000;media.duration=200000;media.rate=1000;media.state=1;media.sampledAt=0
    XCTAssertEqual(media.elapsed(at:2),12);XCTAssertEqual(media.elapsed(at:999999),200)
    media.state=2;XCTAssertEqual(media.elapsed(at:999999),10)
    media.duration = -1;media.state=1;XCTAssertEqual(media.elapsed(at:999999),1000009)
    media.position = -1;XCTAssertEqual(media.elapsed(at:1),0)
  }
  @MainActor func testRetiredSubscriptionDuplicateStaleCommandsAndLegacyData() async throws {
    let model=MacPlayback(); var outgoing:[MediaMessage]=[]
    model.channel("ble",token:"a") { outgoing.append(try XCTUnwrap(MediaMessage.decode($0))) }
    let sub=UUID().uuidString, source=UUID().uuidString, revision=UUID().uuidString
    XCTAssertFalse(model.receive(Data("aniCe connection check".utf8),channel:"ble"))
    XCTAssertTrue(model.receive(try MediaMessage(kind:2,fields:[.text(sub)]).encode(),channel:"ble"))
    let command=try MediaMessage(kind:6,fields:[.text(sub),.integer(1),.text(source),.text(revision),.integer(1),.integer(0)]).encode()
    XCTAssertTrue(model.receive(command,channel:"ble"));XCTAssertTrue(model.receive(command,channel:"ble"))
    try await Task.sleep(for:.milliseconds(150))
    XCTAssertEqual(outgoing.filter { $0.kind==7 }.map { $0.number(2) },[1,1])
    XCTAssertTrue(outgoing.contains { $0.kind==3 });XCTAssertTrue(outgoing.contains { $0.kind==5 });XCTAssertTrue(model.phoneSubscribed)
    model.channel("ble",token:nil) { _ in XCTFail("Retired endpoint sent") }
    let count=outgoing.count;XCTAssertTrue(model.receive(command,channel:"ble"))
    try await Task.sleep(for:.milliseconds(100));XCTAssertEqual(outgoing.count,count)
    XCTAssertTrue(model.playback.source.isEmpty);XCTAssertTrue(model.sources.isEmpty);XCTAssertFalse(model.phoneSubscribed)
  }
  @MainActor func testLocalDisplayDefaultsOffPersistsAndDoesNotRetirePhoneSubscription() throws {
    let suite="aniCe.media-display-tests.\(UUID().uuidString)"
    let preferences=try XCTUnwrap(UserDefaults(suiteName:suite))
    defer { preferences.removePersistentDomain(forName:suite) }
    let model=MacPlayback(preferences:preferences,requestSink:{ _ in true })
    XCTAssertFalse(model.showOnMac)
    model.presented("companion",true);XCTAssertFalse(model.companionVisible)
    model.channel("ble",token:"display-test") { _ in }
    let sub=UUID().uuidString
    _ = model.receive(try MediaMessage(kind:2,fields:[.text(sub)]).encode(),channel:"ble")
    XCTAssertTrue(model.phoneSubscribed)
    let pid=ProcessInfo.processInfo.processIdentifier
    model.read(try JSONSerialization.data(withJSONObject:["pid":pid,"playbackRevision":UUID().uuidString,"sourceIsAutomatic":true,
      "sources":[["pid":pid,"bundleIdentifier":Bundle.main.bundleIdentifier!,"isMusicApp":false,"isPlaying":false,"hasTrack":true]],
      "kMRMediaRemoteNowPlayingInfoTitle":"Display test","isPlaying":false,"canSendCommandsDirectly":true,"canToggle":true]))
    let retained=model.playback;XCTAssertFalse(retained.source.isEmpty)
    model.setShowOnMac(true);XCTAssertTrue(model.showOnMac);XCTAssertTrue(model.companionVisible)
    XCTAssertTrue(MacPlayback(preferences:preferences,requestSink:{ _ in true }).showOnMac)
    model.setShowOnMac(false);XCTAssertFalse(model.showOnMac);XCTAssertFalse(model.companionVisible)
    XCTAssertTrue(model.phoneSubscribed);XCTAssertEqual(model.playback,retained)
    XCTAssertFalse(MacPlayback(preferences:preferences,requestSink:{ _ in true }).showOnMac)
    model.setShowOnMac(true);XCTAssertTrue(model.companionVisible)
    model.presented("companion",false);model.setShowOnMac(false);model.setShowOnMac(true)
    XCTAssertFalse(model.companionVisible);XCTAssertTrue(model.phoneSubscribed)
    _ = model.receive(try MediaMessage(kind:4,fields:[.text(sub)]).encode(),channel:"ble")
    XCTAssertFalse(model.phoneSubscribed)
  }
  @MainActor func testInstalledScriptingDictionaryBoundsAndPermissionCapabilities() throws {
    let good=Data("""
      <dictionary><suite name="Playback" code="Musi"><command name="playpause" code="MusiPlPs"/><command name="next track" code="MusiNext"/><class name="application" code="capp"><property name="player position" code="pPos" type="real" access="rw"/></class></suite></dictionary>
      """.utf8)
    let parsed=try XCTUnwrap(PlaybackAutomationCapabilities.parse(good))
    XCTAssertTrue(parsed.canToggle);XCTAssertNotNil(parsed.position);XCTAssertNotNil(parsed.event(for:.next,isPlaying:true));XCTAssertNil(parsed.event(for:.previous,isPlaying:false))
    XCTAssertNil(PlaybackAutomationCapabilities.parse(Data(repeating:0,count:256*1024+1)))
    XCTAssertNil(PlaybackAutomationCapabilities.parse(Data("<!DOCTYPE dictionary [<!ENTITY x SYSTEM 'file:///tmp/secret'>]><dictionary>&x;</dictionary>".utf8)))
    let duplicate=Data("<dictionary><suite><command name='playpause' code='MusiPlPs'/><command name='playpause' code='MusiPlPs'/></suite></dictionary>".utf8)
    XCTAssertNil(PlaybackAutomationCapabilities.parse(duplicate))
    let required=Data("<dictionary><suite><command name='playpause' code='MusiPlPs'><parameter name='unsafe'/></command></suite></dictionary>".utf8)
    XCTAssertNil(PlaybackAutomationCapabilities.parse(required))
  }
  @MainActor func testThumbnailBoundsAndInvalidInput() throws {
    XCTAssertNil(MacPlayback.thumbnail(Data()));XCTAssertNil(MacPlayback.thumbnail(Data(repeating:0,count:12*1024*1024+1)))
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:512,pixelsHigh:384,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
    if let pixels=bitmap.bitmapData { memset(pixels,0,bitmap.bytesPerRow*bitmap.pixelsHigh) }
    let input=try XCTUnwrap(bitmap.representation(using:.jpeg,properties:[:]))
    let thumbnail=try XCTUnwrap(MacPlayback.thumbnail(input)), decoded=try XCTUnwrap(NSBitmapImageRep(data:thumbnail))
    XCTAssertLessThanOrEqual(thumbnail.count,65536);XCTAssertLessThanOrEqual(max(decoded.pixelsWide,decoded.pixelsHigh),256)
  }
  @MainActor func testPackagedOwnerAgainstCurrentlyPlayingSource() async throws {
    guard ProcessInfo.processInfo.environment["ANICE_RUN_PLAYBACK_READ_TEST"]=="1" else { throw XCTSkip("Requires a manually started real player") }
    let model=MacPlayback();model.presented("acceptance",true);defer { model.presented("acceptance",false) }
    try await Task.sleep(for:.seconds(3))
    XCTAssertEqual(model.feedback,"");XCTAssertFalse(model.playback.source.isEmpty);XCTAssertFalse(model.playback.title.isEmpty);XCTAssertFalse(model.playback.revision.isEmpty)
    XCTAssertTrue(model.sources.contains { $0.id==model.playback.source })
    XCTAssertFalse(model.sources.isEmpty)
  }

  @MainActor func testNativeRepliesCannotCompleteAnotherCommandAndSamplesKeepRevision() throws {
    var requests:[PlaybackRequest]=[]
    let model=MacPlayback(requestSink:{requests.append($0);return true})
    let pid=ProcessInfo.processInfo.processIdentifier, nativeRevision=UUID()
    func snapshot(_ revision: UUID,_ position: Double=1) throws -> Data {
      try JSONSerialization.data(withJSONObject:["pid":pid,"playbackRevision":revision.uuidString,"sourceIsAutomatic":true,
        "sources":[["pid":pid,"bundleIdentifier":Bundle.main.bundleIdentifier!,"isMusicApp":false,"isPlaying":true,"hasTrack":true,"displayName":"Test player"]],
        "kMRMediaRemoteNowPlayingInfoTitle":"Track","kMRMediaRemoteNowPlayingInfoDuration":100,"kMRMediaRemoteNowPlayingInfoElapsedTime":position,
        "kMRMediaRemoteNowPlayingInfoPlaybackRate":1,"isPlaying":true,"canSendCommandsDirectly":true,"canToggle":true,"canSeek":true])
    }
    model.read(try snapshot(nativeRevision));XCTAssertFalse(model.playback.source.isEmpty)
    let first=model.playback
    model.read(try snapshot(nativeRevision,2));XCTAssertEqual(model.playback.revision,first.revision)
    var results:[Int64]=[]
    model.command(source:first.source,revision:first.revision,action:4,value:100001) { results.append($0) }
    XCTAssertEqual(results,[1]);XCTAssertTrue(requests.isEmpty)
    model.command(source:first.source,revision:first.revision,action:1) { results.append($0) }
    let oldID=try XCTUnwrap(requests.last?.requestID);XCTAssertTrue(model.busy)
    model.read(try snapshot(UUID()));XCTAssertFalse(model.busy);XCTAssertEqual(results,[1,1])
    let second=model.playback
    model.command(source:second.source,revision:second.revision,action:1) { results.append($0) }
    let newID=try XCTUnwrap(requests.last?.requestID)
    model.read(try JSONSerialization.data(withJSONObject:["sent":true,"requestID":oldID.uuidString]))
    XCTAssertTrue(model.busy);XCTAssertEqual(results,[1,1])
    model.read(try JSONSerialization.data(withJSONObject:["sent":true,"requestID":newID.uuidString]))
    XCTAssertFalse(model.busy);XCTAssertEqual(results,[1,1,0]);XCTAssertEqual(requests.count,3);XCTAssertEqual(requests.last?.command,.sample)
    let confirmed=model.playback
    let quick:[String:Any] = ["sampleOnly":true,"pid":pid,"playbackRevision":requests.last!.context!.revision.uuidString,"isPlaying":false,"kMRMediaRemoteNowPlayingInfoElapsedTime":42,"kMRMediaRemoteNowPlayingInfoPlaybackRate":1]
    model.read(try JSONSerialization.data(withJSONObject:quick))
    XCTAssertEqual(model.playback.position,42000);XCTAssertEqual(model.playback.state,2);XCTAssertEqual(model.playback.rate,0);XCTAssertEqual(model.playback.revision,confirmed.revision)
    var stale=quick;stale["playbackRevision"]=UUID().uuidString;stale["kMRMediaRemoteNowPlayingInfoElapsedTime"]=99
    model.read(try JSONSerialization.data(withJSONObject:stale));XCTAssertEqual(model.playback.position,42000)
    var playOnly=try XCTUnwrap(JSONSerialization.jsonObject(with:snapshot(UUID())) as? [String:Any])
    playOnly["canToggle"]=false;playOnly["canPlay"]=true;playOnly["canPause"]=false
    model.read(try JSONSerialization.data(withJSONObject:playOnly));XCTAssertEqual(model.playback.actions & 1,0)
    model.command(source:model.playback.source,revision:model.playback.revision,action:1) { results.append($0) };XCTAssertEqual(results.last,2)
    playOnly["isPlaying"]=false;model.read(try JSONSerialization.data(withJSONObject:playOnly));XCTAssertEqual(model.playback.actions & 1,1)
    let pausedRevision=model.playback.revision
    model.read(try JSONSerialization.data(withJSONObject:["sampleOnly":true,"pid":pid,"playbackRevision":playOnly["playbackRevision"]!,"isPlaying":true,"kMRMediaRemoteNowPlayingInfoElapsedTime":3,"kMRMediaRemoteNowPlayingInfoPlaybackRate":1]))
    XCTAssertEqual(model.playback.actions & 1,0);XCTAssertNotEqual(model.playback.revision,pausedRevision)
    model.read(Data("{\"error\":\"metadata timeout\"}".utf8));XCTAssertTrue(model.playback.source.isEmpty);XCTAssertFalse(model.feedback.isEmpty)
  }
  @MainActor func testAppliedRemoteCommandDuplicatesExecuteOnlyOnce() async throws {
    var requests:[PlaybackRequest]=[], sent:[MediaMessage]=[]
    let model=MacPlayback(requestSink:{requests.append($0);return true})
    model.channel("ble",token:"secured") { sent.append(try XCTUnwrap(MediaMessage.decode($0))) }
    let sub=UUID().uuidString;_ = model.receive(try MediaMessage(kind:2,fields:[.text(sub)]).encode(),channel:"ble")
    let pid=ProcessInfo.processInfo.processIdentifier
    model.read(try JSONSerialization.data(withJSONObject:["pid":pid,"playbackRevision":UUID().uuidString,"sourceIsAutomatic":true,
      "sources":[["pid":pid,"bundleIdentifier":Bundle.main.bundleIdentifier!,"isMusicApp":false,"isPlaying":true,"hasTrack":true]],
      "kMRMediaRemoteNowPlayingInfoTitle":"Test","isPlaying":true,"canSendCommandsDirectly":true,"canToggle":true]))
    let target=model.playback, command=try MediaMessage(kind:6,fields:[.text(sub),.integer(1),.text(target.source),.text(target.revision),.integer(1),.integer(0)]).encode()
    _ = model.receive(command,channel:"ble");_ = model.receive(command,channel:"ble")
    XCTAssertEqual(requests.count,1)
    model.read(try JSONSerialization.data(withJSONObject:["sent":true,"requestID":requests[0].requestID!.uuidString]))
    _ = model.receive(command,channel:"ble");try await Task.sleep(for:.milliseconds(100))
    XCTAssertEqual(requests.count,2);XCTAssertEqual(requests.last?.command,.sample);XCTAssertEqual(sent.filter { $0.kind==7 }.map { $0.number(2) },[0,0])
    model.channel("ble",token:nil) { _ in XCTFail("Retired") }
  }

}
