// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies explicit capture readiness, stale callbacks, watchdogs and retained-channel maintenance with native capture fakes.
import Foundation
import XCTest
@testable import aniCe

private actor ListeningCaptureFake: PrivateListeningCapturing {
  var prepared = 0
  var activated = 0
  var stopped = 0
  var forwards = [Bool]()
  var muting = [Bool]()
  var failure = false
  var activationGate: CheckedContinuation<Void, Never>?
  var holdActivation = false
  var batch = MacAudioTapBatch(
    packets: [PrivateListeningCapturedPacket(sequence: 1, pcm: Data(count: 3840))],
    sourceFrames: 960, queuedFrames: 0, droppedFrames: 0)
  func prepare() throws { prepared += 1 }
  func activate(alsoPlayThroughMacSpeakers: Bool) async throws {
    if holdActivation { await withCheckedContinuation { activationGate = $0 } }
    if failure { throw MacAudioTapError.unavailable }
    activated += 1
    muting.append(!alsoPlayThroughMacSpeakers)
  }
  func setMuting(_ muted: Bool) throws { muting.append(muted) }
  func setForwarding(_ enabled: Bool) throws { forwards.append(enabled) }
  func read() throws -> MacAudioTapBatch {
    batch
  }
  func stop() throws { stopped += 1 }
  func setFailure(_ value: Bool) { failure = value }
  func hold() { holdActivation = true }
  func release() { holdActivation = false; activationGate?.resume(); activationGate = nil }
  func setBatch(_ value: MacAudioTapBatch) { batch = value }
}

@MainActor private final class ListeningModelClock {
  var time: Int64 = 0
}
@MainActor private final class ListeningModelChannel: SecuredChannel {
  let descriptor: ChannelDescriptor
  let maintenance: ChannelMaintenance?
  var sent = [PrivateListeningMessage]()
  init(_ peer: DeviceIdentity, clock: ListeningModelClock, instance: String = "listening-channel") {
    descriptor = ChannelDescriptor(instance: instance, transport: "lan", peer: peer)
    maintenance = ChannelMaintenance(now: { clock.time })
  }
  func sendData(_ bytes: Data) async throws { sent.append(try XCTUnwrap(PrivateListeningMessage.decode(bytes))) }
}

@MainActor final class MacPrivateListeningTests: XCTestCase {
  func testCaptureBurstKeepsOnlyTheNewestUnsealedPacketsOnTheSameStream() async throws {
    let (model, capture, _, channel) = try await preparedModel()
    model.start()
    try await settle { channel.sent.contains { $0.kind == 1 } }
    let id = try XCTUnwrap(channel.sent.first { $0.kind == 1 }).text(0)
    _ = await model.handle(try PrivateListeningMessage(kind: 2,
      fields: [.text(id), .integer(0)]).encode(), on: channel.descriptor)
    try await settle { model.state == 2 }
    await capture.setBatch(MacAudioTapBatch(packets: (1...10).map {
      PrivateListeningCapturedPacket(sequence: Int64($0), pcm: Data(count: 3840))
    }, sourceFrames: 9600, queuedFrames: 0, droppedFrames: 0))
    await model.tick()
    try await settle { channel.sent.filter { $0.kind == 3 }.count == 3 }
    XCTAssertEqual(channel.sent.filter { $0.kind == 3 }.map { $0.number(1) }, [8, 9, 10])
    XCTAssertEqual(channel.sent.filter { $0.kind == 1 }.count, 1)
    model.stop()
    try await settle { !model.busy }
  }

  func testHealthyBalancedUpperBufferCanRecoverTransferCreditWithoutRelaxingBadHealth() async throws {
    let (model, _, _, channel) = try await preparedModel()
    var health = [Bool]()
    model.transferHealth = { healthy, _, _ in health.append(healthy) }
    model.start()
    try await settle { channel.sent.contains { $0.kind == 1 } }
    let id = try XCTUnwrap(channel.sent.first { $0.kind == 1 }).text(0)
    _ = await model.handle(try PrivateListeningMessage(kind: 2,
      fields: [.text(id), .integer(0)]).encode(), on: channel.descriptor)
    try await settle { model.state == 2 }
    for (state, queued) in [(2, 11520), (2, 12480), (2, 13440), (2, 13441), (5, 11520), (3, 11520)] {
      _ = await model.handle(try PrivateListeningMessage(kind: 5, fields: [
        .text(id), .integer(1), .integer(Int64(state)), .integer(10), .integer(9600),
        .integer(Int64(queued)), .integer(0)]).encode(), on: channel.descriptor)
    }
    XCTAssertEqual(health, [true, true, true, false, false, false])
    model.stop()
    try await settle { !model.busy }
  }

  private func peer() throws -> DeviceIdentity {
    let helper = SessionFixtures()
    let row = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    return try helper.identity(row, "initiator")
  }

  private func settle(_ condition: @escaping () -> Bool) async throws {
    for _ in 0..<1000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Listening task did not settle")
  }

  private func preparedModel() async throws -> (MacPrivateListeningModel, ListeningCaptureFake, ListeningModelClock, ListeningModelChannel) {
    let capture = ListeningCaptureFake(), clock = ListeningModelClock()
    let model = MacPrivateListeningModel(capture: capture, preferences: nil, now: { clock.time }, automaticallyPump: false)
    let channel = ListeningModelChannel(try peer(), clock: clock)
    model.available(channel)
    _ = await model.handle(try PrivateListeningMessage.capability(enabled: true).encode(), on: channel.descriptor)
    model.prepareCapture()
    try await settle { model.capturePrepared && !model.busy }
    return (model, capture, clock, channel)
  }

  func testPreparationDoesNotMuteAndRefusalStopsWithoutActivation() async throws {
    let (model, capture, _, channel) = try await preparedModel()
    let before = await capture.activated
    XCTAssertEqual(before, 0)
    model.start()
    try await settle { channel.sent.contains { $0.kind == 1 } }
    let id = try XCTUnwrap(channel.sent.first { $0.kind == 1 }).text(0)
    _ = await model.handle(try PrivateListeningMessage(kind: 2, fields: [.text(id), .integer(6)]).encode(),
      on: channel.descriptor)
    try await settle { !model.busy }
    let activations = await capture.activated
    XCTAssertEqual(activations, 0)
    XCTAssertFalse(model.active)
  }

  func testReadyAndTerminalCleanupAreStreamAndGenerationBound() async throws {
    let (model, capture, _, channel) = try await preparedModel()
    model.start()
    try await settle { channel.sent.contains { $0.kind == 1 } }
    let start = try XCTUnwrap(channel.sent.first { $0.kind == 1 })
    let stale = PrivateListeningMessage(kind: 2, fields: [
      .text("01234567-89ab-4cde-8fab-0123456789ab"), .integer(0)])
    let staleResult = await model.handle(try stale.encode(), on: channel.descriptor)
    XCTAssertEqual(staleResult, .discarded)
    let ready = PrivateListeningMessage(kind: 2, fields: [.text(start.text(0)), .integer(0)])
    _ = await model.handle(try ready.encode(), on: channel.descriptor)
    try await settle { model.state == 2 }
    XCTAssertEqual(model.state, 2)
    let activated = await capture.activated
    XCTAssertEqual(activated, 1)
    model.stop()
    XCTAssertEqual(model.status, "Restoring Mac audio…")
    try await settle { !model.busy }
    let lateResult = await model.handle(try ready.encode(), on: channel.descriptor)
    XCTAssertEqual(lateResult, .discarded)
    let stopped = await capture.stopped
    XCTAssertGreaterThanOrEqual(stopped, 1)
    XCTAssertFalse(model.active)
  }

  func testMaintenanceExcludesOnlyTheNativeIntervalAndPreservesStream() async throws {
    let (model, capture, clock, channel) = try await preparedModel()
    model.start()
    try await settle { channel.sent.contains { $0.kind == 1 } }
    let start = try XCTUnwrap(channel.sent.first { $0.kind == 1 })
    _ = await model.handle(try PrivateListeningMessage(kind: 2,
      fields: [.text(start.text(0)), .integer(0)]).encode(), on: channel.descriptor)
    try await settle { model.state == 2 }
    // Confirm one source packet before the maintenance interval; the wire-start timeout stays distinct.
    await model.tick()
    try await settle { channel.sent.contains { $0.kind == 3 } }
    clock.time = 1000
    channel.maintenance?.update(SessionMaintenanceSnapshot(sinceMillis: 1000, revision: 1))
    model.capacityAvailable(channel.descriptor)
    XCTAssertEqual(model.state, 4)
    clock.time = 45000
    await model.tick()
    XCTAssertTrue(model.active)
    let forwards = await capture.forwards
    XCTAssertEqual(forwards.last, false)
    channel.maintenance?.update(SessionMaintenanceSnapshot(elapsedMillis: 44000, revision: 2))
    model.capacityAvailable(channel.descriptor)
    await model.tick()
    XCTAssertTrue(model.active)
    XCTAssertEqual(channel.sent.filter { $0.kind == 1 }.count, 1)
    clock.time = 55000
    await model.tick()
    try await settle { !model.busy }
    XCTAssertFalse(model.active)
  }

  func testLateReadyAfterStartDeadlineCannotMuteCapture() async throws {
    let (model, capture, clock, channel) = try await preparedModel()
    model.start()
    try await settle { channel.sent.contains { $0.kind == 1 } }
    let id = try XCTUnwrap(channel.sent.first { $0.kind == 1 }).text(0)
    clock.time = 5000
    _ = await model.handle(try PrivateListeningMessage(kind: 2,
      fields: [.text(id), .integer(0)]).encode(), on: channel.descriptor)
    try await settle { !model.busy }
    let activated = await capture.activated
    XCTAssertEqual(activated, 0)
    XCTAssertFalse(model.active)
  }

  func testTransferPreparationHasItsOwnDeadlineBeforeStart() async throws {
    let (model, capture, clock, channel) = try await preparedModel()
    var paced = [Bool]()
    model.pacingChanged = { paced.append($0) }
    model.transferReady = { false }
    model.start()
    try await Task.sleep(for: .milliseconds(5))
    XCTAssertTrue(channel.sent.isEmpty)
    XCTAssertEqual(paced, [true])
    clock.time = 10000
    try await settle { !model.busy }
    XCTAssertFalse(channel.sent.contains { $0.kind == 1 })
    XCTAssertEqual(paced.last, false)
    let activated = await capture.activated
    XCTAssertEqual(activated, 0)
  }

  func testCoalescedMaintenanceClearsCaptureWithoutAnotherStart() async throws {
    let (model, capture, clock, channel) = try await preparedModel()
    model.start()
    try await settle { channel.sent.contains { $0.kind == 1 } }
    let id = try XCTUnwrap(channel.sent.first { $0.kind == 1 }).text(0)
    _ = await model.handle(try PrivateListeningMessage(kind: 2,
      fields: [.text(id), .integer(0)]).encode(), on: channel.descriptor)
    try await settle { model.state == 2 }
    await model.tick()
    try await settle { channel.sent.contains { $0.kind == 3 } }
    clock.time = 3000
    channel.maintenance?.update(SessionMaintenanceSnapshot(elapsedMillis: 2000, revision: 2))
    model.capacityAvailable(channel.descriptor)
    await model.tick()
    let forwards = await capture.forwards
    XCTAssertEqual(forwards.suffix(2), [false, true])
    XCTAssertTrue(model.active)
    XCTAssertEqual(channel.sent.filter { $0.kind == 1 }.count, 1)
    model.stop()
    try await settle { !model.busy }
  }

  func testCaptureFailureCannotKeepPhoneOwnershipOrMacActive() async throws {
    let (model, capture, _, channel) = try await preparedModel()
    model.start()
    try await settle { channel.sent.contains { $0.kind == 1 } }
    let id = try XCTUnwrap(channel.sent.first { $0.kind == 1 }).text(0)
    await capture.setFailure(true)
    _ = await model.handle(try PrivateListeningMessage(kind: 2,
      fields: [.text(id), .integer(0)]).encode(), on: channel.descriptor)
    try await settle { !model.busy }
    XCTAssertFalse(model.active)
    XCTAssertTrue(channel.sent.contains { $0.kind == 4 && $0.text(0) == id })
  }

  func testStopWhileActivationSuspendsCannotReviveCaptureOrAllowANewStart() async throws {
    let (model, capture, _, channel) = try await preparedModel()
    model.start()
    try await settle { channel.sent.contains { $0.kind == 1 } }
    let id = try XCTUnwrap(channel.sent.first { $0.kind == 1 }).text(0)
    await capture.hold()
    _ = await model.handle(try PrivateListeningMessage(kind: 2,
      fields: [.text(id), .integer(0)]).encode(), on: channel.descriptor)
    try await Task.sleep(for: .milliseconds(5))
    model.stop()
    XCTAssertFalse(model.active)
    XCTAssertFalse(model.canPrepare)
    await capture.release()
    try await settle { !model.busy }
    XCTAssertFalse(model.active)
    XCTAssertFalse(model.capturePrepared)
    let stops = await capture.stopped
    XCTAssertGreaterThanOrEqual(stops, 1)
  }
}
