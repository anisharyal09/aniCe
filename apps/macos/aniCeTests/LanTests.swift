// SPDX-License-Identifier: GPL-3.0-or-later
// Probes LAN framing, peer reservations and admission under malformed and stale operations.
import CryptoKit
import Foundation
import Network
import XCTest

@testable import aniCe

private struct UnavailableLanIdentityStorage: IdentityStorage {
  func loadRecord() throws -> IdentityRecord? { throw IdentityError.storageUnavailable("injected") }
  func saveRecord(_ record: IdentityRecord) throws { throw IdentityError.storageUnavailable("injected") }
  func keyTags() throws -> [String] { [] }
  func key(tag: String) throws -> StoredPublicKey? { nil }
  func createKey(tag: String) throws -> StoredPublicKey { throw IdentityError.storageUnavailable("injected") }
  func sign(tag: String, message: Data) throws -> Data { throw IdentityError.storageUnavailable("injected") }
  func deleteKey(tag: String) throws { throw IdentityError.storageUnavailable("injected") }
}

final class LanTests: XCTestCase {
  @MainActor func testAutomaticLANRequiresBothPreferencesAndDisconnectPausesRetries() async throws {
    let identity = IdentityService(storage: UnavailableLanIdentityStorage(), deviceName: "Test", tagPrefix: "isolated")
    let owner = MacLanSessionModel(identity: identity, peers: SessionPeerReservation()) {
      XCTFail("Unavailable identity must fail before accessing trust")
      throw SessionFailure.state
    }
    let channel = MockSecuredChannel(transport: "ble")
    owner.rendezvous.available(channel)
    _ = try await owner.rendezvous.handle(LanRendezvousWire.encode(1), on: channel.descriptor)
    try await Task.sleep(for: .milliseconds(20))
    let disabledLoads = await identity.identityLoads
    XCTAssertEqual(disabledLoads, 0)
    owner.setAutomatic(true)
    _ = try await owner.rendezvous.handle(LanRendezvousWire.encode(0), on: channel.descriptor)
    try await Task.sleep(for: .milliseconds(20))
    let remoteDisabledLoads = await identity.identityLoads
    XCTAssertEqual(remoteDisabledLoads, 0)
    _ = try await owner.rendezvous.handle(LanRendezvousWire.encode(1), on: channel.descriptor)
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while owner.state != "Failed", ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(owner.state, "Failed")
    let failedLoads = await identity.identityLoads
    XCTAssertEqual(failedLoads, 1)
    _ = try await owner.rendezvous.handle(LanRendezvousWire.encode(1), on: channel.descriptor)
    try await Task.sleep(for: .milliseconds(2100))
    let idleLoads = await identity.identityLoads
    XCTAssertEqual(idleLoads, 1, "A failed LAN attempt must not create a timed retry")
    for state: Int64 in 0...4 { owner.onApplicationActivity(channel.descriptor, try LanRendezvousWire.encode(state)) }
    let stale = MockSecuredChannel(instance: "retired", transport: "ble")
    owner.onApplicationActivity(stale.descriptor, try SessionCbor.encode(.text("feature activity")))
    try await Task.sleep(for: .milliseconds(30))
    let controlLoads = await identity.identityLoads
    XCTAssertEqual(controlLoads, 1, "Coordination and stale traffic must not initiate LAN")
    let activity = try SessionCbor.encode(.text("feature activity"))
    for _ in 0..<10 { owner.onApplicationActivity(channel.descriptor, activity) }
    let requestDeadline = ContinuousClock.now.advanced(by: .seconds(1))
    while await identity.identityLoads < 2, ContinuousClock.now < requestDeadline { try await Task.sleep(for: .milliseconds(5)) }
    let requestedLoads = await identity.identityLoads
    XCTAssertEqual(requestedLoads, 2)
    owner.disconnect()
    owner.onApplicationActivity(channel.descriptor, activity)
    _ = try await owner.rendezvous.handle(LanRendezvousWire.encode(1), on: channel.descriptor)
    try await Task.sleep(for: .milliseconds(30))
    let disconnectedLoads = await identity.identityLoads
    XCTAssertEqual(disconnectedLoads, requestedLoads)
    XCTAssertFalse(owner.allowing)
    XCTAssertTrue(owner.automatic)
    owner.rendezvous.retired(channel.descriptor)
  }

  @MainActor func testAutomaticLANDefaultsOnUnlessTheUserStoredOff() {
    let suite = "io.github.anisharyal09.anice.lan-tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("Missing test defaults") }
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let identity = IdentityService(storage: UnavailableLanIdentityStorage(), deviceName: "Test", tagPrefix: "isolated")
    @MainActor func make() -> MacLanSessionModel {
      MacLanSessionModel(identity: identity, peers: SessionPeerReservation(), preferences: defaults) {
        XCTFail("Disabled automation must not load the identity")
        throw SessionFailure.state
      }
    }
    XCTAssertTrue(make().automatic, "An absent preference must leave automation on")
    let disabled = make()
    disabled.setAutomatic(false)
    XCTAssertEqual(defaults.object(forKey: "lan.automatic") as? Bool, false)
    XCTAssertFalse(make().automatic, "An explicitly stored off preference must win")
    defaults.removeObject(forKey: "lan.automatic")
    XCTAssertTrue(make().automatic)
  }

  @MainActor func testManualDisconnectSurvivesFeatureActivityAndPreferenceChangeResumes() async throws {
    let identity = IdentityService(storage: UnavailableLanIdentityStorage(), deviceName: "Test", tagPrefix: "isolated")
    let owner = MacLanSessionModel(identity: identity, peers: SessionPeerReservation()) {
      XCTFail("Paused automation must not load the identity")
      throw SessionFailure.state
    }
    let channel = MockSecuredChannel(transport: "ble")
    owner.rendezvous.available(channel)
    owner.setAutomatic(true)
    _ = try await owner.rendezvous.handle(LanRendezvousWire.encode(1), on: channel.descriptor)
    try await Task.sleep(for: .milliseconds(20))
    owner.disconnect()
    let disconnectedLoads = await identity.identityLoads
    owner.onApplicationActivity(channel.descriptor, try SessionCbor.encode(.text("feature activity")))
    XCTAssertFalse(owner.requestAutomaticConnection())
    _ = try await owner.rendezvous.handle(LanRendezvousWire.encode(1), on: channel.descriptor)
    try await Task.sleep(for: .milliseconds(30))
    let pausedLoads = await identity.identityLoads
    XCTAssertEqual(pausedLoads, disconnectedLoads, "Feature traffic must not resume a manual disconnect")
    XCTAssertFalse(owner.allowing)
    owner.setAutomatic(true)
    XCTAssertTrue(owner.requestAutomaticConnection())
    owner.rendezvous.retired(channel.descriptor)
  }

  func testAutomaticGateConsumesEachEventOnce() {
    var gate = LanAttemptGate()
    for index in 0..<20 {
      gate.update(channel: "ble-1", eligible: true, remoteEligible: true, ready: false, requests: 0)
      XCTAssertEqual(gate.claim(), index == 0)
    }
    gate.update(channel: "ble-1", eligible: true, remoteEligible: true, ready: false, requests: 1)
    XCTAssertTrue(gate.claim()); XCTAssertFalse(gate.claim())
    gate.update(channel: "ble-2", eligible: true, remoteEligible: true, ready: false, requests: 1)
    XCTAssertTrue(gate.claim()); XCTAssertFalse(gate.claim())
  }
  @MainActor func testExplicitRendezvousDemandDoesNotOverrideDisabledPeer() async throws {
    let link = LanRendezvous(), channel = MockSecuredChannel(transport: "ble")
    link.available(channel); link.update(1)
    for _ in 0..<10 { await Task.yield() }
    _ = try await link.handle(LanRendezvousWire.encode(0), on: channel.descriptor)
    _ = try await link.handle(LanRendezvousWire.encode(4), on: channel.descriptor)
    XCTAssertEqual(link.remote, 0); XCTAssertEqual(link.requests, 1)
    link.request()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(try channel.sentData.map { try LanRendezvousWire.decode($0) }, [1, 4])
    link.retired(channel.descriptor)
  }
  func testRendezvousIndependentWireAndMalformedStates() throws {
    let prefix = try helper.hex("8369616e694365204c414e01")
    for state: Int64 in 0...4 {
      XCTAssertEqual(try LanRendezvousWire.encode(state), prefix + Data([UInt8(state)]))
      XCTAssertEqual(try LanRendezvousWire.decode(prefix + Data([UInt8(state)])), state)
    }
    let invalid = [prefix + Data([5]), prefix + Data([0x20]), prefix.dropLast() + Data([2, 1]), prefix + Data([1, 0])]
    XCTAssertGreaterThanOrEqual(invalid.count, 4)
    for bytes in invalid { XCTAssertThrowsError(try LanRendezvousWire.decode(bytes)) }
    XCTAssertNil(try LanRendezvousWire.decode(SessionCbor.encode(.text("other"))))
    XCTAssertNil(try LanRendezvousWire.decode(Data(repeating: 0, count: 65)))
  }
  @MainActor func testRendezvousBindsBLEGenerationAndDoesNotEcho() async throws {
    let link = LanRendezvous()
    var changes = 0
    link.changed = { changes += 1 }
    let lan = MockSecuredChannel()
    link.available(lan)
    XCTAssertNil(link.channel)
    let ignored = try await link.handle(LanRendezvousWire.encode(2), on: lan.descriptor)
    XCTAssertEqual(ignored, .unrecognized)
    let first = MockSecuredChannel(transport: "ble")
    link.available(first); link.update(1)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(first.sentData.count, 1)
    let result = try await link.handle(LanRendezvousWire.encode(2), on: first.descriptor)
    XCTAssertEqual(result, .handled)
    XCTAssertEqual(link.remote, 2)
    _ = try await link.handle(LanRendezvousWire.encode(2), on: first.descriptor)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(first.sentData.count, 1)
    link.retired(first.descriptor)
    XCTAssertNil(link.remote)
    let replacement = MockSecuredChannel(instance: "replacement", transport: "ble")
    link.available(replacement)
    link.retired(first.descriptor)
    XCTAssertTrue(link.channel === replacement)
    let stale = try await link.handle(LanRendezvousWire.encode(2), on: first.descriptor)
    XCTAssertEqual(stale, .unrecognized)
    XCTAssertNil(link.remote)
    XCTAssertGreaterThanOrEqual(changes, 4)
    link.retired(replacement.descriptor)
  }
  @MainActor func testRendezvousBackpressureCoalescesLatestState() async throws {
    let link = LanRendezvous(), channel = MockSecuredChannel(transport: "ble")
    channel.onSendData = { _ in throw SessionBackpressure() }
    link.available(channel); link.update(1)
    for _ in 0..<10 { await Task.yield() }
    link.update(2); link.update(0)
    for _ in 0..<10 { await Task.yield() }
    channel.sentData.removeAll()
    channel.onSendData = nil
    link.capacityAvailable(channel.descriptor)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(try channel.sentData.map { try LanRendezvousWire.decode($0) }, [0])
    link.retired(channel.descriptor)
  }

  @MainActor func testTCPPeerLossDetectionDoesNotWaitForDefaultIdleTimeouts() throws {
    let parameters = LanTcpTransport.parameters()
    let options = try XCTUnwrap(
      parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
    XCTAssertTrue(options.noDelay)
    XCTAssertTrue(options.enableKeepalive)
    XCTAssertGreaterThan(options.keepaliveIdle, 0)
    XCTAssertGreaterThan(options.keepaliveCount, 0)
    XCTAssertGreaterThan(options.keepaliveInterval, 0)
    XCTAssertLessThanOrEqual(
      options.keepaliveIdle + options.keepaliveCount * options.keepaliveInterval, 30)
    XCTAssertGreaterThan(options.connectionDropTime, 0)
    XCTAssertLessThanOrEqual(options.connectionDropTime, 30)
    XCTAssertFalse(parameters.includePeerToPeer)
    XCTAssertEqual(parameters.prohibitedInterfaceTypes?.contains(.loopback), true)
  }
  private let helper = SessionFixtures()
  private func feed(_ bytes: Data, into framing: inout LanFraming) throws -> [Data] {
    let time = try framing.beginBuffer()
    var offset = 0
    var result = [Data]()
    while offset < bytes.count {
      if let frame = try framing.feed(bytes, offset: &offset, receivedAt: time) { result.append(frame) }
    }
    return result
  }
  func testIndependentFixturesAndEverySplitPoint() throws {
    let root = try helper.root("lan-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(valid.count, 8)
    XCTAssertGreaterThanOrEqual(invalid.count, 10)
    for row in valid {
      let frame = try helper.b(row, "frame")
      let envelope = try helper.b(row, "envelope")
      XCTAssertEqual(try LanFraming.encode(envelope), frame)
      for split in 0...frame.count {
        var framing = LanFraming()
        let first = try feed(Data(frame.prefix(split)), into: &framing)
        let second = try feed(Data(frame.dropFirst(split)), into: &framing)
        XCTAssertEqual(first + second, [envelope])
        try framing.end()
      }
    }
    for row in invalid {
      var framing = LanFraming()
      let reason = try XCTUnwrap(SessionFailure(rawValue: XCTUnwrap(row["reason"] as? String)))
      XCTAssertThrowsError(
        try {
          _ = try feed(helper.b(row, "frame"), into: &framing)
          try framing.end()
        }()
      ) {
        XCTAssertEqual($0 as? SessionFailure, reason)
      }
      XCTAssertThrowsError(try feed(Data([1]), into: &framing)) {
        XCTAssertEqual($0 as? SessionFailure, .cancelled)
      }
    }
  }
  func testCoalescingAndSlowAssemblyCannotExtendDeadline() throws {
    let envelope = Data([1, 42])
    let frame = try LanFraming.encode(envelope)
    var framing = LanFraming()
    XCTAssertEqual(try feed(frame + frame + frame, into: &framing), [envelope, envelope, envelope])
    var clock: TimeInterval = 0
    var slow = LanFraming(now: { clock })
    XCTAssertNil(slow.nextDeadline)
    _ = try feed(Data([1]), into: &slow)
    XCTAssertEqual(slow.nextDeadline, 10)
    clock = 9.999
    _ = try feed(Data([0]), into: &slow)
    XCTAssertEqual(slow.nextDeadline, 10)
    clock = 10
    XCTAssertThrowsError(try feed(Data([0]), into: &slow)) { XCTAssertEqual($0 as? SessionFailure, .expired) }
    XCTAssertThrowsError(try slow.end()) { XCTAssertEqual($0 as? SessionFailure, .cancelled) }
    XCTAssertNil(slow.nextDeadline)
    for size in [0, 1, 4097] {
      XCTAssertThrowsError(try LanFraming.encode(Data(repeating: 0, count: size))) {
        XCTAssertEqual($0 as? SessionFailure, .malformed)
      }
    }
  }
  func testBufferClockIsSampledOnceAndSlicesPreserveOffsets() throws {
    var reads = 0
    var framing = LanFraming(now: { reads += 1; return 0 })
    let payload = Data(repeating: 7, count: 4096)
    let wire = try LanFraming.encode(payload)
    let slice = (Data([99, 99]) + wire).dropFirst(2)
    XCTAssertEqual(try feed(slice, into: &framing), [payload])
    XCTAssertEqual(reads, 1)
    for count in 1..<wire.count {
      var partial = LanFraming()
      _ = try feed(Data(wire.prefix(count)), into: &partial)
      XCTAssertThrowsError(try partial.end()) { XCTAssertEqual($0 as? SessionFailure, .malformed) }
      XCTAssertThrowsError(try partial.beginBuffer()) { XCTAssertEqual($0 as? SessionFailure, .cancelled) }
    }
  }

  func testEnvelopesAreOwnedByTheCallerAndNeverAliasTheAssemblyBuffers() throws {
    let first = Data(repeating: 1, count: 64), second = Data(repeating: 2, count: 64)
    var wire = try LanFraming.encode(first)
    wire.append(try LanFraming.encode(second))
    var framing = LanFraming()
    let frames = try feed(wire, into: &framing)
    XCTAssertEqual(frames, [first, second])
    let third = Data(repeating: 3, count: 64)
    let following = try feed(try LanFraming.encode(third), into: &framing)
    XCTAssertEqual(following, [third])
    // A handed-off envelope is the frame's own value, so assembling the next record cannot rewrite
    // one already sitting in the ingress queue.
    XCTAssertEqual(frames, [first, second])
  }

  func testBulkProbeIndependentOracleAndStandardIsolation() throws {
    let root = try helper.root("bulk-probe-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(valid.count, 3); XCTAssertGreaterThanOrEqual(invalid.count, 10)
    let key = try helper.b(root, "key"), iv = try helper.b(root, "iv"), id = try helper.b(root, "id")
    for row in valid {
      let size = try XCTUnwrap(row["length"] as? Int)
      let plain = Data((0..<size).map { UInt8($0 % 251) })
      let record = try SessionRecordCodec.seal(key: key, iv: iv, id: id, direction: 1,
        kind: .data, sequence: 0, plaintext: plain, profile: .bulkProbe)
      let digest = SHA256.hash(data: record).map { String(format: "%02x", $0) }.joined()
      XCTAssertEqual(digest, row["recordSHA256"] as? String)
      XCTAssertEqual(record.prefix(14), try helper.b(row, "header"))
      XCTAssertEqual(record.suffix(16), try helper.b(row, "tag"))
      XCTAssertEqual(try SessionRecordCodec.open(key: key, iv: iv, id: id, direction: 1,
        expected: 0, record: record, profile: .bulkProbe).1, plain)
      XCTAssertThrowsError(try SessionRecordCodec.open(key: key, iv: iv, id: id, direction: 1,
        expected: 0, record: record)) { XCTAssertEqual($0 as? SessionFailure, .malformed) }
    }
    for row in invalid {
      let reason = try XCTUnwrap(SessionFailure(rawValue: XCTUnwrap(row["reason"] as? String)))
      XCTAssertThrowsError(try SessionRecordCodec.open(key: key, iv: iv, id: id, direction: 1,
        expected: 0, record: helper.b(row, "record"), profile: .bulkProbe)) {
        XCTAssertEqual($0 as? SessionFailure, reason)
      }
    }
    XCTAssertThrowsError(try SessionRecordCodec.seal(key: key, iv: iv, id: id, direction: 1,
      kind: .data, sequence: 0, plaintext: Data(repeating: 0, count: 4194305), profile: .bulkProbe))
    XCTAssertThrowsError(try SessionEnvelope.encode(1, Data(repeating: 0, count: 4096), profile: .bulkProbe))
    let envelope = Data(repeating: 6, count: 4194335)
    let frame = try LanFraming.encode(envelope, profile: .bulkProbe)
    var bulk = LanFraming(profile: .bulkProbe)
    XCTAssertEqual(try feed(frame, into: &bulk), [envelope])
    var standard = LanFraming()
    XCTAssertThrowsError(try feed(Data(frame.prefix(5)), into: &standard)) {
      XCTAssertEqual($0 as? SessionFailure, .unsupportedProfile)
    }
    var budget = LanQueueBudget(profile: .bulkProbe)
    for _ in 0..<4 { try budget.reserve(envelope.count) }
    XCTAssertFalse(budget.canReserve(1))
    for _ in 0..<4 { budget.release(envelope.count) }
    XCTAssertTrue(budget.canReserve(envelope.count))
    XCTAssertFalse(LanQueueBudget(profile: .standard).canReserve(envelope.count))
    XCTAssertNotEqual(SessionProfile.standard.exporterLabel, SessionProfile.bulkProbe.exporterLabel)
  }

  func testLanTransferIndependentOracleAndStandardIsolation() throws {
    let root = try helper.root("lan-transfer-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(valid.count, 3); XCTAssertGreaterThanOrEqual(invalid.count, 10)
    let key = try helper.b(root, "key"), iv = try helper.b(root, "iv"), id = try helper.b(root, "id")
    for row in valid {
      let size = try XCTUnwrap(row["length"] as? Int)
      let plain = Data((0..<size).map { UInt8($0 % 251) })
      let record = try SessionRecordCodec.seal(key: key, iv: iv, id: id, direction: 1,
        kind: .data, sequence: 0, plaintext: plain, profile: .lanTransfer)
      let digest = SHA256.hash(data: record).map { String(format: "%02x", $0) }.joined()
      XCTAssertEqual(digest, row["recordSHA256"] as? String)
      XCTAssertEqual(record.prefix(14), try helper.b(row, "header"))
      XCTAssertEqual(record.suffix(16), try helper.b(row, "tag"))
      XCTAssertEqual(try SessionRecordCodec.open(key: key, iv: iv, id: id, direction: 1,
        expected: 0, record: record, profile: .lanTransfer).1, plain)
      XCTAssertThrowsError(try SessionRecordCodec.open(key: key, iv: iv, id: id, direction: 1,
        expected: 0, record: record)) { XCTAssertEqual($0 as? SessionFailure, .malformed) }
    }
    for row in invalid {
      let reason = try XCTUnwrap(SessionFailure(rawValue: XCTUnwrap(row["reason"] as? String)))
      XCTAssertThrowsError(try SessionRecordCodec.open(key: key, iv: iv, id: id, direction: 1,
        expected: 0, record: helper.b(row, "record"), profile: .lanTransfer)) {
        XCTAssertEqual($0 as? SessionFailure, reason)
      }
    }
    XCTAssertThrowsError(try SessionRecordCodec.seal(key: key, iv: iv, id: id, direction: 1,
      kind: .data, sequence: 0, plaintext: Data(repeating: 0, count: 262145), profile: .lanTransfer))
    XCTAssertThrowsError(try SessionEnvelope.encode(1, Data(repeating: 0, count: 4096), profile: .lanTransfer))
    let envelope = Data(repeating: 6, count: 262175)
    let frame = try LanFraming.encode(envelope, profile: .lanTransfer)
    var bulk = LanFraming(profile: .lanTransfer)
    XCTAssertEqual(try feed(frame, into: &bulk), [envelope])
    var standard = LanFraming()
    XCTAssertThrowsError(try feed(Data(frame.prefix(5)), into: &standard)) {
      XCTAssertEqual($0 as? SessionFailure, .unsupportedProfile)
    }
    var budget = LanQueueBudget(profile: .lanTransfer)
    for _ in 0..<4 { try budget.reserve(envelope.count) }
    XCTAssertFalse(budget.canReserve(1))
    for _ in 0..<4 { budget.release(envelope.count) }
    XCTAssertTrue(budget.canReserve(envelope.count))
    XCTAssertFalse(LanQueueBudget(profile: .standard).canReserve(envelope.count))
    XCTAssertNotEqual(SessionProfile.standard.exporterLabel, SessionProfile.lanTransfer.exporterLabel)
  }

  @MainActor func testUnknownAdmissionIsExclusiveAndKnownPeersRemainPinned() throws {
    let row = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    let peer = try helper.identity(row, "initiator")
    let other = try helper.identity(row, "responder")
    let reservation = SessionPeerReservation()
    XCTAssertTrue(reservation.acquire("ble", peer: nil, local: "local"))
    XCTAssertFalse(reservation.acquire("lan", peer: peer, local: "local"))
    XCTAssertTrue(reservation.authenticate("ble", peer: peer))
    XCTAssertTrue(reservation.acquire("lan", peer: peer, local: "local"))
    XCTAssertFalse(reservation.acquire("ble", peer: nil, local: "local"))
    XCTAssertFalse(reservation.acquire("lan", peer: other, local: "local"))
    XCTAssertFalse(reservation.acquire("lan", peer: peer, local: "changed"))
    XCTAssertFalse(reservation.authenticate("ble", peer: other))
    reservation.release("ble")
    XCTAssertFalse(reservation.acquire("ble", peer: other, local: "local"))
    reservation.release("lan")
    XCTAssertNil(reservation.peer)
    XCTAssertFalse(reservation.authenticate("lan", peer: peer))
    XCTAssertTrue(reservation.acquire("ble", peer: other, local: "changed"))
  }
  func testAdmissionFailureBudgetDoesNotExtendWindow() {
    var window = SessionAdmissionWindow()
    window.open(0)
    for index in 0..<5 {
      XCTAssertTrue(window.claim(Double(index)))
      XCTAssertFalse(window.claim(Double(index)))
      XCTAssertEqual(window.retire(Double(index)), index < 4)
      window.open(Double(index) + 100)
      XCTAssertEqual(window.deadline, 120)
    }
    XCTAssertFalse(window.claim(6))
    window.clear()
    window.open(10)
    XCTAssertFalse(window.claim(130))
  }

  @MainActor private func assertCapacity(_ transport: LanTcpTransport, _ size: Int, _ expected: Bool,
    file: StaticString = #filePath, line: UInt = #line) async {
    let available = await transport.capacity(size)
    XCTAssertEqual(available, expected, file: file, line: line)
  }

  @MainActor func testQueuedWritesAreBoundedAndCloseResumesEverySubmission() async throws {
    let socket = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    let transport = LanTcpTransport(socket)
    var jobs = [Task<Void, Error>]()
    let envelope = Data(repeating: 6, count: 4096)
    for _ in 0..<8 {
      await assertCapacity(transport, envelope.count, true)
      jobs.append(Task { try await transport.submit(envelope) })
      await Task.yield()
    }
    await assertCapacity(transport, 2, false)
    do {
      try await transport.submit(Data([1, 0]))
      XCTFail("Queue overflow accepted")
    } catch is SessionBackpressure {}
    await transport.close()
    for job in jobs {
      do {
        try await job.value
        XCTFail("Retired submission succeeded")
      } catch let failure as SessionFailure { XCTAssertEqual(failure, .cancelled) }
    }
    await assertCapacity(transport, 2, false)
  }

  @MainActor func testStalledNativeSubmissionIsRetiredByWatchdog() async throws {
    let socket = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    let transport = LanTcpTransport(socket)
    let start = ProcessInfo.processInfo.systemUptime
    do {
      try await transport.submit(Data([1, 0]))
      XCTFail("Stalled submission succeeded")
    } catch let failure as SessionFailure { XCTAssertEqual(failure, .cancelled) }
    XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 10)
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 15)
    await assertCapacity(transport, 2, false)
  }

  @MainActor func testCancellationRetiresAnOutstandingSubmission() async throws {
    let transport = LanTcpTransport(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
    let submission = Task { try await transport.submit(Data([1, 0])) }
    await Task.yield()
    submission.cancel()
    do {
      try await submission.value
      XCTFail("Cancelled submission succeeded")
    } catch is CancellationError {} catch let failure as SessionFailure {
      XCTAssertEqual(failure, .cancelled)
    }
    await Task.yield()
    await assertCapacity(transport, 2, false)
  }

  @MainActor private func socket() -> NWConnection {
    NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
  }

  /// With no consumer running, a pushed envelope must stay until it is popped, and `pop` must report
  /// nil only after the hand-off is closed — never a synthetic empty.
  @MainActor func testIngressHandsOffEveryEnvelopeInOrder() async throws {
    let transport = LanTcpTransport(socket(), profile: .lanTransfer)
    let queue = await transport.ingressQueue
    let expected = (0..<64).map { Data(repeating: UInt8($0), count: 4096) }
    let produced = Task { for bytes in expected { await queue.push(bytes) } }
    var received = [Data]()
    for _ in expected.indices {
      let next = await queue.pop()
      received.append(try XCTUnwrap(next))
    }
    await produced.value
    XCTAssertEqual(received, expected)
    await queue.close()
    let drained = await queue.pop()
    XCTAssertNil(drained)
  }

  /// The regression guard for this change: a full hand-off suspends its producer. An implementation
  /// that dropped (every `AsyncStream` buffering policy does) or grew without bound would complete
  /// the suspended push here and report a count past the profile-3 admission limit.
  @MainActor func testAFullIngressSuspendsItsProducerInsteadOfDroppingOrGrowing() async throws {
    let transport = LanTcpTransport(socket(), profile: .lanTransfer)
    let queue = await transport.ingressQueue
    let envelope = Data(repeating: 6, count: 262175)
    for _ in 0..<4 { await queue.push(envelope) }
    let filled = await queue.count
    XCTAssertEqual(filled, 4)
    let probe = IngressProbe()
    let blocked = Task {
      await queue.push(envelope)
      await probe.pushed()
    }
    for _ in 0..<200 where await probe.count == 0 { try await Task.sleep(for: .milliseconds(1)) }
    let early = await probe.count
    XCTAssertEqual(early, 0, "A full hand-off must suspend its producer")
    let held = await queue.count
    XCTAssertEqual(held, 4, "A suspended producer must not buffer past the bound")
    let first = await queue.pop()
    XCTAssertEqual(first, envelope)
    await blocked.value
    let refilled = await queue.count
    XCTAssertEqual(refilled, 4, "Popping one envelope releases exactly one suspended push")
    await transport.close()
  }

  /// The bound restates the documented admission limit, so the profile decides it: eight standard
  /// envelopes, four for the larger bulk and LAN-transfer records.
  @MainActor func testTheProfileSelectsTheDocumentedIngressBound() async throws {
    for (profile, limit) in [(SessionProfile.standard, 8), (SessionProfile.lanTransfer, 4)] {
      let transport = LanTcpTransport(socket(), profile: profile)
      let queue = await transport.ingressQueue
      for _ in 0..<limit { await queue.push(Data([1])) }
      let filled = await queue.count
      XCTAssertEqual(filled, limit)
      let probe = IngressProbe()
      let blocked = Task {
        await queue.push(Data([2]))
        await probe.pushed()
      }
      for _ in 0..<200 where await probe.count == 0 { try await Task.sleep(for: .milliseconds(1)) }
      let past = await probe.count
      let retained = await queue.count
      XCTAssertEqual(past, 0)
      XCTAssertEqual(retained, limit)
      await transport.close()
      await blocked.value
      // Closing ends the hand-off without emptying it: the envelopes it already accepted still reach
      // the consumer, and only then does `pop` report the end of the stream.
      var delivered = [Data]()
      while let bytes = await queue.pop() { delivered.append(bytes) }
      XCTAssertEqual(delivered, Array(repeating: Data([1]), count: limit))
    }
  }

  /// A stream end must not discard records the read loop already handed over. The peer's FIN commonly
  /// follows its last record, so a close that emptied the hand-off would drop the record carrying the
  /// peer's CLOSE — which inline delivery always delivered, and which `closedByPeer` depends on.
  @MainActor func testClosingTheIngressHandOffStillDeliversTheEnvelopesAlreadyHandedOver() async throws {
    let transport = LanTcpTransport(socket(), profile: .lanTransfer)
    let queue = await transport.ingressQueue
    let handed = (0..<4).map { Data(repeating: UInt8($0 + 1), count: 128) }
    for bytes in handed { await queue.push(bytes) }
    // The hand-off is full, so a fifth producer can only leave `push` once it is closed — awaiting it
    // is what proves the close landed, instead of racing a yield loop. It must leave without
    // appending, which is why it is absent from what is delivered below.
    let blocked = Task { await queue.push(Data([9])) }
    await transport.close()
    await blocked.value
    var delivered = [Data]()
    while let bytes = await queue.pop() { delivered.append(bytes) }
    XCTAssertEqual(delivered, handed, "Closing the hand-off must not discard what it already accepted")
  }

  /// Closing a transport has to unwind both halves of the hand-off: a consumer waiting on an empty
  /// queue would otherwise strand the delivery task for the life of the process.
  @MainActor func testClosingTheTransportReleasesAWaitingIngressConsumer() async throws {
    let transport = LanTcpTransport(socket(), profile: .lanTransfer)
    let queue = await transport.ingressQueue
    let waiting = Task { await queue.pop() }
    for _ in 0..<50 { await Task.yield() }
    await transport.close()
    let drained = await waiting.value
    XCTAssertNil(drained)
  }
}

private actor IngressProbe {
  private(set) var count = 0
  func pushed() { count += 1 }
}
