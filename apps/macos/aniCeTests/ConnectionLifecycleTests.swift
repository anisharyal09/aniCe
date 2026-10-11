// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies pairing contracts, durable trust and exclusive BLE ownership across native lifecycle faults.
import CryptoKit
import Foundation
import XCTest

@testable import aniCe

@MainActor private final class SessionRadioFake: SessionPeripheralAdapter {
  var pairingWrite: ((Data) -> Bool)?
  var pairingDisconnect: (() -> Void)?
  var sessionWrite: ((Data) -> Bool)?
  var sessionDisconnect: (() -> Void)?
  var sessionAdmitted: (() -> Bool)?
  var event: ((PeripheralEvent) -> Void)?
  var started = false
  var resumes = 0
  var stopped = 0
  var retirement = 0
  func begin(
    event: @escaping (PeripheralEvent) -> Void, read: @escaping (Bool, Int) -> DiscoveryRead
  ) {
    self.event = event
    started = true
    event(.available)
  }
  func publish() { event?(.published) }
  func advertise() { event?(.advertising) }
  func stop() {
    stopped += 1
    event = nil
  }
  func sendPairing(_ message: Data) throws { throw PairingFailure.transport }
  func drainPairing() async {}
  func retirePairingConnection() { retirement += 1 }
  func sessionCapacity(_ bytes: Int) -> Bool { true }
  var sent: [Data] = []
  var failReadyAck = false
  func sendSession(_ message: Data) async throws {
    if failReadyAck, message.first == 6 { throw SessionFailure.authentication }
    sent.append(message)
  }
  func resumeSessionAdvertising() { resumes += 1 }
  func tickSessionTransport() throws {}
}
@MainActor private final class SessionRecoveryWait {
  var delays = [TimeInterval]()
  var continuation: CheckedContinuation<Void, Never>?
  func pause(_ delay: TimeInterval) async {
    delays.append(delay)
    await withCheckedContinuation { continuation = $0 }
  }
  func release() { continuation?.resume(); continuation = nil }
}
@MainActor final class SessionLifecycleTests: XCTestCase {
  func testLatePairingCleanupRespectsDiscoveryPairingAndStop() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("trust.json")
    let trust = try PeerTrustStore(url: url), memory = PairingMemoryIdentity()
    let service = IdentityService(storage: memory, deviceName: "Mac test", tagPrefix: "radio.test.")
    _ = try await service.publicIdentity()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let savedIdentity = try encoder.encode(memory.record), savedTrust = try Data(contentsOf: url)
    let radio = SessionRadioFake(), discovery = MacDiscoveryModel(adapter: radio)
    let pairing = MacPairingModel(identity: service, discovery: discovery, makeStore: { trust })
    let session = MacSessionModel(identity: service, adapter: radio, store: { trust })
    AniCeApp.configureSessionLifecycle(session: session, pairing: pairing, discovery: discovery)
    defer {
      session.quit(); pairing.cancel(); discovery.stop()
      session.beforeAllow = {}; pairing.beforePairing = {}; pairing.trustRemoved = {}; discovery.beforeStart = {}
    }
    session.setAutomatic(true)
    pairing.start(.qr)
    let lateCleanup = pairing.afterPairing
    lateCleanup()
    XCTAssertTrue(pairing.active); XCTAssertFalse(session.allowing)
    pairing.cancel()
    discovery.start()
    XCTAssertTrue(discovery.session.active)
    let stopped = radio.stopped
    lateCleanup() // Deliver the old completion after discovery has acquired the shared radio.
    XCTAssertTrue(discovery.session.active); XCTAssertFalse(session.allowing)
    XCTAssertEqual(radio.stopped, stopped)
    discovery.stop()
    lateCleanup() // Positive control: idle radio still restores enabled automatic availability.
    XCTAssertTrue(session.allowing)
    session.disconnect()
    lateCleanup()
    XCTAssertFalse(session.allowing); XCTAssertFalse(session.automatic)
    XCTAssertEqual(try Data(contentsOf: url), savedTrust)
    XCTAssertEqual(try encoder.encode(memory.record), savedIdentity)
  }

  func testProductionModelReadinessAndAuthenticatedPeerFeedback() async throws {
    try await exerciseProductionModel(failReadyAck: false)
  }
  func testProductionModelReadinessFailurePreservesIdentityAndTrust() async throws {
    try await exerciseProductionModel(failReadyAck: true)
  }
  private func exerciseProductionModel(failReadyAck: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("trust.json")
    let trust = try PeerTrustStore(url: url)
    let memory = PairingMemoryIdentity()
    let service = IdentityService(
      storage: memory, deviceName: "Mac test", tagPrefix: "session.test.")
    let mac = try await service.publicIdentity()
    let key = P256.Signing.PrivateKey()
    let android = try DeviceIdentity.decode(
      JSONSerialization.data(withJSONObject: [
        "identitySchemaVersion": 1, "algorithm": "ECDSA_P256_SHA256", "platform": "android",
        "deviceId": UUID().uuidString.lowercased(), "deviceName": "Phone test",
        "publicKey": key.publicKey.x963Representation.base64EncodedString(),
        "fingerprint": DeviceIdentity.fingerprint(key.publicKey.x963Representation),
      ]))
    let hash = Data(repeating: 7, count: 32)
    try trust.prepare(
      PeerTrustRecord(
        peer: android, localFingerprint: mac.fingerprint,
        method: .qr, pairedAt: Date(), transcriptHash: hash, active: false))
    try trust.activate(
      peerID: android.deviceId, hash: hash,
      receipt: key.signature(for: PairingCodec.receipt(hash, 1)).derRepresentation)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let savedIdentity = try encoder.encode(memory.record)
    let savedTrust = try Data(contentsOf: url)
    let radio = SessionRadioFake()
    radio.failReadyAck = failReadyAck
    let model = MacSessionModel(identity: service, adapter: radio, store: { trust })
    defer { model.cancel() }
    model.allow()
    try await waitFor { radio.started }
    try await waitFor { model.maintenanceDeadline != nil }
    XCTAssertGreaterThan(try XCTUnwrap(model.maintenanceDeadline) - ProcessInfo.processInfo.systemUptime, 100)
    XCTAssertTrue(radio.sessionAdmitted?() ?? false)
    XCTAssertFalse(radio.sessionAdmitted?() ?? true)
    let client = try SessionHandshakeEngine(
      local: android, responder: false,
      trusted: { [mac] }, currentIdentity: { android },
      signer: {
        SignedIdentityPayload(
          identity: android, signature: try key.signature(for: $0).derRepresentation)
      }, selectedPeer: mac)
    let message1 = try await client.initiate()
    XCTAssertTrue(radio.sessionWrite?(try SessionEnvelope.encode(1, message1)) ?? false)
    try await waitFor { !radio.sent.isEmpty }
    let message2 = try SessionEnvelope.decode(radio.sent.removeFirst())
    XCTAssertEqual(message2.0, 2)
    let message3 = try await client.authenticateResponder(message2.1)
    XCTAssertTrue(radio.sessionWrite?(try SessionEnvelope.encode(3, message3)) ?? false)
    try await waitFor { !radio.sent.isEmpty }
    let message4 = try SessionEnvelope.decode(radio.sent.removeFirst())
    XCTAssertEqual(message4.0, 4)
    try await client.confirmResponder(message4.1)
    XCTAssertEqual(model.state, "Connecting")
    XCTAssertEqual(model.receivedChecks, 0)
    let records = PairingBus()
    let channel = try await SecureSession.fromHandshake(
      client, responder: false,
      capacity: { _ in true }, submit: { await records.send($0) })
    try await channel.send(.ready)
    let readyRecords = await records.take()
    let ready = try XCTUnwrap(readyRecords.first)
    XCTAssertTrue(radio.sessionWrite?(try SessionEnvelope.encode(6, ready)) ?? false)
    if failReadyAck {
      try await waitFor { model.state == "Failed" }
      try await waitFor { model.maintenanceDeadline != nil }
      XCTAssertGreaterThan(try XCTUnwrap(model.maintenanceDeadline) - ProcessInfo.processInfo.systemUptime, 100)
      XCTAssertTrue(radio.sent.isEmpty)
      XCTAssertEqual(model.receivedChecks, 0)
      let stage = await channel.stage
      XCTAssertEqual(stage, .readySent)
    } else {
      try await waitFor { model.state == "Secured" }
      try await waitFor { model.maintenanceDeadline != nil }
      let wait = try XCTUnwrap(model.maintenanceDeadline) - ProcessInfo.processInfo.systemUptime
      XCTAssertGreaterThan(wait, 8) // Legacy control compatibility remains bounded at ten seconds.
      XCTAssertLessThanOrEqual(wait, 10.1)
      XCTAssertTrue(model.status.contains(android.deviceName))
      let ack = try SessionEnvelope.decode(try XCTUnwrap(radio.sent.first))
      XCTAssertEqual(ack.0, 6)
      _ = try await channel.receive(ack.1)
      try await channel.send(.data, plaintext: Data("aniCe connection check".utf8))
      let dataRecords = await records.take()
      let data = try XCTUnwrap(dataRecords.first)
      XCTAssertTrue(radio.sessionWrite?(try SessionEnvelope.encode(6, data)) ?? false)
      try await waitFor { model.receivedChecks == 1 }
      model.checkConnection()
      try await waitFor { radio.sent.count == 2 }
      let response = try SessionEnvelope.decode(radio.sent[1])
      let received = try await channel.receive(response.1)
      XCTAssertEqual(received.0, .data)
      XCTAssertEqual(received.1, Data("aniCe connection check".utf8))
      model.cancel()
      XCTAssertNil(model.maintenanceDeadline)
      radio.started = false
      model.allow()
      try await waitFor { radio.started }
      try await waitFor { model.maintenanceDeadline != nil }
      XCTAssertGreaterThan(try XCTUnwrap(model.maintenanceDeadline) - ProcessInfo.processInfo.systemUptime, 100)
      XCTAssertEqual(model.state, "Disconnected")
    }
    XCTAssertEqual(try encoder.encode(memory.record), savedIdentity)
    XCTAssertEqual(try Data(contentsOf: url), savedTrust)
    await channel.close()
    await client.close()
  }
  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<2000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Production model transition did not complete")
    throw SessionFailure.expired
  }
  func testAutomaticAdmissionCooldownPauseSleepAndTrustBinding() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("trust.json")
    let trust = try PeerTrustStore(url: url)
    let memory = PairingMemoryIdentity()
    let service = IdentityService(storage: memory, deviceName: "Mac test", tagPrefix: "auto.test.")
    let mac = try await service.publicIdentity(), key = P256.Signing.PrivateKey()
    let android = try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: [
      "identitySchemaVersion": 1, "algorithm": "ECDSA_P256_SHA256", "platform": "android",
      "deviceId": UUID().uuidString.lowercased(), "deviceName": "Phone test",
      "publicKey": key.publicKey.x963Representation.base64EncodedString(),
      "fingerprint": DeviceIdentity.fingerprint(key.publicKey.x963Representation),
    ]))
    let hash = Data(repeating: 9, count: 32)
    try trust.prepare(PeerTrustRecord(peer: android, localFingerprint: mac.fingerprint,
      method: .qr, pairedAt: Date(), transcriptHash: hash, active: false))
    try trust.activate(peerID: android.deviceId, hash: hash,
      receipt: key.signature(for: PairingCodec.receipt(hash, 1)).derRepresentation)
    let savedTrust = try Data(contentsOf: url)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let savedIdentity = try encoder.encode(memory.record)
    let suite = "anice.auto.test.\(UUID().uuidString)"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let radio = SessionRadioFake(), cooldown = SessionRecoveryWait()
    var clock: TimeInterval = 0
    let model = MacSessionModel(identity: service, adapter: radio, store: { trust }, now: { clock },
      preferences: preferences, wait: { await cooldown.pause($0) })
    defer { model.cancel(); cooldown.release() }
    XCTAssertFalse(model.automatic)
    model.selectedPeer = android
    model.setAutomatic(true)
    try await waitFor { radio.started }
    let stale = radio.sessionAdmitted
    clock = 120; radio.started = false; model.tick()
    try await waitFor { radio.started }
    XCTAssertFalse(stale?() ?? true)
    XCTAssertTrue(model.automatic)
    for index in 1...5 {
      XCTAssertTrue(radio.sessionAdmitted?() ?? false)
      XCTAssertFalse(radio.sessionAdmitted?() ?? true)
      XCTAssertTrue(radio.sessionWrite?(Data([0])) ?? false)
      if index < 5 { try await waitFor { radio.resumes == index } }
      else { try await waitFor { !cooldown.delays.isEmpty } }
    }
    XCTAssertEqual(cooldown.delays, [120])
    model.allow() // A pending admission cooldown cannot be bypassed by a manual command.
    XCTAssertFalse(model.allowing)
    XCTAssertNil(radio.sessionAdmitted)
    // Stop wins even if the timer continuation is already queued for delivery.
    model.disconnect(); radio.started = false; cooldown.release()
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(radio.started); XCTAssertFalse(model.automatic)
    XCTAssertTrue(preferences.bool(forKey: "session.paused"))
    model.restoreAutomatic(); XCTAssertFalse(model.automatic)
    model.setAutomatic(true); try await waitFor { radio.started }
    let beforeSleep = radio.sessionAdmitted
    model.sleep(); XCTAssertFalse(model.allowing)
    XCTAssertFalse(beforeSleep?() ?? true)
    radio.started = false; model.wake(); try await waitFor { radio.started }
    model.suspendAutomatic(); XCTAssertFalse(model.allowing)
    radio.started = false; model.resumeAutomatic(); try await waitFor { radio.started }
    model.setAutomatic(false); radio.started = false
    model.resumeAutomatic(); XCTAssertFalse(radio.started)
    // Restored policy must not bind a remembered peer to a different local identity.
    preferences.set(true, forKey: "session.automatic")
    preferences.set(false, forKey: "session.paused")
    preferences.set("changed", forKey: "session.local")
    model.restoreAutomatic()
    try await waitFor { model.state == "Failed" }
    XCTAssertFalse(radio.started); XCTAssertFalse(model.automatic)
    XCTAssertEqual(try Data(contentsOf: url), savedTrust)
    XCTAssertEqual(try encoder.encode(memory.record), savedIdentity)
    model.quit(); model.wake(); XCTAssertFalse(model.allowing)
  }
  func testServiceRevocationClosesPendingBleOwnerAndIgnoresOtherJournals() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Mac test", tagPrefix: "revocation.test.")
    let mac = try await identity.publicIdentity(), key = P256.Signing.PrivateKey()
    let phone = try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: [
      "identitySchemaVersion": 1, "algorithm": "ECDSA_P256_SHA256", "platform": "android",
      "deviceId": UUID().uuidString.lowercased(), "deviceName": "Phone test",
      "publicKey": key.publicKey.x963Representation.base64EncodedString(),
      "fingerprint": DeviceIdentity.fingerprint(key.publicKey.x963Representation),
    ]))
    let hash = Data(repeating: 9, count: 32)
    try trust.prepare(PeerTrustRecord(peer: phone, localFingerprint: mac.fingerprint,
      method: .qr, pairedAt: Date(), transcriptHash: hash, active: false))
    try trust.activate(peerID: phone.deviceId, hash: hash,
      receipt: key.signature(for: PairingCodec.receipt(hash, 1)).derRepresentation)
    let radio = SessionRadioFake(), peers = SessionPeerReservation()
    let ble = MacSessionModel(identity: identity, adapter: radio, store: { trust }, peers: peers)
    ble.selectedPeer = phone
    ble.allow()
    try await waitFor { radio.started }
    XCTAssertTrue(ble.allowing)
    XCTAssertEqual(peers.peer, phone)
    let stale = try XCTUnwrap(radio.sessionAdmitted)
    let unrelated = try PeerTrustStore(url: directory.appendingPathComponent("other.json"))
    try unrelated.remove(phone.deviceId)
    XCTAssertTrue(ble.allowing)
    // A distinct instance of the owning journal still invalidates admission before its durable write.
    let sameJournal = try PeerTrustStore(url: trust.location)
    try sameJournal.remove(phone.deviceId)
    XCTAssertTrue(sameJournal.list(localFingerprint: mac.fingerprint).isEmpty)
    XCTAssertFalse(ble.allowing)
    XCTAssertFalse(stale())
    XCTAssertNil(peers.peer)
  }

  func testExpiryCancellationStaleCallbacksAndDurableState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("trust.json")
    let trust = try PeerTrustStore(url: url)
    let memory = PairingMemoryIdentity()
    let identity = IdentityService(
      storage: memory, deviceName: "Mac test", tagPrefix: "session.test.")
    _ = try await identity.publicIdentity()
    let identityEncoder = JSONEncoder()
    identityEncoder.outputFormatting = [.sortedKeys]
    let savedIdentity = try identityEncoder.encode(memory.record)
    let savedTrust = try Data(contentsOf: url)
    let radio = SessionRadioFake()
    var clock: TimeInterval = 0
    let model = MacSessionModel(
      identity: identity, adapter: radio, store: { trust }, now: { clock })
    model.allow()
    for _ in 0..<200 {
      if radio.started { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertTrue(radio.started)
    XCTAssertTrue(model.allowing)
    let staleAdmission = radio.sessionAdmitted
    let staleEvent = radio.event
    clock = 120
    model.tick()
    XCTAssertFalse(model.allowing)
    XCTAssertEqual(model.state, "Disconnected")
    XCTAssertFalse(staleAdmission?() ?? true)
    staleEvent?(.advertising)
    XCTAssertFalse(model.allowing)
    XCTAssertEqual(try Data(contentsOf: url), savedTrust)
    XCTAssertEqual(try identityEncoder.encode(memory.record), savedIdentity)
    clock = 200
    radio.started = false
    model.allow()
    for _ in 0..<200 {
      if radio.started { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertTrue(radio.sessionAdmitted?() ?? false)
    XCTAssertFalse(radio.sessionAdmitted?() ?? true)
    clock = 230
    model.tick()
    XCTAssertEqual(model.state, "Failed")
    XCTAssertTrue(model.allowing)
    try await waitFor { radio.resumes == 1 }
    XCTAssertGreaterThan(radio.retirement, 0)
    model.cancel()
    XCTAssertNil(radio.sessionWrite)
    XCTAssertNil(radio.sessionAdmitted)
    XCTAssertEqual(try Data(contentsOf: url), savedTrust)
    XCTAssertEqual(try identityEncoder.encode(memory.record), savedIdentity)
  }
}

@MainActor final class FeatureDispatchTests: XCTestCase {
  private final class Handler: FeatureHandler {
    var channel: (any SecuredChannel)?
    var retirement = 0, capacity = 0, received = 0
    var result = DataHandling.unrecognized
    func available(_ channel: any SecuredChannel) { self.channel=channel }
    func retired(_ descriptor: ChannelDescriptor) { retirement += 1 }
    func capacityAvailable(_ descriptor: ChannelDescriptor) { capacity += 1 }
    func handle(_ bytes: Data, on descriptor: ChannelDescriptor) -> DataHandling { received += 1; return result }
  }
  func testRetiredChannelsBoundsAndConnectionCheckFallback() async throws {
    let fixture=SessionFixtures(), root=try fixture.root()
    let row=try XCTUnwrap((root["valid"] as? [[String:Any]])?.first)
    let peer=try fixture.identity(row,"initiator")
    let dispatch=FeatureDispatch(), handler=Handler(); dispatch.register(handler)
    var sends=0
    dispatch.available(ChannelDescriptor(instance:"first",transport:"ble",peer:peer)) { _ in sends += 1 }
    let old=try XCTUnwrap(handler.channel)
    XCTAssertEqual(dispatch.handle(Data([1]),transport:"ble",instance:"first"),.unrecognized)
    handler.result = .discarded
    XCTAssertEqual(dispatch.handle(Data([1]),transport:"ble",instance:"first"),.discarded)
    dispatch.capacityAvailable("ble"); XCTAssertEqual(handler.capacity,1)
    dispatch.available(ChannelDescriptor(instance:"second",transport:"ble",peer:peer)) { _ in sends += 1 }
    XCTAssertEqual(handler.retirement,1)
    XCTAssertEqual(dispatch.handle(Data([1]),transport:"ble",instance:"first"),.discarded)
    XCTAssertEqual(handler.received,2)
    do { try await old.sendData(Data([1])); XCTFail("Retired channel sent DATA") } catch let error as SessionFailure { XCTAssertEqual(error,.cancelled) }
    XCTAssertEqual(sends,0)
    let current=try XCTUnwrap(handler.channel)
    try await current.sendData(Data(count:4000)); XCTAssertEqual(sends,1)
    do { try await current.sendData(Data(count:4001)); XCTFail("Oversized DATA sent") } catch let error as SessionFailure { XCTAssertEqual(error,.malformed) }
    XCTAssertEqual(sends,1)
    dispatch.retired("ble"); dispatch.capacityAvailable("ble"); XCTAssertEqual(handler.capacity,1)
  }
}
