// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies reverse consent admission, capability advertising and mutual exclusion without audio hardware.
import AppKit
import Foundation
import XCTest
@testable import aniCe

private actor PhoneModelOutput: PhoneAudioOutput {
  private var prepares = 0
  private var stops = 0
  private var received = [Data]()
  private var holdPreparation = false
  private var preparationGate: CheckedContinuation<Void, Never>?
  private var holdOffer = false
  private var offerGate: CheckedContinuation<Void, Never>?
  private var admission = PhoneAudioOutputAdmission.accepted
  private(set) var preparationWaiting = false
  private(set) var offerWaiting = false
  private(set) var discarded = 0
  func prepare() async throws {
    if holdPreparation {
      preparationWaiting = true
      await withCheckedContinuation { preparationGate = $0 }
      preparationWaiting = false
    }
    prepares += 1
  }
  func offer(_ pcm: Data, afterGap: Bool) async -> PhoneAudioOutputAdmission {
    if holdOffer {
      offerWaiting = true
      await withCheckedContinuation { offerGate = $0 }
      offerWaiting = false
    }
    if admission == .accepted { received.append(pcm) }
    return admission
  }
  func stop() { stops += 1 }
  func discardPending() -> PhoneAudioOutputAdmission { discarded += 1; return admission }
  var queuedFrames: Int { 0 }
  func holdPrepare() { holdPreparation = true }
  func releasePrepare() { holdPreparation = false; preparationGate?.resume(); preparationGate = nil }
  func holdAudio() { holdOffer = true }
  func releaseAudio() { holdOffer = false; offerGate?.resume(); offerGate = nil }
  func setAdmission(_ value: PhoneAudioOutputAdmission) { admission = value }
  func counts() -> (prepares: Int, stops: Int, received: Int) { (prepares, stops, received.count) }
}

@MainActor private final class PhoneModelClock { var time: Int64 = 0 }

@MainActor private final class PhoneModelChannel: SecuredChannel {
  let descriptor: ChannelDescriptor
  let maintenance: ChannelMaintenance?
  var sent = [PhoneAudioMessage]()
  var backpressured = false
  var attempts = 0
  let clock: PhoneModelClock
  init(_ peer: DeviceIdentity, clock: PhoneModelClock, instance: String = "phone-audio") {
    descriptor = ChannelDescriptor(instance: instance, transport: "lan", peer: peer)
    maintenance = ChannelMaintenance(now: { clock.time })
    self.clock = clock
  }
  func sendData(_ bytes: Data) async throws {
    attempts += 1
    if backpressured { throw SessionBackpressure() }
    sent.append(try XCTUnwrap(PhoneAudioMessage.decode(bytes)))
  }
}

@MainActor final class MacPhoneAudioModelTests: XCTestCase {
  private let streamID = "01234567-89ab-4cde-8fab-0123456789ab"

  func testOptInDiagnosticsKeepLocalArrivalCountsAndIgnoreStaleStreams() async throws {
    let (model, _, channel) = try await harness()
    defer { model.shutdown() }
    var time: Int64 = 0
    var reports = [MacPhoneAudioDiagnosticReport]()
    model.diagnosticsEnabled = true
    model.diagnosticNanoTime = { time }
    model.diagnosticSink = { reports.append($0) }
    model.setReceiving(true)
    _ = await model.handle(try start().encode(), on: channel.descriptor)
    time = 20_000_000
    _ = await model.handle(try audio(1).encode(), on: channel.descriptor)
    time = 120_000_000
    _ = await model.handle(try audio(4).encode(), on: channel.descriptor)
    model.tick()
    XCTAssertEqual(reports.count, 1)
    XCTAssertEqual(reports.first?.fields["arrival_interval_max_us"] as? Int64, 100_000)
    XCTAssertEqual(reports.first?.fields["sequence_missing_packets"] as? Int64, 2)
    model.stop()
    _ = await model.handle(try audio(5).encode(), on: channel.descriptor)
    XCTAssertEqual(reports.count, 2)
    XCTAssertEqual(reports.last?.fields["accepted_packets"] as? Int64, 2)
    let text = String(data: try JSONSerialization.data(withJSONObject: reports.last!.fields), encoding: .utf8)!
    XCTAssertFalse(text.contains(streamID))
    XCTAssertFalse(text.contains(channel.descriptor.peer.publicKey))
  }

  func testStartWithoutConsentRepliesDisabledAndKeepsNoOperation() async throws {
    let (model, _, channel) = try await harness()
    defer { model.shutdown() }
    let result = await model.handle(try start().encode(), on: channel.descriptor)
    XCTAssertEqual(result, DataHandling.handled)
    XCTAssertFalse(model.active)
    try await settle { channel.sent.contains { $0.kind == 2 } }
    XCTAssertEqual(try XCTUnwrap(channel.sent.last { $0.kind == 2 }).fields[1], .integer(1))
  }

  func testConsentAdvertisesCapabilityAndAcceptsOneBoundStream() async throws {
    let (model, output, channel) = try await harness()
    defer { model.shutdown() }
    model.setReceiving(true)
    try await settle { channel.sent.last(where: { $0.kind == 0 })?.fields[4] == .bool(true) }
    XCTAssertEqual(try XCTUnwrap(channel.sent.last { $0.kind == 0 }).fields[4], .bool(true))
    let result = await model.handle(try start().encode(), on: channel.descriptor)
    XCTAssertEqual(result, DataHandling.handled)
    XCTAssertTrue(model.active)
    try await settle { channel.sent.contains { $0.kind == 2 } }
    XCTAssertEqual(try XCTUnwrap(channel.sent.last { $0.kind == 2 }).fields[1], .integer(0))
    let prepared = await output.counts()
    XCTAssertEqual(prepared.prepares, 1)
    let accepted = await model.handle(try audio(1).encode(), on: channel.descriptor)
    XCTAssertEqual(accepted, DataHandling.handled)
    let received = await output.counts()
    XCTAssertEqual(received.received, 1)
    XCTAssertEqual(model.acceptedPackets, 1)
    let stopped = await model.handle(try stop().encode(), on: channel.descriptor)
    XCTAssertEqual(stopped, DataHandling.handled)
    XCTAssertFalse(model.active)
  }

  func testForwardListeningBlocksReverseStart() async throws {
    let (model, _, channel) = try await harness()
    defer { model.shutdown() }
    model.setReceiving(true)
    model.forwardActive = { true }
    let result = await model.handle(try start().encode(), on: channel.descriptor)
    XCTAssertEqual(result, DataHandling.handled)
    XCTAssertFalse(model.active)
    try await settle { channel.sent.contains { $0.kind == 2 } }
    XCTAssertEqual(try XCTUnwrap(channel.sent.last { $0.kind == 2 }).fields[1], .integer(2))
  }

  func testForwardTagRemainsUnrecognizedByTheReverseOwner() async throws {
    let (model, _, channel) = try await harness()
    defer { model.shutdown() }
    let result = await model.handle(try AudioSharingMessage.start(streamID: streamID).encode(),
      on: channel.descriptor)
    XCTAssertEqual(result, DataHandling.unrecognized)
  }

  func testDuplicateStartForAnotherStreamIsBusy() async throws {
    let (model, _, channel) = try await harness()
    defer { model.shutdown() }
    model.setReceiving(true)
    _ = await model.handle(try start().encode(), on: channel.descriptor)
    let other = "01234567-89ab-4cde-8fab-0123456789ac"
    _ = await model.handle(try start(other).encode(), on: channel.descriptor)
    try await settle { channel.sent.contains { $0.kind == 2 && $0.fields[1] == .integer(2) } }
    XCTAssertTrue(model.active)
  }

  func testStopDuringNativePreparationFencesLateReadyAndTheOtherDirectionUntilCleanup() async throws {
    let (model, output, channel) = try await harness()
    defer { model.shutdown() }
    var exclusions = [Bool]()
    model.onActiveChanged = { exclusions.append($0) }
    model.setReceiving(true)
    await output.holdPrepare()
    let bytes = try start().encode()
    let pending = Task { await model.handle(bytes, on: channel.descriptor) }
    try await settleAsync { await output.preparationWaiting }
    XCTAssertTrue(model.active)
    _ = await model.handle(bytes, on: channel.descriptor)
    XCTAssertFalse(channel.sent.contains { $0.kind == 2 && $0.fields[1] == .integer(0) })
    model.stop()
    XCTAssertFalse(model.active)
    XCTAssertTrue(model.busy)
    XCTAssertEqual(exclusions, [true])
    _ = await model.handle(try start("01234567-89ab-4cde-8fab-0123456789ac").encode(),
      on: channel.descriptor)
    await output.releasePrepare()
    _ = await pending.value
    try await settle { !model.busy }
    XCTAssertEqual(exclusions.last, false)
    XCTAssertFalse(channel.sent.contains { $0.kind == 2 && $0.fields[1] == .integer(0) })
    let late = await model.handle(try audio(1).encode(), on: channel.descriptor)
    XCTAssertEqual(late, DataHandling.discarded)
    let counts = await output.counts()
    XCTAssertGreaterThanOrEqual(counts.stops, 1)
    XCTAssertEqual(counts.received, 0)
  }

  func testImmediateStopCannotStartANativePreparationTaskThatHasNotRunYet() async throws {
    let (model, output, channel) = try await harness()
    defer { model.shutdown() }
    model.setReceiving(true)
    model.onActiveChanged = { [weak model] active in
      if active { model?.stop() }
    }
    _ = await model.handle(try start().encode(), on: channel.descriptor)
    try await settle { !model.busy }
    let counts = await output.counts()
    XCTAssertEqual(counts.prepares, 0)
    XCTAssertFalse(model.active)
    XCTAssertFalse(channel.sent.contains { $0.kind == 2 && $0.fields[1] == .integer(0) })
  }

  func testRetirementDuringPreparationCannotBindOutputToTheReplacementChannel() async throws {
    let (model, output, channel) = try await harness()
    defer { model.shutdown() }
    model.setReceiving(true)
    await output.holdPrepare()
    let bytes = try start().encode()
    let pending = Task { await model.handle(bytes, on: channel.descriptor) }
    try await settleAsync { await output.preparationWaiting }
    let replacement = PhoneModelChannel(channel.descriptor.peer, clock: channel.clock,
      instance: "replacement")
    model.available(replacement)
    try await settle { model.localReady }
    XCTAssertFalse(model.receivingEnabled)
    await output.releasePrepare()
    _ = await pending.value
    try await settle { !model.busy }
    XCTAssertFalse(model.active)
    XCTAssertFalse(replacement.sent.contains { $0.kind == 2 && $0.fields[1] == .integer(0) })
    let stale = await model.handle(try audio(1).encode(), on: channel.descriptor)
    XCTAssertEqual(stale, DataHandling.unrecognized)
    let unbound = await model.handle(try audio(1).encode(), on: replacement.descriptor)
    XCTAssertEqual(unbound, DataHandling.discarded)
  }

  func testDisablingConsentStopsLocallyAndRetainsStopAndDisabledCapabilityUnderBackpressure() async throws {
    let (model, output, channel) = try await harness()
    defer { model.shutdown() }
    model.setReceiving(true)
    _ = await model.handle(try start().encode(), on: channel.descriptor)
    try await settle { channel.sent.contains { $0.kind == 2 } }
    channel.backpressured = true
    model.setReceiving(false)
    XCTAssertFalse(model.active)
    try await settle { !model.busy }
    let after = channel.attempts
    for _ in 0..<10 { model.tick() }
    XCTAssertEqual(channel.attempts, after)
    channel.backpressured = false
    model.capacityAvailable(channel.descriptor)
    try await settle {
      channel.sent.contains { $0.kind == 4 } &&
        channel.sent.last(where: { $0.kind == 0 })?.fields[4] == .bool(false)
    }
    let counts = await output.counts()
    XCTAssertGreaterThanOrEqual(counts.stops, 1)
    let late = await model.handle(try audio(1).encode(), on: channel.descriptor)
    XCTAssertEqual(late, DataHandling.discarded)
  }

  func testStoppedStreamIDsCannotBeReusedAndLiveDuplicateStartIsIdempotent() async throws {
    let (model, output, channel) = try await harness()
    defer { model.shutdown() }
    model.setReceiving(true)
    _ = await model.handle(try start().encode(), on: channel.descriptor)
    _ = await model.handle(try start().encode(), on: channel.descriptor)
    let before = await output.counts()
    XCTAssertEqual(before.prepares, 1)
    model.stop()
    try await settle { !model.busy }
    _ = await model.handle(try start().encode(), on: channel.descriptor)
    XCTAssertFalse(model.active)
    try await settle {
      channel.sent.last(where: { $0.kind == 2 && $0.fields[0] == .text(self.streamID) })?.fields[1] == .integer(2)
    }
    let after = await output.counts()
    XCTAssertEqual(after.prepares, 1)
  }

  func testConsentPersistsOnlyForTheLocalIdentityAndCompletePhoneCredential() async throws {
    let suite = "phone-audio-test.\(UUID().uuidString)"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let (first, _, channel) = try await harness(preferences: preferences)
    XCTAssertFalse(first.receivingEnabled)
    first.setReceiving(true)
    first.shutdown()
    try await settle { !first.busy }
    let (same, _, _) = try await harness(preferences: preferences)
    defer { same.shutdown() }
    XCTAssertTrue(same.receivingEnabled)
    let (changedLocal, _, _) = try await harness(preferences: preferences, local: "replacement-local")
    defer { changedLocal.shutdown() }
    XCTAssertFalse(changedLocal.receivingEnabled)
    let peer = channel.descriptor.peer
    var forgedCredential = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(peer)) as? [String: Any])
    forgedCredential["publicKey"] = "replacement-key"
    // An in-memory negative fixture, never a credential admitted by real session authentication.
    let changedKey = try JSONDecoder().decode(DeviceIdentity.self,
      from: JSONSerialization.data(withJSONObject: forgedCredential))
    let (changedPhone, _, changedChannel) = try await harness(preferences: preferences, peer: changedKey)
    defer { changedPhone.shutdown() }
    XCTAssertFalse(changedPhone.receivingEnabled)
    let forged = await same.handle(try start().encode(), on: changedChannel.descriptor)
    XCTAssertEqual(forged, DataHandling.unrecognized)
    XCTAssertFalse(same.active)
  }

  func testPreparationTimeoutDoesNotAcceptLateNativeSuccess() async throws {
    let (model, output, channel) = try await harness()
    defer { model.shutdown() }
    model.setReceiving(true)
    await output.holdPrepare()
    let bytes = try start().encode()
    let pending = Task { await model.handle(bytes, on: channel.descriptor) }
    try await settleAsync { await output.preparationWaiting }
    channel.clock.time = 5000
    model.tick()
    XCTAssertFalse(model.active)
    await output.releasePrepare()
    _ = await pending.value
    try await settle { !model.busy }
    try await settle { channel.sent.contains { $0.kind == 2 && $0.fields[1] == .integer(9) } }
    XCTAssertFalse(channel.sent.contains { $0.kind == 2 && $0.fields[1] == .integer(0) })
  }

  func testMaintenancePreservesTheStreamButClearsOldOutputAndExcludesOnlyItsInterval() async throws {
    let (model, output, channel) = try await harness()
    defer { model.shutdown() }
    model.setReceiving(true)
    _ = await model.handle(try start().encode(), on: channel.descriptor)
    _ = await model.handle(try audio(1).encode(), on: channel.descriptor)
    channel.clock.time = 1000
    channel.maintenance?.update(SessionMaintenanceSnapshot(sinceMillis: 1000, revision: 1))
    model.capacityAvailable(channel.descriptor)
    let during = await model.handle(try audio(2).encode(), on: channel.descriptor)
    XCTAssertEqual(during, DataHandling.discarded)
    XCTAssertEqual(model.state, 4)
    channel.clock.time = 45000
    model.tick()
    XCTAssertTrue(model.active)
    channel.maintenance?.update(SessionMaintenanceSnapshot(elapsedMillis: 44000, revision: 2))
    model.capacityAvailable(channel.descriptor)
    try await settleAsync { await output.discarded >= 2 }
    let fresh = await model.handle(try audio(3).encode(), on: channel.descriptor)
    XCTAssertEqual(fresh, DataHandling.handled)
    XCTAssertEqual(model.acceptedPackets, 2)
    XCTAssertEqual(model.gapPackets, 1)
    channel.clock.time = 55000
    model.tick()
    XCTAssertFalse(model.active)
    try await settle { !model.busy }
  }

  func testLateAudioCompletionAfterStopCannotRestoreCountersOrOwnership() async throws {
    let (model, output, channel) = try await harness()
    defer { model.shutdown() }
    model.setReceiving(true)
    _ = await model.handle(try start().encode(), on: channel.descriptor)
    await output.holdAudio()
    let bytes = try audio(1).encode()
    let pending = Task { await model.handle(bytes, on: channel.descriptor) }
    try await settleAsync { await output.offerWaiting }
    model.stop()
    await output.releaseAudio()
    let result = await pending.value
    XCTAssertEqual(result, DataHandling.discarded)
    try await settle { !model.busy }
    XCTAssertFalse(model.active)
    XCTAssertEqual(model.acceptedPackets, 0)
  }

  func testOutputLossStopsAndReportsRatherThanAcceptingSilentPackets() async throws {
    let (model, output, channel) = try await harness()
    defer { model.shutdown() }
    model.setReceiving(true)
    _ = await model.handle(try start().encode(), on: channel.descriptor)
    await output.setAdmission(.unavailable)
    _ = await model.handle(try audio(1).encode(), on: channel.descriptor)
    XCTAssertFalse(model.active)
    try await settle { channel.sent.contains { $0.kind == 4 && $0.fields[1] == .integer(6) } }
    let late = await model.handle(try audio(2).encode(), on: channel.descriptor)
    XCTAssertEqual(late, DataHandling.discarded)
  }

  func testSleepStopsTheNativeOwnerAndDoesNotRestartIt() async throws {
    let (model, _, channel) = try await harness()
    defer { model.shutdown() }
    model.installLifecycle()
    model.setReceiving(true)
    _ = await model.handle(try start().encode(), on: channel.descriptor)
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
    try await settle { !model.busy }
    XCTAssertFalse(model.active)
    let late = await model.handle(try audio(1).encode(), on: channel.descriptor)
    XCTAssertEqual(late, DataHandling.discarded)
  }

  func testOfflineSetReceivingTriggersLanRequiredAndBackpressuredStopWaitsForCapacity() async throws {
    let clock = PhoneModelClock()
    let offline = MacPhoneAudioModel(receiver: PhoneAudioReceiver(output: PhoneModelOutput()),
      now: { clock.time }, automaticTicks: false)
    defer { offline.shutdown() }
    var lanRequests = 0
    offline.onLanRequired = { lanRequests += 1; return false }
    offline.setReceiving(true)
    XCTAssertEqual(lanRequests, 1)

    let (model, _, channel) = try await harness()
    defer { model.shutdown() }
    model.setReceiving(true)
    channel.backpressured = true
    _ = await model.handle(try start().encode(), on: channel.descriptor)
    try await settle { channel.attempts >= 1 }
    let attemptsAtBackpressure = channel.attempts
    for _ in 0..<10 { model.tick() }
    XCTAssertEqual(channel.attempts, attemptsAtBackpressure)

    channel.backpressured = false
    model.capacityAvailable(channel.descriptor)
    try await settle { channel.sent.contains { $0.kind == 2 && $0.fields[1] == .integer(0) } }
  }

  func testPlaybackCounterTracksSynchronousCompletionsAndEpochResets() {
    let counter = PhoneAudioPlaybackCounter()
    let epoch = counter.enqueue(recordDiagnostics: true)
    _ = counter.enqueue(recordDiagnostics: true)
    XCTAssertEqual(counter.pending, 2)
    counter.complete(epoch: epoch, scheduledAt: 100)
    XCTAssertEqual(counter.pending, 1)
    counter.complete(epoch: epoch, scheduledAt: 200)
    XCTAssertEqual(counter.pending, 0)
    _ = counter.enqueue(recordDiagnostics: true)
    counter.resetQueue()
    XCTAssertEqual(counter.pending, 0)
    let nextEpoch = counter.enqueue(recordDiagnostics: true)
    counter.complete(epoch: epoch, scheduledAt: 300)
    XCTAssertEqual(counter.pending, 1, "A cancelled buffer cannot consume the replacement queue")
    counter.complete(epoch: nextEpoch, scheduledAt: 400)
    counter.complete(epoch: nextEpoch, scheduledAt: 400)
    let snapshot = counter.snapshot(diagnosticsEnabled: true, unavailableDrops: 0, resyncs: 1)
    XCTAssertEqual(snapshot.resyncs, 1)
    XCTAssertEqual(snapshot.emptyPendingTransitions, 2)
    XCTAssertEqual(snapshot.renderedCallbacks, 3)
  }

  private func harness(preferences: UserDefaults? = nil, local: String = "local-identity",
    peer replacement: DeviceIdentity? = nil) async throws -> (MacPhoneAudioModel, PhoneModelOutput, PhoneModelChannel) {
    let helper = SessionFixtures()
    let row = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    let peer = try replacement ?? helper.identity(row, "initiator")
    let clock = PhoneModelClock()
    let output = PhoneModelOutput()
    let model = MacPhoneAudioModel(receiver: PhoneAudioReceiver(output: output), preferences: preferences,
      localFingerprint: { local }, now: { clock.time }, automaticTicks: false)
    let channel = PhoneModelChannel(peer, clock: clock)
    model.available(channel)
    try await settle { model.localReady }
    return (model, output, channel)
  }

  private func settle(_ condition: @escaping () -> Bool) async throws {
    for _ in 0..<1000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Phone audio task did not settle")
    throw SessionFailure.expired
  }

  private func settleAsync(_ condition: @escaping () async -> Bool) async throws {
    for _ in 0..<1000 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Phone audio task did not settle")
    throw SessionFailure.expired
  }

  private func start(_ id: String? = nil) -> PhoneAudioMessage {
    PhoneAudioMessage(kind: 1, fields: [.text(id ?? streamID), .integer(48000), .integer(2),
      .integer(16), .integer(960)])
  }

  private func audio(_ sequence: Int64) -> PhoneAudioMessage {
    PhoneAudioMessage(kind: 3, fields: [.text(streamID), .integer(sequence),
      .integer((sequence - 1) * 960), .bytes(Data(count: 3840))])
  }

  private func stop() -> PhoneAudioMessage {
    PhoneAudioMessage(kind: 4, fields: [.text(streamID), .integer(0)])
  }
}
