// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies transfer engine lifecycle, cumulative flow control and adversarial chunk handling.
import XCTest
import CryptoKit
import os
@testable import aniCe

@MainActor
final class MockSecuredChannel: SecuredChannel {
  let descriptor: ChannelDescriptor
  var sentData: [Data] = []
  var onSendData: ((Data) async throws -> Void)?

  init(instance: String = "test-token", transport: String = "lan", deviceName: String = "Pixel 9", maximumDataBytes: Int = 4000, peer: DeviceIdentity? = nil) {
    let key = P256.Signing.PrivateKey()
    let peer = peer ?? (try! DeviceIdentity(deviceId: UUID().uuidString.lowercased(), deviceName: deviceName, publicKey: key.publicKey.x963Representation))
    self.descriptor = ChannelDescriptor(instance: instance, transport: transport, peer: peer, maximumDataBytes: maximumDataBytes)
  }

  func sendData(_ bytes: Data) async throws {
    sentData.append(bytes)
    if let onSendData {
      try await onSendData(bytes)
    }
  }
}

@MainActor
final class TransferModelTests: XCTestCase {
  private var tempDir: URL!

  func testConstrainedLanRequalifiesOnlyWithADrainedWindowAndANewCompleteProbe() {
    var window = TransferSendWindow(maximumChunk: 262016, maximumWindow: 8, lan: true, started: 0)
    window.acknowledged(0.101, fullyConfirmed: true); window.advance()
    window.acknowledged(4.999, fullyConfirmed: true); window.advance()
    XCTAssertEqual(window.creditBytes, 8192)
    window.acknowledged(5, fullyConfirmed: false); window.advance()
    XCTAssertEqual(window.creditBytes, 8192, "Outstanding bytes prevent another probe")
    window.acknowledged(5, fullyConfirmed: true)
    XCTAssertEqual(window.creditBytes, 8192, "The current source read retains its budget")
    window.advance()
    XCTAssertEqual(window.creditBytes, 4096)
    window.acknowledged(5.09, fullyConfirmed: false); window.advance()
    window.acknowledged(5.15, fullyConfirmed: true); window.advance()
    XCTAssertEqual(window.creditBytes, 8192, "Partial confirmation cannot disguise a slow probe")
    window.acknowledged(10, fullyConfirmed: true); window.advance()
    XCTAssertEqual(window.creditBytes, 4096)
    window.acknowledged(10.05, fullyConfirmed: true); window.advance()
    XCTAssertEqual(window.chunkBytes, 262016); XCTAssertEqual(window.creditBytes, 2096128)
  }

  func testLanSendWindowRequiresTimelyProgressAndAppliesChangesBetweenRecords() {
    for delay in [0.1, 0.101] {
      var window = TransferSendWindow(maximumChunk: 262016, maximumWindow: 8, lan: true, started: 0)
      XCTAssertEqual(window.chunkBytes, 4096); XCTAssertEqual(window.creditBytes, 4096)
      window.acknowledged(delay, fullyConfirmed: true)
      XCTAssertEqual(window.creditBytes, 4096, "An admitted read keeps its window")
      window.advance()
      XCTAssertEqual(window.chunkBytes, delay == 0.1 ? 262016 : 4096)
      XCTAssertEqual(window.creditBytes, delay == 0.1 ? 2096128 : 8192)
      window.acknowledged(delay + 1.001, fullyConfirmed: true); window.advance()
      XCTAssertEqual(window.chunkBytes, 4096); XCTAssertEqual(window.creditBytes, 8192)
      window.acknowledged(delay + 1.002, fullyConfirmed: true); window.advance()
      XCTAssertEqual(window.creditBytes, 8192, "Fast subsequent ACKs cannot oscillate the window")
    }
    var single = TransferSendWindow(maximumChunk: 5000, maximumWindow: 1, lan: true, started: 0)
    single.acknowledged(0.101, fullyConfirmed: true); single.advance()
    XCTAssertEqual(single.creditBytes, 4096)
    var ble = TransferSendWindow(maximumChunk: 3072, maximumWindow: 4, lan: false, started: 0)
    ble.acknowledged(5, fullyConfirmed: true); ble.advance()
    XCTAssertEqual(ble.chunkBytes, 3072); XCTAssertEqual(ble.creditBytes, 12288)
    var partial = TransferSendWindow(maximumChunk: 262016, maximumWindow: 8, lan: true, started: 0)
    partial.acknowledged(0.09, fullyConfirmed: false); partial.advance()
    XCTAssertEqual(partial.creditBytes, 4096)
    partial.acknowledged(0.15, fullyConfirmed: true); partial.advance()
    XCTAssertEqual(partial.creditBytes, 8192, "Partial ACK must not reset the probe's start time")
  }

  func testIngressBoundsIncludeActiveWriteAndCancellationRemovesWaiter() async throws {
    for (byteLimit, recordLimit) in [(4, 8), (100, 2)] {
      let descriptor = MockSecuredChannel().descriptor, epoch = UUID()
      var release: CheckedContinuation<Void, Never>?
      var consumed: [UInt8] = []
      let queue = TransferIngress { _, _, bytes in
        if bytes.first == 1 { await withCheckedContinuation { release = $0 } }
        consumed.append(bytes.first!)
      }
      func send(_ value: UInt8) async -> Bool {
        await queue.enqueue(Data([value, 0]), on: descriptor, epoch: epoch,
          byteLimit: byteLimit, recordLimit: recordLimit) { true }
      }
      let first = await send(1); XCTAssertTrue(first)
      for _ in 0..<1000 { if release != nil { break }; await Task.yield() }
      XCTAssertNotNil(release)
      let second = await send(2); XCTAssertTrue(second)
      var admitted = false
      let blocked = Task { admitted = await send(3) }
      let cancelled = Task { await send(4) }
      for _ in 0..<20 { await Task.yield() }
      XCTAssertFalse(admitted)
      cancelled.cancel()
      let cancelledAccepted = await cancelled.value; XCTAssertFalse(cancelledAccepted)
      release?.resume()
      await blocked.value
      XCTAssertTrue(admitted)
      let drained = await queue.drain(); XCTAssertTrue(drained)
      XCTAssertEqual(consumed, [1, 2, 3])
    }
  }

  func testIngressInvalidationRetainsActiveCapacityAndDrainIsBounded() async throws {
    let descriptor = MockSecuredChannel().descriptor, epoch = UUID()
    var release: CheckedContinuation<Void, Never>?
    var live = true, consumed: [UInt8] = []
    let queue = TransferIngress { _, _, bytes in
      if bytes.first == 1 { await withCheckedContinuation { release = $0 } }
      consumed.append(bytes.first!)
    }
    func send(_ value: UInt8) async -> Bool {
      await queue.enqueue(Data([value]), on: descriptor, epoch: epoch, byteLimit: 2, recordLimit: 2) { live }
    }
    let first = await send(1); XCTAssertTrue(first)
    for _ in 0..<1000 { if release != nil { break }; await Task.yield() }
    XCTAssertNotNil(release)
    let second = await send(2); XCTAssertTrue(second)
    let blocked = Task { await send(3) }
    for _ in 0..<20 { await Task.yield() }
    live = false; queue.invalidate(descriptor)
    let staleAccepted = await blocked.value; XCTAssertFalse(staleAccepted)
    let timedOut = await queue.drain(timeout: .milliseconds(5)); XCTAssertFalse(timedOut)
    release?.resume()
    let drained = await queue.drain(); XCTAssertTrue(drained)
    XCTAssertEqual(consumed, [1])
    live = true
    let fresh = await send(4); XCTAssertTrue(fresh)
    let freshDrained = await queue.drain(); XCTAssertTrue(freshDrained)
    XCTAssertEqual(consumed, [1, 4])
  }

  func testSuccessorEpochUsesAFreshConsumerAfterAnUninterruptibleWrite() async throws {
    let old = MockSecuredChannel(instance: "old").descriptor
    let fresh = MockSecuredChannel(instance: "fresh").descriptor
    var release: CheckedContinuation<Void, Never>?
    var consumed: [UInt8] = []
    let queue = TransferIngress { descriptor, _, bytes in
      if descriptor == old { await withCheckedContinuation { release = $0 } }
      else { XCTAssertFalse(Task.isCancelled, "Successor must not inherit cancellation") }
      consumed.append(bytes.first!)
    }
    let first = await queue.enqueue(Data([1]), on: old, epoch: UUID(), byteLimit: 2, recordLimit: 2) { true }
    XCTAssertTrue(first)
    for _ in 0..<1000 { if release != nil { break }; await Task.yield() }
    XCTAssertNotNil(release); queue.invalidate(old)
    let second = await queue.enqueue(Data([2]), on: fresh, epoch: UUID(), byteLimit: 2, recordLimit: 2) { true }
    XCTAssertTrue(second); release?.resume()
    let drained = await queue.drain(); XCTAssertTrue(drained)
    XCTAssertEqual(consumed, [1, 2])
  }

  func testDrainingAnotherChannelDoesNotWaitForOrCancelActiveStorage() async throws {
    let active = MockSecuredChannel(instance: "active").descriptor
    let other = MockSecuredChannel(instance: "other").descriptor
    var release: CheckedContinuation<Void, Never>?
    var completed = false
    let queue = TransferIngress { _, _, _ in
      await withCheckedContinuation { release = $0 }; completed = true
    }
    let accepted = await queue.enqueue(Data([1]), on: active, epoch: UUID(), byteLimit: 1, recordLimit: 1) { true }
    XCTAssertTrue(accepted)
    for _ in 0..<1000 { if release != nil { break }; await Task.yield() }
    XCTAssertNotNil(release)
    queue.invalidate(other)
    let otherDrained = await queue.drain(other, timeout: .milliseconds(5))
    XCTAssertTrue(otherDrained); XCTAssertFalse(completed)
    release?.resume()
    let activeDrained = await queue.drain(active); XCTAssertTrue(activeDrained); XCTAssertTrue(completed)
  }

  func testIngressUsesLocalReceiveCreditWithAsymmetricPeerCapability() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel(maximumDataBytes: 262144)
    let dispatch = FeatureDispatch()
    dispatch.register(owner); dispatch.available(channel.descriptor) { try await channel.sendData($0) }
    defer { owner.dismiss() }
    _ = await owner.handle(try TransferMessage.capability(version: 3, maxChunkBytes: 1, maxWindow: 1).encode(maximumChunkBytes: 262016), on: channel.descriptor)
    let bytes = Data(repeating: 0, count: 131072), batch = UUID().uuidString.lowercased(), file = UUID().uuidString.lowercased()
    _ = await owner.handle(try TransferMessage.offer(batch: batch, sliceIndex: 0, totalSlices: 1, totalFiles: 1, totalBytes: Int64(bytes.count),
      files: [.array([.text(file), .text("asymmetric.bin"), .integer(Int64(bytes.count)), .bytes(Data(SHA256.hash(data: bytes)))])]).encode(), on: channel.descriptor)
    await owner.acceptIncomingOffer(destination: tempDir)
    let result = await dispatch.handle(try TransferMessage.chunk(batch: batch, file: file, offset: 0, data: bytes).encode(maximumChunkBytes: 262016), transport: "lan", instance: channel.descriptor.instance)
    XCTAssertEqual(result, .queued)
    await dispatch.drain("lan", instance: channel.descriptor.instance)
    XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("asymmetric.bin")), bytes)
  }

  func testProductionIngressDrainsChunksBeforeCloseAndPreservesFileBytes() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel()
    let dispatch = FeatureDispatch()
    dispatch.register(owner)
    dispatch.available(channel.descriptor) { try await channel.sendData($0) }
    defer { owner.dismiss() }
    _ = await dispatch.handle(try TransferMessage.capability().encode(), transport: "lan", instance: channel.descriptor.instance)
    let data = Data([1, 2, 3]), batch = UUID().uuidString.lowercased(), file = UUID().uuidString.lowercased()
    let offer = try TransferMessage.offer(batch: batch, sliceIndex: 0, totalSlices: 1, totalFiles: 1, totalBytes: 3,
      files: [.array([.text(file), .text("queued.bin"), .integer(3), .bytes(Data(SHA256.hash(data: data)))])]).encode()
    _ = await dispatch.handle(offer, transport: "lan", instance: channel.descriptor.instance)
    await owner.acceptIncomingOffer(destination: tempDir)
    for (offset, byte) in data.enumerated() {
      let result = await dispatch.handle(try TransferMessage.chunk(batch: batch, file: file, offset: Int64(offset), data: Data([byte])).encode(), transport: "lan", instance: channel.descriptor.instance)
      XCTAssertEqual(result, .queued)
    }
    await dispatch.drain("lan", instance: channel.descriptor.instance)
    XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("queued.bin")), data)
  }


  func testCancelledDecodeCannotPresentAnOfferAndFreshDeliveryStillWorks() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel()
    owner.available(channel)
    defer { owner.dismiss() }
    _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    let payload = try TransferMessage.offer(batch: UUID().uuidString.lowercased(), sliceIndex: 0,
      totalSlices: 1, totalFiles: 1, totalBytes: 0,
      files: [.array([.text(UUID().uuidString.lowercased()), .text("empty.txt"), .integer(0),
        .bytes(Data(SHA256.hash(data: Data())))])]).encode()
    let cancelled = Task { await owner.handle(payload, on: channel.descriptor) }
    cancelled.cancel()
    let result = await cancelled.value
    if case .discarded = result {} else { XCTFail("Cancelled decode reached feature handling") }
    XCTAssertNil(owner.pendingOffer)
    _ = await owner.handle(payload, on: channel.descriptor)
    XCTAssertNotNil(owner.pendingOffer)
    owner.retired(channel.descriptor)
    _ = await owner.handle(payload, on: channel.descriptor)
    XCTAssertNil(owner.pendingOffer, "Retired delivery must not recreate an offer")
  }

  func testLateConfirmationStaysPendingAndCapacityCallbacksDoNotSpin() async throws {
    let owner = MacTransferModel(pauseTimeout: .seconds(5), resumeTimeout: .milliseconds(25), confirmationTimeout: .milliseconds(25))
    let channel = MockSecuredChannel()
    owner.available(channel)
    defer { owner.dismiss() }
    _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    let source = tempDir.appendingPathComponent("late.bin")
    try Data(repeating: 0, count: 4).write(to: source)
    await owner.sendFiles(urls: [source])
    guard case .waitingForPeerApproval(let batch) = owner.state else { return XCTFail("Missing offer") }
    channel.onSendData = { bytes in
      if try TransferMessage.decode(bytes)?.kind == 10 {
        _ = await owner.handle(try TransferMessage.status(batch: batch.idString, file: batch.files[0].idString,
          bytesTransferred: 0, state: 3).encode(), on: channel.descriptor)
      }
    }
    _ = await owner.handle(try TransferMessage.accept(batch: batch.idString, files: []).encode(), on: channel.descriptor)
    func resumes() -> Int { channel.sentData.compactMap { try? TransferMessage.decode($0) }.filter { $0.kind == 10 }.count }
    for _ in 0..<200 {
      if case .paused = owner.state, resumes() > 0 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .paused = owner.state else { return XCTFail("Late confirmation discarded the batch") }
    try await Task.sleep(for: .milliseconds(30))
    for _ in 0..<100 { owner.capacityAvailable(channel.descriptor) }
    XCTAssertEqual(resumes(), 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }

  func testBleCreditLeavesRoomForControlsInTheEightMessageIngressQueue() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel(transport: "ble")
    owner.available(channel)
    defer { owner.dismiss() }
    for _ in 0..<200 {
      if !channel.sentData.isEmpty { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let advertised = try XCTUnwrap(channel.sentData.first)
    XCTAssertEqual(try TransferMessage.decode(advertised)?.number(2), 4)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    let source = tempDir.appendingPathComponent("window.bin")
    try Data(repeating: 0, count: 20000).write(to: source)
    await owner.sendFiles(urls: [source])
    guard case .waitingForPeerApproval(let batch) = owner.state else { return XCTFail("Missing offer") }
    _ = await owner.handle(try TransferMessage.accept(batch: batch.idString, files: []).encode(), on: channel.descriptor)
    func chunks() -> [TransferMessage] { channel.sentData.compactMap { try? TransferMessage.decode($0) }.filter { $0.kind == 5 } }
    for _ in 0..<200 {
      if chunks().count >= 4 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(chunks().count, 4)
    _ = await owner.handle(try TransferMessage.ack(batch: batch.idString, file: batch.files[0].idString, written: 12288).encode(), on: channel.descriptor)
    for _ in 0..<200 {
      if chunks().count >= 7 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(chunks().count, 7)
    _ = await owner.handle(try TransferMessage.fileResult(batch: batch.idString, file: batch.files[0].idString,
      result: 0, hash: batch.files[0].sha256).encode(), on: channel.descriptor)
    for _ in 0..<200 {
      if case .completed = owner.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .completed = owner.state else { return XCTFail("Credited BLE transfer did not complete") }
  }

  private func checkpointFixture(receiving: Bool = true, stage: Int = 0) async throws -> (TransferCheckpoint, IdentityService, MockSecuredChannel, URL) {
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Recovery Mac", tagPrefix: "checkpoint.test.")
    let local = try await identity.publicIdentity(), channel = MockSecuredChannel()
    let source = tempDir.appendingPathComponent("source.bin")
    try Data(repeating: 0, count: 4).write(to: source)
    let file = TransferFile(id: UUID(), name: "received.bin", size: 4,
      sha256: Data(SHA256.hash(data: Data(repeating: 0, count: 4))), localURL: receiving ? nil : source)
    let batch = TransferBatch(id: UUID(), files: [file], totalBytes: 4, peerName: "Phone")
    let part = tempDir.appendingPathComponent(".anice-\(batch.idString)-\(file.idString)-\(UUID().uuidString).part")
    try Data([0]).write(to: part)
    let saved = TransferCheckpoint(localFingerprint: local.fingerprint, peerId: channel.descriptor.peer.deviceId,
      peerFingerprint: channel.descriptor.peer.fingerprint, batch: batch, receiving: receiving, index: 0,
      offset: receiving ? 1 : 0, folder: receiving ? tempDir : nil, partial: receiving ? part : nil,
      transport: "lan", expiresAt: Date().addingTimeInterval(60), stage: stage)
    return (saved, identity, channel, tempDir.appendingPathComponent("private/checkpoint-\(UUID().uuidString).json"))
  }

  func testCrashAfterPublicationReplaysAReceiptWithoutPublishingAnotherFile() async throws {
    var (saved, identity, channel, journal) = try await checkpointFixture()
    let part = try XCTUnwrap(saved.partial)
    try Data(repeating: 0, count: 4).write(to: part)
    let attributes = try FileManager.default.attributesOfItem(atPath: part.path)
    let device = try XCTUnwrap(attributes[.systemNumber] as? NSNumber)
    let inode = try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber)
    saved.stage = 4; saved.offset = 4; saved.fileIdentity = "\(device):\(inode)"
    let target = tempDir.appendingPathComponent("received.bin")
    try FileManager.default.linkItem(at: part, to: target)
    try FileManager.default.removeItem(at: part)
    try await TransferRecoveryStore(journal).save(saved)
    let owner = MacTransferModel(recoveryURL: journal, identity: identity)
    defer { owner.dismiss() }
    for _ in 0..<400 {
      if case .completed = owner.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .completed = owner.state else { return XCTFail("Publication was not reconciled: \(owner.state)") }
    let receipt = try await TransferRecoveryStore(journal).load()
    XCTAssertEqual(receipt?.stage, 3)
    owner.available(channel)
    _ = await owner.handle(try TransferMessage.resume(batch: saved.batch.idString, file: saved.batch.files[0].idString,
      offset: 4, prefixHash: saved.batch.files[0].sha256).encode(), on: channel.descriptor)
    XCTAssertTrue(channel.sentData.compactMap { try? TransferMessage.decode($0) }.contains { $0.kind == 7 && $0.number(2) == 0 })
    XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("received (1).bin").path))
    XCTAssertEqual(try Data(contentsOf: target), Data(repeating: 0, count: 4))
  }

  func testUnansweredAndBusyResumeStayPendingAndANewChannelCanFinish() async throws {
    let (saved, identity, first, journal) = try await checkpointFixture(receiving: false)
    try await TransferRecoveryStore(journal).save(saved)
    let owner = MacTransferModel(recoveryURL: journal, identity: identity, resumeTimeout: .milliseconds(25))
    defer { owner.dismiss() }
    for _ in 0..<200 {
      if case .paused = owner.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .paused = owner.state else { return XCTFail("Sender checkpoint missing") }
    for attempt in 0..<3 {
      let channel = MockSecuredChannel(instance: "attempt-\(attempt)", peer: first.descriptor.peer)
      channel.onSendData = { bytes in
        let message = try XCTUnwrap(TransferMessage.decode(bytes))
        if message.kind == 10, attempt > 0 {
          _ = await owner.handle(try TransferMessage.status(batch: saved.batch.idString, file: saved.batch.files[0].idString,
            bytesTransferred: 0, state: attempt == 1 ? 3 : 0).encode(), on: channel.descriptor)
        }
        if message.kind == 5, attempt == 2 {
          _ = await owner.handle(try TransferMessage.fileResult(batch: saved.batch.idString, file: saved.batch.files[0].idString,
            result: 0, hash: saved.batch.files[0].sha256).encode(), on: channel.descriptor)
        }
      }
      owner.available(channel)
      _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
      for _ in 0..<200 {
        if channel.sentData.compactMap({ try? TransferMessage.decode($0) }).contains(where: { $0.kind == 10 }) { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      if attempt < 2 {
        try await Task.sleep(for: .milliseconds(75))
        guard case .paused = owner.state else { return XCTFail("Transient resume failure discarded the batch") }
        owner.retired(channel.descriptor)
      }
    }
    for _ in 0..<200 {
      if case .completed = owner.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .completed = owner.state else { return XCTFail("A fresh channel could not resume the retained batch") }
  }

  func testRestoredIncomingOfferStillRequiresApproval() async throws {
    let (saved, identity, channel, journal) = try await checkpointFixture(stage: 2)
    try await TransferRecoveryStore(journal).save(saved)
    let owner = MacTransferModel(recoveryURL: journal, identity: identity)
    defer { owner.dismiss() }
    for _ in 0..<200 {
      if case .paused = owner.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    owner.available(channel)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    guard case .incomingOffer(let batch) = owner.state else { return XCTFail("Unapproved offer was lost") }
    XCTAssertEqual(batch.id, saved.batch.id)
    XCTAssertFalse(channel.sentData.compactMap { try? TransferMessage.decode($0) }.contains { $0.kind == 3 })
  }

  func testCapabilityArrivingDuringRestoreIsRetained() async throws {
    let (saved, identity, channel, journal) = try await checkpointFixture(stage: 2)
    try await TransferRecoveryStore(journal).save(saved)
    let owner = MacTransferModel(recoveryURL: journal, identity: identity)
    defer { owner.dismiss() }
    owner.available(channel)
    let result = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    XCTAssertEqual(result, .handled)
    XCTAssertTrue(owner.peerCompatible)
    XCTAssertEqual(owner.pendingOffer?.id, saved.batch.id)
  }

  func testCheckpointWriteFailurePreservesThePreviousJournalAndPartial() async throws {
    let (saved, _, _, journal) = try await checkpointFixture()
    let store = TransferRecoveryStore(journal)
    try await store.save(saved)
    let parent = journal.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
    do {
      var next = saved; next.offset = 2
      do { try await store.save(next); XCTFail("Ignored checkpoint write denial") }
      catch let error as CocoaError { XCTAssertEqual(error.code, .fileWriteUnknown) }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    let retained = try await store.load()
    XCTAssertEqual(retained?.offset, saved.offset)
    XCTAssertEqual(retained?.batch, saved.batch)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(saved.partial)), Data([0]))
  }

  func testBothRestartedOwnersRecoverLostApprovalAndAllPublishedReceipts() async throws {
    let (base, identity, peer, senderJournal) = try await checkpointFixture(receiving: false)
    let files = try [0, 4, 0].enumerated().map { index, length -> TransferFile in
      let source = tempDir.appendingPathComponent("source-\(index).bin")
      try Data(repeating: 0, count: length).write(to: source)
      return TransferFile(id: UUID(), name: source.lastPathComponent, size: Int64(length),
        sha256: Data(SHA256.hash(data: Data(repeating: 0, count: length))), localURL: source)
    }
    let batch = TransferBatch(id: base.batch.id, files: files, totalBytes: 4, peerName: "Phone")
    let received = TransferBatch(id: batch.id, files: files.map {
      TransferFile(id: $0.id, name: $0.name, size: $0.size, sha256: $0.sha256, localURL: nil)
    }, totalBytes: 4, peerName: "Mac")
    let receiverJournal = tempDir.appendingPathComponent("receiver/checkpoint.json")
    try await TransferRecoveryStore(senderJournal).save(TransferCheckpoint(localFingerprint: base.localFingerprint,
      peerId: base.peerId, peerFingerprint: base.peerFingerprint, batch: batch, receiving: false, index: 0,
      offset: 0, folder: nil, partial: nil, transport: "lan", expiresAt: Date().addingTimeInterval(60), stage: 1))
    try await TransferRecoveryStore(receiverJournal).save(TransferCheckpoint(localFingerprint: base.localFingerprint,
      peerId: base.peerId, peerFingerprint: base.peerFingerprint, batch: received, receiving: true, index: 2,
      offset: 0, folder: nil, partial: nil, transport: "lan", expiresAt: Date().addingTimeInterval(60), stage: 3))
    let sender = MacTransferModel(recoveryURL: senderJournal, identity: identity)
    let receiver = MacTransferModel(recoveryURL: receiverJournal, identity: identity)
    let outgoing = MockSecuredChannel(instance: "sender-new", peer: peer.descriptor.peer)
    let incoming = MockSecuredChannel(instance: "receiver-new", peer: peer.descriptor.peer)
    defer { sender.dismiss(); receiver.dismiss(); outgoing.onSendData = nil; incoming.onSendData = nil }
    for _ in 0..<200 {
      if case .paused = sender.state, case .completed = receiver.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    outgoing.onSendData = { _ = await receiver.handle($0, on: incoming.descriptor) }
    incoming.onSendData = { _ = await sender.handle($0, on: outgoing.descriptor) }
    sender.available(outgoing); receiver.available(incoming)
    _ = await sender.handle(try TransferMessage.capability().encode(), on: outgoing.descriptor)
    _ = await receiver.handle(try TransferMessage.capability().encode(), on: incoming.descriptor)
    for _ in 0..<800 {
      if case .completed = sender.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .completed(_, let count, _) = sender.state else { return XCTFail("Sender could not recover published receipts: \(sender.state)") }
    XCTAssertEqual(count, 3)
    XCTAssertFalse(outgoing.sentData.compactMap { try? TransferMessage.decode($0) }.contains { $0.kind == 5 })
    guard case .completed = receiver.state else { return XCTFail("Reoffering changed the completed receiver") }
  }

  func testRestartedReceiverUsesOnlyItsVerifiedCheckpointAndRejectsAnotherPeer() async throws {
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Recovery Mac", tagPrefix: "recovery.test.")
    let local = try await identity.publicIdentity()
    let channel = MockSecuredChannel(instance: "fresh")
    let file = TransferFile(id: UUID(), name: "recovered.bin", size: 4,
      sha256: Data(SHA256.hash(data: Data(repeating: 0, count: 4))), localURL: nil)
    let batch = TransferBatch(id: UUID(), files: [file], totalBytes: 4, peerName: "Phone")
    let part = tempDir.appendingPathComponent(".anice-\(batch.idString)-\(file.idString)-\(UUID().uuidString).part")
    try Data(repeating: 0, count: 3).write(to: part)
    let journal = tempDir.appendingPathComponent("private/checkpoint.json")
    let saved = TransferCheckpoint(localFingerprint: local.fingerprint, peerId: channel.descriptor.peer.deviceId,
      peerFingerprint: channel.descriptor.peer.fingerprint, batch: batch, receiving: true, index: 0,
      offset: 1, folder: tempDir, partial: part, transport: "lan", expiresAt: Date().addingTimeInterval(60))
    try await TransferRecoveryStore(journal).save(saved)
    let owner = MacTransferModel(recoveryURL: journal, identity: identity)
    defer { owner.dismiss() }
    for _ in 0..<200 {
      if case .paused = owner.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .paused = owner.state else { return XCTFail("Checkpoint was not restored: \(owner.state)") }
    XCTAssertEqual(try Data(contentsOf: part).count, 1)
    owner.available(MockSecuredChannel())
    XCTAssertNil(owner.activeChannel)
    owner.available(channel)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    _ = await owner.handle(try TransferMessage.resume(batch: batch.idString, file: file.idString,
      offset: 1, prefixHash: Data(SHA256.hash(data: Data([0])))).encode(), on: channel.descriptor)
    _ = await owner.handle(try TransferMessage.chunk(batch: batch.idString, file: file.idString,
      offset: 1, data: Data(repeating: 0, count: 3)).encode(), on: channel.descriptor)
    for _ in 0..<200 {
      if case .completed = owner.state, try await TransferRecoveryStore(journal).load()?.stage == 3 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .completed = owner.state else { return XCTFail("Recovered batch did not complete: \(owner.state)") }
    XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("recovered.bin")), Data(repeating: 0, count: 4))
    let receipt = try await TransferRecoveryStore(journal).load()
    XCTAssertEqual(receipt?.stage, 3)
  }

  func testExpiredCheckpointRemovesOnlyItsOwnedPartial() async throws {
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Recovery Mac", tagPrefix: "expiry.test.")
    let local = try await identity.publicIdentity(), channel = MockSecuredChannel()
    let file = TransferFile(id: UUID(), name: "recovered.bin", size: 4,
      sha256: Data(SHA256.hash(data: Data(repeating: 0, count: 4))), localURL: nil)
    let batch = TransferBatch(id: UUID(), files: [file], totalBytes: 4, peerName: "Phone")
    let part = tempDir.appendingPathComponent(".anice-\(batch.idString)-\(file.idString)-\(UUID().uuidString).part")
    let unrelated = tempDir.appendingPathComponent(".anice-unrelated.part")
    try Data([0]).write(to: part); try Data([42]).write(to: unrelated)
    let journal = tempDir.appendingPathComponent("private/checkpoint.json")
    try await TransferRecoveryStore(journal).save(TransferCheckpoint(localFingerprint: local.fingerprint,
      peerId: channel.descriptor.peer.deviceId, peerFingerprint: channel.descriptor.peer.fingerprint,
      batch: batch, receiving: true, index: 0, offset: 1, folder: tempDir, partial: part,
      transport: "lan", expiresAt: Date().addingTimeInterval(-1)))
    let owner = MacTransferModel(recoveryURL: journal, identity: identity)
    defer { owner.dismiss() }
    for _ in 0..<200 {
      if case .failed = owner.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .failed = owner.state else { return XCTFail("Expired checkpoint was retained") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    XCTAssertEqual(try Data(contentsOf: unrelated), Data([42]))
  }

  override func setUp() async throws {
    try await super.setUp()
    tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
      try? FileManager.default.removeItem(at: tempDir)
    }
    try await super.tearDown()
  }

  func testLanAdvertisesLegacyCapabilityBeforeLargeChunkExtension() async throws {
    let owner = MacTransferModel()
    let channel = MockSecuredChannel(maximumDataBytes: 262144)
    owner.available(channel)
    defer { owner.dismiss() }
    for _ in 0..<100 {
      if channel.sentData.count >= 2 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(channel.sentData.count, 2)
    let baseline = try XCTUnwrap(channel.sentData.first)
    let extensionBytes = try XCTUnwrap(channel.sentData.last)
    XCTAssertEqual(try TransferMessage.decode(baseline, maximumChunkBytes: 131072)?.number(0), 2)
    XCTAssertEqual(try TransferMessage.decode(extensionBytes, maximumChunkBytes: 262016)?.number(0), 3)
  }

  func testSenderProgressCountsReceiverWritesInsteadOfSocketSubmissions() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel(transport: "ble")
    owner.available(channel)
    defer { owner.dismiss() }
    _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    let url = tempDir.appendingPathComponent("source.bin")
    try Data(repeating: 7, count: 12288).write(to: url)
    await owner.sendFiles(urls: [url])
    for _ in 0..<200 {
      if case .waitingForPeerApproval = owner.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .waitingForPeerApproval(let batch) = owner.state else { return XCTFail("Offer missing") }
    _ = await owner.handle(try TransferMessage.accept(batch: batch.idString, files: []).encode(), on: channel.descriptor)
    for _ in 0..<200 {
      if try channel.sentData.filter({ try TransferMessage.decode($0)?.kind == 5 }).count >= 4 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .transferring(_, _, _, let queuedProgress, _, let queuedTotal, _) = owner.state else { return XCTFail("Stream missing") }
    XCTAssertEqual(queuedProgress, 0)
    XCTAssertEqual(queuedTotal, 0)
    _ = await owner.handle(try TransferMessage.ack(batch: batch.idString, file: batch.files[0].idString, written: 3072).encode(), on: channel.descriptor)
    try await Task.sleep(for: .milliseconds(300))
    guard case .transferring(_, _, _, let confirmed, _, let total, _) = owner.state else { return XCTFail("Stream missing") }
    XCTAssertEqual(confirmed, 3072)
    XCTAssertEqual(total, 3072)
    guard case .transferring(_, _, _, _, _, _, let speed) = owner.state else { return XCTFail("Stream missing") }
    XCTAssertGreaterThan(speed, 0)
    for _ in 0..<65 {
      if case .transferring(_, _, _, _, _, _, let currentSpeed) = owner.state, currentSpeed == 0 { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard case .transferring(_, _, _, _, _, let stalledTotal, let stalledSpeed) = owner.state else { return XCTFail("Stream missing") }
    XCTAssertEqual(stalledTotal, 3072)
    XCTAssertEqual(stalledSpeed, 0)
  }

  func testLANWinsEitherConnectionOrderAndFallsBackOnlyOnItsRetirement() async throws {
    for lanFirst in [false, true] {
      let owner = MacTransferModel(), lan = MockSecuredChannel(instance: "lan")
      let ble = MockSecuredChannel(instance: "ble", transport: "ble", peer: lan.descriptor.peer)
      for channel in lanFirst ? [lan, ble] : [ble, lan] {
        owner.available(channel)
        _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
      }
      XCTAssertEqual(owner.activeChannel?.descriptor, lan.descriptor)
      XCTAssertTrue(owner.peerCompatible)
      let handlingResult1 = await owner.handle(try TransferMessage.cancel(batch: UUID().uuidString.lowercased(), file: "", reason: 0).encode(), on: ble.descriptor)
      XCTAssertEqual(handlingResult1, .discarded)
      owner.retired(ChannelDescriptor(instance: "stale", transport: "lan", peer: lan.descriptor.peer))
      XCTAssertEqual(owner.activeChannel?.descriptor, lan.descriptor)
      owner.retired(lan.descriptor)
      XCTAssertEqual(owner.activeChannel?.descriptor, ble.descriptor)
      XCTAssertTrue(owner.peerCompatible)
      owner.retired(ble.descriptor)
      XCTAssertFalse(owner.peerConnected)
      XCTAssertFalse(owner.peerCompatible)
    }
  }

  func testCapabilityDoesNotLeakAcrossChannelsOrSessionReplacement() async throws {
    let owner = MacTransferModel(), ble = MockSecuredChannel(instance: "ble", transport: "ble")
    let lan = MockSecuredChannel(instance: "lan", peer: ble.descriptor.peer)
    owner.available(ble)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: ble.descriptor)
    owner.available(lan)
    XCTAssertEqual(owner.activeChannel?.descriptor, ble.descriptor)
    XCTAssertTrue(owner.peerCompatible)
    owner.retired(ble.descriptor)
    XCTAssertEqual(owner.activeChannel?.descriptor, lan.descriptor)
    XCTAssertFalse(owner.peerCompatible)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: lan.descriptor)
    let successor = MockSecuredChannel(instance: "successor", peer: lan.descriptor.peer)
    owner.available(successor)
    XCTAssertFalse(owner.peerCompatible)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: lan.descriptor)
    XCTAssertFalse(owner.peerCompatible)
    owner.dismiss()
  }

  func testLANLossPausesReceiverRetainsPartialAndResumesOverBLE() async throws {
    let owner = MacTransferModel(), lan = MockSecuredChannel(instance: "lan")
    let ble = MockSecuredChannel(instance: "ble", transport: "ble", peer: lan.descriptor.peer)
    for channel in [lan, ble] {
      owner.available(channel)
      _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    }
    try await offer(owner, lan, size: 10)
    guard case .incomingOffer(let batch) = owner.state else { return XCTFail("Missing offer") }
    await owner.acceptIncomingOffer(destination: tempDir)
    _ = await owner.handle(try TransferMessage.chunk(batch: batch.idString, file: batch.files[0].idString,
      offset: 0, data: Data([0])).encode(), on: lan.descriptor)

    owner.retired(lan.descriptor)
    guard case .paused(_, _, _, let fileBytes, _, _, _, let canResumeOverBle) = owner.state else {
      return XCTFail("LAN loss must pause, not fail: \(owner.state)")
    }
    XCTAssertEqual(fileBytes, 1)
    XCTAssertTrue(canResumeOverBle, "A receiver with only a capable BLE channel may continue over it")
    XCTAssertEqual(owner.activeChannel?.descriptor, ble.descriptor)
    XCTAssertEqual(try partialNames(in: tempDir).count, 1, "The verified prefix must survive the pause")

    // Old-channel chunks are discarded; the retained prefix is untouched.
    let stale = await owner.handle(try TransferMessage.chunk(batch: batch.idString, file: batch.files[0].idString,
      offset: 1, data: Data(repeating: 0, count: 9)).encode(), on: lan.descriptor)
    XCTAssertEqual(stale, .discarded)
    XCTAssertTrue(owner.isPaused)

    // The sender resumes over BLE at the receiver's retained length.
    let prefix = Data(SHA256.hash(data: Data([0])))
    _ = await owner.handle(try TransferMessage.resume(batch: batch.idString, file: batch.files[0].idString,
      offset: 1, prefixHash: prefix).encode(), on: ble.descriptor)
    let status = try XCTUnwrap(statuses(ble).last)
    XCTAssertEqual(status.number(3), 0)
    XCTAssertEqual(status.number(2), 1)

    _ = await owner.handle(try TransferMessage.chunk(batch: batch.idString, file: batch.files[0].idString,
      offset: 1, data: Data(repeating: 0, count: 9)).encode(), on: ble.descriptor)
    for _ in 0..<200 {
      if case .completed = owner.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .completed = owner.state else { return XCTFail("Resumed batch did not complete: \(owner.state)") }
    XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("empty.bin")), Data(repeating: 0, count: 10))
    XCTAssertTrue(try partialNames(in: tempDir).isEmpty)
    owner.dismiss()
  }

  func testPauseTimeoutRemovesPartialAndFails() async throws {
    let owner = MacTransferModel(pauseTimeout: .milliseconds(25))
    let channel = MockSecuredChannel(instance: "lan")
    owner.available(channel)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    try await offer(owner, channel, size: 10)
    guard case .incomingOffer(let batch) = owner.state else { return XCTFail("Missing offer") }
    await owner.acceptIncomingOffer(destination: tempDir)
    _ = await owner.handle(try TransferMessage.chunk(batch: batch.idString, file: batch.files[0].idString,
      offset: 0, data: Data([0])).encode(), on: channel.descriptor)
    owner.retired(channel.descriptor)
    XCTAssertTrue(owner.isPaused)

    for _ in 0..<400 {
      if case .failed = owner.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .failed(let reason) = owner.state else { return XCTFail("Pause must time out: \(owner.state)") }
    XCTAssertTrue(reason.contains("paused for too long"))
    for _ in 0..<400 {
      if try partialNames(in: tempDir).isEmpty { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(try partialNames(in: tempDir).isEmpty, "The timed-out partial must be deleted")
    owner.dismiss()
  }

  func testCancelWhilePausedDeletesPartial() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel()
    owner.available(channel)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    try await offer(owner, channel, size: 10)
    guard case .incomingOffer(let batch) = owner.state else { return XCTFail("Missing offer") }
    await owner.acceptIncomingOffer(destination: tempDir)
    _ = await owner.handle(try TransferMessage.chunk(batch: batch.idString, file: batch.files[0].idString,
      offset: 0, data: Data([0])).encode(), on: channel.descriptor)
    owner.retired(channel.descriptor)
    XCTAssertTrue(owner.isPaused)

    owner.cancelTransfer()
    XCTAssertEqual(owner.state, .cancelled)
    for _ in 0..<400 {
      if try partialNames(in: tempDir).isEmpty { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(try partialNames(in: tempDir).isEmpty, "Cancel must delete the paused partial")
  }

  func testResumeOffsetMismatchAndPrefixMismatchRecover() async throws {
    let owner = MacTransferModel(), lan = MockSecuredChannel(instance: "lan")
    let ble = MockSecuredChannel(instance: "ble", transport: "ble", peer: lan.descriptor.peer)
    for channel in [lan, ble] {
      owner.available(channel)
      _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    }
    try await offer(owner, lan, size: 10)
    guard case .incomingOffer(let batch) = owner.state else { return XCTFail("Missing offer") }
    await owner.acceptIncomingOffer(destination: tempDir)
    _ = await owner.handle(try TransferMessage.chunk(batch: batch.idString, file: batch.files[0].idString,
      offset: 0, data: Data(repeating: 0, count: 4)).encode(), on: lan.descriptor)
    owner.retired(lan.descriptor)
    XCTAssertTrue(owner.isPaused)

    // A requested offset beyond the retained length reports the real length.
    _ = await owner.handle(try TransferMessage.resume(batch: batch.idString, file: batch.files[0].idString,
      offset: 9, prefixHash: Data(SHA256.hash(data: Data(repeating: 0, count: 9)))).encode(), on: ble.descriptor)
    XCTAssertEqual(try XCTUnwrap(statuses(ble).last).number(3), 1)
    XCTAssertEqual(try XCTUnwrap(statuses(ble).last).number(2), 4)

    // A prefix that does not match discards the retained bytes and restarts from zero.
    _ = await owner.handle(try TransferMessage.resume(batch: batch.idString, file: batch.files[0].idString,
      offset: 4, prefixHash: Data(repeating: 0, count: 32)).encode(), on: ble.descriptor)
    XCTAssertEqual(try XCTUnwrap(statuses(ble).last).number(3), 2)
    let parts = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(".anice-") }
    XCTAssertEqual(parts.count, 1)
    XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(parts.first)).count, 0)

    _ = await owner.handle(try TransferMessage.resume(batch: batch.idString, file: batch.files[0].idString,
      offset: 0, prefixHash: Data(SHA256.hash(data: Data()))).encode(), on: ble.descriptor)
    XCTAssertEqual(try XCTUnwrap(statuses(ble).last).number(3), 0)
    _ = await owner.handle(try TransferMessage.chunk(batch: batch.idString, file: batch.files[0].idString,
      offset: 0, data: Data(repeating: 0, count: 10)).encode(), on: ble.descriptor)
    for _ in 0..<200 {
      if case .completed = owner.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .completed = owner.state else { return XCTFail("Restarted batch did not complete: \(owner.state)") }
    XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("empty.bin")), Data(repeating: 0, count: 10))
    owner.dismiss()
  }

  func testLastChunkPauseReplaysVerifiedFileResult() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel()
    owner.available(channel)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    try await offer(owner, channel, size: 4)
    guard case .incomingOffer(let batch) = owner.state else { return XCTFail("Missing offer") }
    await owner.acceptIncomingOffer(destination: tempDir)
    _ = await owner.handle(try TransferMessage.chunk(batch: batch.idString, file: batch.files[0].idString,
      offset: 0, data: Data(repeating: 0, count: 4)).encode(), on: channel.descriptor)
    for _ in 0..<200 {
      if case .completed = owner.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .completed = owner.state else { return XCTFail("File did not complete") }
    let resultsBefore = channel.sentData.compactMap { try? TransferMessage.decode($0) }.filter { $0.kind == 7 }.count

    // The sender reconnects after the final chunk was acknowledged but before it saw the result.
    _ = await owner.handle(try TransferMessage.resume(batch: batch.idString, file: batch.files[0].idString,
      offset: 4, prefixHash: Data(SHA256.hash(data: Data(repeating: 0, count: 4)))).encode(), on: channel.descriptor)
    let status = try XCTUnwrap(statuses(channel).last)
    XCTAssertEqual(status.number(3), 0)
    XCTAssertEqual(status.number(2), 4)
    let resultsAfter = channel.sentData.compactMap { try? TransferMessage.decode($0) }.filter { $0.kind == 7 }.count
    XCTAssertGreaterThan(resultsAfter, resultsBefore, "The verified file result must be replayed")
    owner.dismiss()
  }

  func testAsymmetricReceiverAcceptsResumeWhileStillTransferring() async throws {
    let owner = MacTransferModel(), lan = MockSecuredChannel(instance: "lan")
    let ble = MockSecuredChannel(instance: "ble", transport: "ble", peer: lan.descriptor.peer)
    for channel in [lan, ble] {
      owner.available(channel)
      _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    }
    try await offer(owner, lan, size: 10)
    guard case .incomingOffer(let batch) = owner.state else { return XCTFail("Missing offer") }
    await owner.acceptIncomingOffer(destination: tempDir)
    _ = await owner.handle(try TransferMessage.chunk(batch: batch.idString, file: batch.files[0].idString,
      offset: 0, data: Data([0])).encode(), on: lan.descriptor)
    XCTAssertEqual(owner.activeChannel?.descriptor, lan.descriptor)

    // Only the sender lost its channel; the receiver is still transferring but must accept the
    // sender's resume on the new channel and rebind to it.
    _ = await owner.handle(try TransferMessage.resume(batch: batch.idString, file: batch.files[0].idString,
      offset: 1, prefixHash: Data(SHA256.hash(data: Data([0])))).encode(), on: ble.descriptor)
    XCTAssertEqual(try XCTUnwrap(statuses(ble).last).number(3), 0)
    XCTAssertEqual(owner.activeChannel?.descriptor, ble.descriptor)

    _ = await owner.handle(try TransferMessage.chunk(batch: batch.idString, file: batch.files[0].idString,
      offset: 1, data: Data(repeating: 0, count: 9)).encode(), on: ble.descriptor)
    for _ in 0..<200 {
      if case .completed = owner.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .completed = owner.state else { return XCTFail("Asymmetric resume did not complete: \(owner.state)") }
    XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("empty.bin")), Data(repeating: 0, count: 10))
    owner.dismiss()
  }

  func testLANPauseAutoResumesWhenLanReconnects() async throws {
    let sender = MacTransferModel(), receiver = MacTransferModel()
    let senderLan = MockSecuredChannel(instance: "sender-lan", deviceName: "MacBook")
    let receiverLan = MockSecuredChannel(instance: "receiver-lan", deviceName: "Phone")
    let capability = try TransferMessage.capability().encode()
    sender.available(senderLan); _ = await sender.handle(capability, on: senderLan.descriptor)
    receiver.available(receiverLan); _ = await receiver.handle(capability, on: receiverLan.descriptor)

    var gateReached = false
    senderLan.onSendData = { bytes in
      if let message = try? TransferMessage.decode(bytes), !gateReached,
        message.kind == 5, message.number(2) == 6144 {
        gateReached = true
        // Suspends the stream until the pause cancels it, so the third chunk never reaches the peer.
        try await Task.sleep(for: .seconds(600))
      }
      _ = await receiver.handle(bytes, on: receiverLan.descriptor)
    }
    receiverLan.onSendData = { bytes in _ = await sender.handle(bytes, on: senderLan.descriptor) }

    let data = Data((0..<20_000).map { UInt8($0 % 251) })
    let source = tempDir.appendingPathComponent("source.bin")
    try data.write(to: source)
    let dest = tempDir.appendingPathComponent("dest")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

    await sender.sendFiles(urls: [source])
    guard case .incomingOffer = receiver.state else { return XCTFail("Missing offer") }
    await receiver.acceptIncomingOffer(destination: dest)
    for _ in 0..<400 {
      if gateReached { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(gateReached)

    sender.retired(senderLan.descriptor)
    XCTAssertTrue(sender.isPaused, "A lost LAN channel must pause the sender")
    XCTAssertFalse(receiver.isPaused, "The receiver's partial must survive the sender's pause")

    // The same peer answers on a fresh LAN channel; the sender resumes automatically.
    let senderLan2 = MockSecuredChannel(instance: "sender-lan-2", deviceName: "MacBook", peer: senderLan.descriptor.peer)
    senderLan2.onSendData = { bytes in _ = await receiver.handle(bytes, on: receiverLan.descriptor) }
    receiverLan.onSendData = { bytes in _ = await sender.handle(bytes, on: senderLan2.descriptor) }
    sender.available(senderLan2)
    _ = await sender.handle(capability, on: senderLan2.descriptor)

    for _ in 0..<800 {
      if case .completed = sender.state, case .completed = receiver.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .completed = sender.state, case .completed = receiver.state else {
      return XCTFail("Auto-resume did not complete; sender: \(sender.state), receiver: \(receiver.state)")
    }
    XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("source.bin")), data)
    XCTAssertTrue(try partialNames(in: dest).isEmpty)
    XCTAssertTrue(senderLan2.sentData.compactMap { try? TransferMessage.decode($0) }.contains { $0.kind == 10 },
      "A reconnected LAN channel must trigger a resume request")
    sender.dismiss(); receiver.dismiss()
  }

  func testBLEContinuationRequiresExplicitOptIn() async throws {
    let sender = MacTransferModel(), receiver = MacTransferModel()
    let senderLan = MockSecuredChannel(instance: "sender-lan", deviceName: "MacBook")
    let receiverLan = MockSecuredChannel(instance: "receiver-lan", deviceName: "Phone")
    let senderBle = MockSecuredChannel(instance: "sender-ble", transport: "ble", deviceName: "MacBook", peer: senderLan.descriptor.peer)
    let receiverBle = MockSecuredChannel(instance: "receiver-ble", transport: "ble", deviceName: "Phone", peer: receiverLan.descriptor.peer)
    let capability = try TransferMessage.capability().encode()
    for channel in [senderLan, senderBle] {
      sender.available(channel)
      _ = await sender.handle(capability, on: channel.descriptor)
    }
    for channel in [receiverLan, receiverBle] {
      receiver.available(channel)
      _ = await receiver.handle(capability, on: channel.descriptor)
    }

    var gateReached = false
    senderLan.onSendData = { bytes in
      if let message = try? TransferMessage.decode(bytes), !gateReached,
        message.kind == 5, message.number(2) == 6144 {
        gateReached = true
        try await Task.sleep(for: .seconds(600))
      }
      _ = await receiver.handle(bytes, on: receiverLan.descriptor)
    }
    senderBle.onSendData = { bytes in _ = await receiver.handle(bytes, on: receiverBle.descriptor) }
    receiverLan.onSendData = { bytes in _ = await sender.handle(bytes, on: senderLan.descriptor) }
    receiverBle.onSendData = { bytes in _ = await sender.handle(bytes, on: senderBle.descriptor) }

    let data = Data((0..<20_000).map { UInt8($0 % 251) })
    let source = tempDir.appendingPathComponent("source.bin")
    try data.write(to: source)
    let dest = tempDir.appendingPathComponent("dest")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

    await sender.sendFiles(urls: [source])
    guard case .incomingOffer = receiver.state else { return XCTFail("Missing offer") }
    await receiver.acceptIncomingOffer(destination: dest)
    for _ in 0..<400 {
      if gateReached { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(gateReached)

    sender.retired(senderLan.descriptor)
    receiver.retired(receiverLan.descriptor)
    XCTAssertTrue(sender.isPaused)
    XCTAssertTrue(receiver.isPaused)
    guard case .paused(_, _, _, _, _, _, _, let canResume) = sender.state else {
      return XCTFail("Sender must be paused")
    }
    XCTAssertTrue(canResume, "A LAN pause with a capable BLE channel must offer continuation")
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(senderBle.sentData.compactMap { try? TransferMessage.decode($0) }.contains { $0.kind == 10 },
      "BLE must not resume a LAN pause before opt-in")

    let chunksBefore = senderBle.sentData.count
    sender.resumeOverBluetooth()
    for _ in 0..<800 {
      if case .completed = sender.state, case .completed = receiver.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .completed = sender.state, case .completed = receiver.state else {
      return XCTFail("BLE continuation did not complete; sender: \(sender.state), receiver: \(receiver.state)")
    }
    XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("source.bin")), data)
    XCTAssertTrue(try partialNames(in: dest).isEmpty)
    let resumedChunks = senderBle.sentData.dropFirst(chunksBefore).compactMap { try? TransferMessage.decode($0) }
      .filter { $0.kind == 5 }
    XCTAssertFalse(resumedChunks.isEmpty, "Continuation must send chunks over BLE")
    for chunk in resumedChunks {
      XCTAssertLessThanOrEqual(try XCTUnwrap(chunk.bytes(3)).count, 3072)
    }
    sender.dismiss(); receiver.dismiss()
  }

  func testReceiverCanAskTheSenderToContinueOverBluetooth() async throws {
    let sender = MacTransferModel(), receiver = MacTransferModel()
    let senderLan = MockSecuredChannel(instance: "sender-lan", deviceName: "MacBook")
    let receiverLan = MockSecuredChannel(instance: "receiver-lan", deviceName: "Phone")
    let senderBle = MockSecuredChannel(instance: "sender-ble", transport: "ble", deviceName: "MacBook", peer: senderLan.descriptor.peer)
    let receiverBle = MockSecuredChannel(instance: "receiver-ble", transport: "ble", deviceName: "Phone", peer: receiverLan.descriptor.peer)
    let capability = try TransferMessage.capability().encode()
    for channel in [senderLan, senderBle] {
      sender.available(channel)
      _ = await sender.handle(capability, on: channel.descriptor)
    }
    for channel in [receiverLan, receiverBle] {
      receiver.available(channel)
      _ = await receiver.handle(capability, on: channel.descriptor)
    }

    var gateReached = false
    senderLan.onSendData = { bytes in
      if let message = try? TransferMessage.decode(bytes), !gateReached,
        message.kind == 5, message.number(2) == 6144 {
        gateReached = true
        try await Task.sleep(for: .seconds(600))
      }
      _ = await receiver.handle(bytes, on: receiverLan.descriptor)
    }
    senderBle.onSendData = { bytes in _ = await receiver.handle(bytes, on: receiverBle.descriptor) }
    receiverLan.onSendData = { bytes in _ = await sender.handle(bytes, on: senderLan.descriptor) }
    receiverBle.onSendData = { bytes in _ = await sender.handle(bytes, on: senderBle.descriptor) }

    let data = Data((0..<20_000).map { UInt8($0 % 251) })
    let source = tempDir.appendingPathComponent("source.bin")
    try data.write(to: source)
    let dest = tempDir.appendingPathComponent("dest")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

    await sender.sendFiles(urls: [source])
    guard case .incomingOffer = receiver.state else { return XCTFail("Missing offer") }
    await receiver.acceptIncomingOffer(destination: dest)
    for _ in 0..<400 {
      if gateReached { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(gateReached)

    sender.retired(senderLan.descriptor)
    receiver.retired(receiverLan.descriptor)
    guard case .paused(_, _, _, _, _, _, _, let canResume) = receiver.state else {
      return XCTFail("Receiver must be paused")
    }
    XCTAssertTrue(canResume, "The receiver with a capable BLE channel must offer continuation")
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(receiverBle.sentData.compactMap { try? TransferMessage.decode($0) }.contains { $0.kind == 10 },
      "No continuation happens before the explicit opt-in")

    // The receiving device, not the sender, initiates the resume over Bluetooth.
    receiver.resumeOverBluetooth()
    for _ in 0..<800 {
      if case .completed = sender.state, case .completed = receiver.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .completed = sender.state, case .completed = receiver.state else {
      return XCTFail("Receiver-initiated continuation did not complete; sender: \(sender.state), receiver: \(receiver.state)")
    }
    XCTAssertTrue(receiverBle.sentData.compactMap { try? TransferMessage.decode($0) }.contains { $0.kind == 10 },
      "The receiver must send the resume request")
    XCTAssertTrue(senderBle.sentData.compactMap { try? TransferMessage.decode($0) }.contains { $0.kind == 11 },
      "The sender must answer over the same channel")
    XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("source.bin")), data)
    XCTAssertTrue(try partialNames(in: dest).isEmpty)
    sender.dismiss(); receiver.dismiss()
  }

  func testLANReconnectUpgradesAnActiveBluetoothStream() async throws {
    let sender = MacTransferModel(), receiver = MacTransferModel()
    let senderBle = MockSecuredChannel(instance: "sender-ble", transport: "ble", deviceName: "MacBook")
    let receiverBle = MockSecuredChannel(instance: "receiver-ble", transport: "ble", deviceName: "Phone",
      peer: senderBle.descriptor.peer)
    let capability = try TransferMessage.capability().encode()
    for channel in [senderBle] {
      sender.available(channel)
      _ = await sender.handle(capability, on: channel.descriptor)
    }
    for channel in [receiverBle] {
      receiver.available(channel)
      _ = await receiver.handle(capability, on: channel.descriptor)
    }

    var gateReached = false
    senderBle.onSendData = { bytes in
      if let message = try? TransferMessage.decode(bytes), !gateReached,
        message.kind == 5, message.number(2) == 6144 {
        gateReached = true
        try await Task.sleep(for: .seconds(600))
      }
      _ = await receiver.handle(bytes, on: receiverBle.descriptor)
    }
    receiverBle.onSendData = { bytes in _ = await sender.handle(bytes, on: senderBle.descriptor) }

    let data = Data((0..<20_000).map { UInt8($0 % 251) })
    let source = tempDir.appendingPathComponent("source.bin")
    try data.write(to: source)
    let dest = tempDir.appendingPathComponent("dest")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

    await sender.sendFiles(urls: [source])
    guard case .incomingOffer = receiver.state else { return XCTFail("Missing offer") }
    await receiver.acceptIncomingOffer(destination: dest)
    for _ in 0..<400 {
      if gateReached { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(gateReached)

    // A live LAN appears while the Bluetooth stream is still in flight.
    let senderLan = MockSecuredChannel(instance: "sender-lan", deviceName: "MacBook", peer: senderBle.descriptor.peer)
    let receiverLan = MockSecuredChannel(instance: "receiver-lan", deviceName: "Phone", peer: receiverBle.descriptor.peer)
    senderLan.onSendData = { bytes in _ = await receiver.handle(bytes, on: receiverLan.descriptor) }
    receiverLan.onSendData = { bytes in _ = await sender.handle(bytes, on: senderLan.descriptor) }
    receiver.available(receiverLan)
    _ = await receiver.handle(capability, on: receiverLan.descriptor)
    sender.available(senderLan)
    _ = await sender.handle(capability, on: senderLan.descriptor)

    for _ in 0..<800 {
      if case .completed = sender.state, case .completed = receiver.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    guard case .completed = sender.state, case .completed = receiver.state else {
      return XCTFail("LAN upgrade did not complete; sender: \(sender.state), receiver: \(receiver.state)")
    }
    let lanMessages = senderLan.sentData.compactMap { try? TransferMessage.decode($0) }
    XCTAssertTrue(lanMessages.contains { $0.kind == 10 },
      "The sender must hand the stream over through the resume handshake")
    XCTAssertTrue(lanMessages.contains { $0.kind == 5 },
      "The remainder must continue over LAN, not Bluetooth")
    XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("source.bin")), data)
    XCTAssertTrue(try partialNames(in: dest).isEmpty)
    sender.dismiss(); receiver.dismiss()
  }

  func testActiveBLEBatchKeepsItsGenerationUntilCleanupThenPrefersLAN() async throws {
    let owner = MacTransferModel(), ble = MockSecuredChannel(instance: "ble", transport: "ble")
    let lan = MockSecuredChannel(instance: "lan", peer: ble.descriptor.peer)
    owner.available(ble)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: ble.descriptor)
    try await offer(owner, ble, size: 1)
    owner.available(lan)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: lan.descriptor)
    XCTAssertEqual(owner.activeChannel?.descriptor, ble.descriptor)
    owner.cancelTransfer(local: false)
    XCTAssertEqual(owner.activeChannel?.descriptor, lan.descriptor)
    XCTAssertTrue(owner.peerCompatible)
  }

  func testFallbackRejectsAnotherPeer() async {
    let owner = MacTransferModel(), lan = MockSecuredChannel(instance: "lan")
    let other = MockSecuredChannel(instance: "other", transport: "ble")
    owner.available(lan)
    owner.available(other)
    owner.retired(lan.descriptor)
    XCTAssertFalse(owner.peerConnected)
  }

  func testCancellingBLEBatchStillNotifiesItsPeerWhenLANBecomesPreferred() async throws {
    let owner = MacTransferModel(), ble = MockSecuredChannel(instance: "ble", transport: "ble")
    let lan = MockSecuredChannel(instance: "lan", peer: ble.descriptor.peer)
    owner.available(ble)
    try await offer(owner, ble, size: 1)
    owner.available(lan)
    owner.cancelTransfer()
    XCTAssertEqual(owner.activeChannel?.descriptor, lan.descriptor)
    for _ in 0..<50 {
      if ble.sentData.compactMap({ try? TransferMessage.decode($0) }).contains(where: { $0.kind == 9 }) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(ble.sentData.compactMap { try? TransferMessage.decode($0) }.contains { $0.kind == 9 })
    XCTAssertFalse(lan.sentData.compactMap { try? TransferMessage.decode($0) }.contains { $0.kind == 9 })
  }

  func testStandbyCapabilityWaitSurvivesJobCleanupAndUsesStandbyCapacity() async throws {
    let owner = MacTransferModel(), lan = MockSecuredChannel(instance: "lan")
    let ble = MockSecuredChannel(instance: "ble", transport: "ble", peer: lan.descriptor.peer)
    var attempts = 0
    ble.onSendData = { _ in attempts += 1; if attempts == 1 { throw SessionBackpressure() } }
    owner.available(lan)
    try await offer(owner, lan, size: 1)
    owner.available(ble)
    for _ in 0..<50 { if attempts == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(attempts, 1)
    owner.cancelTransfer(local: false)
    owner.capacityAvailable(ble.descriptor)
    for _ in 0..<50 { if attempts == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(attempts, 2)
    XCTAssertEqual(owner.activeChannel?.descriptor, lan.descriptor)
  }

  func testPartiallyAssembledBLEOfferKeepsItsChannelWhenLANArrives() async throws {
    let owner = MacTransferModel(), ble = MockSecuredChannel(instance: "ble", transport: "ble")
    let lan = MockSecuredChannel(instance: "lan", peer: ble.descriptor.peer)
    owner.available(ble)
    let batch = UUID().uuidString.lowercased()
    let rows: [SessionCBOR] = (0...1).map { index in
      .array([.text(UUID().uuidString.lowercased()), .text("\(index).bin"), .integer(0), .bytes(Data(SHA256.hash(data: Data())))])
    }
    _ = await owner.handle(try TransferMessage.offer(batch: batch, sliceIndex: 0, totalSlices: 2,
      totalFiles: 2, totalBytes: 0, files: [rows[0]]).encode(), on: ble.descriptor)
    owner.available(lan)
    XCTAssertEqual(owner.activeChannel?.descriptor, ble.descriptor)
    _ = await owner.handle(try TransferMessage.offer(batch: batch, sliceIndex: 1, totalSlices: 2,
      totalFiles: 2, totalBytes: 0, files: [rows[1]]).encode(), on: ble.descriptor)
    guard case .incomingOffer = owner.state else { return XCTFail("Offer lost during LAN arrival") }
    XCTAssertEqual(owner.activeChannel?.descriptor, ble.descriptor)
    await owner.rejectIncomingOffer()
    XCTAssertEqual(owner.activeChannel?.descriptor, lan.descriptor)
    XCTAssertTrue(ble.sentData.compactMap { try? TransferMessage.decode($0) }.contains { $0.kind == 4 })
    XCTAssertFalse(lan.sentData.compactMap { try? TransferMessage.decode($0) }.contains { $0.kind == 4 })
  }

  func testCapabilityArrivingAfterOfferRemainsUsableAfterCleanup() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel()
    owner.available(channel)
    try await offer(owner, channel, size: 1)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    await owner.rejectIncomingOffer()
    XCTAssertTrue(owner.peerCompatible)
    owner.retired(channel.descriptor)
    XCTAssertFalse(owner.peerCompatible)
  }

  func testQueuedAckCannotCrossIntoNextChannelOrBatch() async throws {
    let owner = MacTransferModel(), ble = MockSecuredChannel(instance: "ble", transport: "ble")
    let lan = MockSecuredChannel(instance: "lan", peer: ble.descriptor.peer)
    owner.available(ble)
    try await offer(owner, ble, size: 100_000)
    guard case .incomingOffer(let batch) = owner.state else { return XCTFail("Missing offer") }
    await owner.acceptIncomingOffer(destination: tempDir)
    owner.available(lan)
    for index in 0..<8 {
      _ = await owner.handle(try TransferMessage.chunk(batch: batch.idString, file: batch.files[0].idString,
        offset: Int64(index * 3072), data: Data(repeating: 0, count: 3072)).encode(), on: ble.descriptor)
    }
    owner.cancelTransfer(local: false)
    try await offer(owner, lan, size: 1)
    let next = owner.state
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(owner.state, next)
    XCTAssertFalse(lan.sentData.compactMap { try? TransferMessage.decode($0) }.contains { $0.kind == 6 })
    XCTAssertFalse(ble.sentData.compactMap { try? TransferMessage.decode($0) }.contains { $0.kind == 6 })
    owner.dismiss()
  }

  func testLateAcceptFailureCannotFailTheNextOffer() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel()
    owner.available(channel)
    try await offer(owner, channel, size: 1)
    var release: CheckedContinuation<Void, Never>?
    channel.onSendData = { bytes in
      if try TransferMessage.decode(bytes)?.kind == 3 {
        await withCheckedContinuation { release = $0 }
        throw SessionFailure.cancelled
      }
    }
    let accepting = Task { await owner.acceptIncomingOffer(destination: tempDir) }
    for _ in 0..<50 { if release != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
    guard let pending = release else { accepting.cancel(); return XCTFail("Accept was not submitted") }
    owner.cancelTransfer(local: false)
    try await offer(owner, channel, size: 2)
    let next = owner.state
    pending.resume()
    await accepting.value
    XCTAssertEqual(owner.state, next)
    owner.dismiss()
  }

  func testRetiringStandbyChannelReleasesItsCapacityWaitWithoutRetainingOwner() async throws {
    var owner: MacTransferModel? = MacTransferModel()
    weak var releasedOwner = owner
    let lan = MockSecuredChannel(instance: "lan")
    let ble = MockSecuredChannel(instance: "ble", transport: "ble", peer: lan.descriptor.peer)
    var blocked = false
    ble.onSendData = { _ in blocked = true; throw SessionBackpressure() }
    owner?.available(lan)
    owner?.available(ble)
    for _ in 0..<50 { if blocked { break }; try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(blocked)
    owner?.retired(ble.descriptor)
    XCTAssertEqual(owner?.activeChannel?.descriptor, lan.descriptor)
    owner = nil
    for _ in 0..<50 { if releasedOwner == nil { break }; try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertNil(releasedOwner)
  }

  func testOfferAssemblyPreservesOrderingAndRejectsConflictingDuplicates() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel()
    owner.available(channel)
    let batch = UUID().uuidString.lowercased()
    let rows: [SessionCBOR] = (0...1).map { index in
      .array([.text(UUID().uuidString.lowercased()), .text("\(index).bin"), .integer(0), .bytes(Data(SHA256.hash(data: Data())))])
    }
    func slice(_ index: Int64, row: SessionCBOR? = nil) throws -> Data {
      try TransferMessage.offer(batch: batch, sliceIndex: index, totalSlices: 2, totalFiles: 2,
        totalBytes: 0, files: [row ?? rows[Int(index)]]).encode()
    }
    _ = await owner.handle(try slice(1), on: channel.descriptor)
    _ = await owner.handle(try slice(1), on: channel.descriptor)
    XCTAssertEqual(owner.state, .idle)
    _ = await owner.handle(try slice(0), on: MockSecuredChannel(instance: "other").descriptor)
    XCTAssertEqual(owner.state, .idle)
    _ = await owner.handle(try slice(0, row: rows[1]), on: channel.descriptor)
    XCTAssertEqual(owner.state, .idle)
    _ = await owner.handle(try slice(1), on: channel.descriptor)
    _ = await owner.handle(try slice(1, row: rows[0]), on: channel.descriptor)
    _ = await owner.handle(try slice(0), on: channel.descriptor)
    XCTAssertEqual(owner.state, .idle)
    _ = await owner.handle(try slice(1), on: channel.descriptor)
    guard case .incomingOffer(let offer) = owner.state else { return XCTFail("Missing complete offer") }
    XCTAssertEqual(offer.files.map(\.name), ["0.bin", "1.bin"])
    owner.dismiss()
  }

  private func offer(_ owner: MacTransferModel, _ channel: MockSecuredChannel, size: Int64 = 0) async throws {
    let digest = Data(SHA256.hash(data: Data(repeating: 0, count: Int(size))))
    let message = TransferMessage.offer(batch: UUID().uuidString.lowercased(), sliceIndex: 0,
      totalSlices: 1, totalFiles: 1, totalBytes: size,
      files: [.array([.text(UUID().uuidString.lowercased()), .text("empty.bin"), .integer(size), .bytes(digest)])])
    _ = await owner.handle(try message.encode(), on: channel.descriptor)
  }

  private func statuses(_ channel: MockSecuredChannel) -> [TransferMessage] {
    channel.sentData.compactMap { try? TransferMessage.decode($0) }.filter { $0.kind == 11 }
  }

  private func partialNames(in folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".anice-") }
  }

  func testDelayedBatchCompletionCannotCleanUpReplacementOffer() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel()
    owner.available(channel)
    defer { owner.dismiss() }
    _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    let source = tempDir.appendingPathComponent("source-empty.bin")
    try Data().write(to: source)
    await owner.sendFiles(urls: [source])
    guard case .waitingForPeerApproval(let batch) = owner.state else { return XCTFail("Missing offer") }
    var release: CheckedContinuation<Void, Never>?
    channel.onSendData = { bytes in
      if try TransferMessage.decode(bytes)?.kind == 8 {
        await withCheckedContinuation { release = $0 }
      }
    }
    _ = await owner.handle(try TransferMessage.accept(batch: batch.idString, files: []).encode(), on: channel.descriptor)
    for _ in 0..<100 {
      if case .transferring = owner.state { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let file = batch.files[0]
    _ = await owner.handle(try TransferMessage.fileResult(batch: batch.idString, file: file.idString,
      result: 0, hash: file.sha256).encode(), on: channel.descriptor)
    for _ in 0..<100 { if release != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
    let pending = try XCTUnwrap(release)
    owner.cancelTransfer(local: false)
    try await offer(owner, channel, size: 1)
    let replacement = owner.state
    pending.resume()
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(owner.state, replacement)
    XCTAssertNotNil(owner.pendingOffer)
  }

  func testFailedAckWaitsForExternalCapacityInsteadOfRetryingItself() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel()
    owner.available(channel)
    defer { owner.dismiss() }
    try await offer(owner, channel, size: 100_000)
    guard case .incomingOffer(let batch) = owner.state else { return XCTFail("Missing offer") }
    var release: CheckedContinuation<Void, Never>?
    var attempts = 0
    var failed = true
    channel.onSendData = { bytes in
      if try TransferMessage.decode(bytes)?.kind == 6 {
        attempts += 1
        if attempts == 1 { await withCheckedContinuation { release = $0 } }
        // Bound the broken retry loop so a regression fails instead of hanging.
        if failed && attempts < 8 { throw CocoaError(.fileWriteUnknown) }
      }
    }
    await owner.acceptIncomingOffer(destination: tempDir)
    for index in 0..<8 {
      _ = await owner.handle(try TransferMessage.chunk(batch: batch.idString, file: batch.files[0].idString,
        offset: Int64(index * 3072), data: Data(repeating: 0, count: 3072)).encode(), on: channel.descriptor)
    }
    for _ in 0..<100 { if release != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
    let pending = try XCTUnwrap(release)
    // Let the earlier ACK deadline fire while submission is still held.
    try await Task.sleep(for: .milliseconds(30))
    pending.resume()
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(attempts, 1)
    failed = false
    owner.capacityAvailable(channel.descriptor)
    for _ in 0..<100 { if attempts >= 2 { break }; try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(attempts, 2)
  }

  func testCancellationRemovesUnsealedAckWithoutDamagingNextOffer() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel(), admission = SessionDataAdmission()
    let submitted = OSAllocatedUnfairLock(initialState: false)
    let release = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
    let active = Task {
      try await admission.run(bulk: true) {
        await withCheckedContinuation { continuation in
          release.withLock { $0 = continuation }
        }
      }
    }
    do {
      for _ in 0..<200 { if release.withLock({ $0 != nil }) { break }; try await Task.sleep(for: .milliseconds(5)) }
      let pending = try XCTUnwrap(release.withLock { $0 })
      owner.available(channel)
      try await offer(owner, channel, size: 100_000)
      guard case .incomingOffer(let batch) = owner.state else { throw SessionFailure.state }
      channel.onSendData = { bytes in
        if try TransferMessage.decode(bytes)?.kind == 6 {
          try await admission.run(bulk: false) { submitted.withLock { $0 = true } }
        }
      }
      await owner.acceptIncomingOffer(destination: tempDir)
      for index in 0..<8 {
        _ = await owner.handle(try TransferMessage.chunk(batch: batch.idString, file: batch.files[0].idString,
          offset: Int64(index * 3072), data: Data(repeating: 0, count: 3072)).encode(), on: channel.descriptor)
      }
      for _ in 0..<200 { if await admission.pendingCount == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
      let waiting = await admission.pendingCount
      XCTAssertEqual(waiting, 1)
      owner.cancelTransfer(local: false)
      for _ in 0..<200 { if await admission.pendingCount == 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
      let remaining = await admission.pendingCount
      XCTAssertEqual(remaining, 0)
      XCTAssertEqual(owner.state, .cancelled)
      try await offer(owner, channel, size: 1)
      let next = owner.state
      release.withLock { $0 = nil }; pending.resume(); try await active.value
      XCTAssertFalse(submitted.withLock { $0 }, "Cancelled transfer ACK must not acquire a nonce later")
      XCTAssertEqual(owner.state, next)
    } catch {
      let pending = release.withLock { value in let pending = value; value = nil; return pending }
      pending?.resume()
      active.cancel(); _ = try? await active.value
      owner.dismiss(); throw error
    }
    owner.dismiss()
  }

  func testFailedFinalizationCannotReportSuccess() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel()
    owner.available(channel)
    try await offer(owner, channel, size: 1)
    guard case .incomingOffer(let batch) = owner.state else { return XCTFail("Missing offer") }
    await owner.acceptIncomingOffer(destination: tempDir)
    let partial = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".anice-") })
    try FileManager.default.removeItem(at: partial)
    _ = await owner.handle(try TransferMessage.chunk(batch: batch.idString, file: batch.files[0].idString, offset: 0, data: Data([0])).encode(), on: channel.descriptor)
    guard case .failed = owner.state else { return XCTFail("Finalization error ignored") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("empty.bin").path))
    XCTAssertFalse(channel.sentData.compactMap { try? TransferMessage.decode($0) }.contains { $0.kind == 7 && $0.number(2) == 0 })
  }

  func testInconsistentTotalsAndRetiredChannelCannotPresentOffer() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel()
    owner.available(channel)
    let message = TransferMessage.offer(batch: UUID().uuidString.lowercased(), sliceIndex: 0, totalSlices: 1,
      totalFiles: 1, totalBytes: 2, files: [.array([.text(UUID().uuidString.lowercased()), .text("a"), .integer(1), .bytes(Data(repeating: 0, count: 32))])])
    _ = await owner.handle(try message.encode(), on: channel.descriptor)
    XCTAssertEqual(owner.state, .idle)
    let handlingResult3 = await owner.handle(try message.encode(), on: MockSecuredChannel(instance: "retired").descriptor)
    XCTAssertEqual(handlingResult3, .discarded)
    XCTAssertEqual(owner.state, .idle)
  }

  func testLegacyPeerCannotStartTransferWithoutCapability() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel()
    owner.available(channel)
    let source = tempDir.appendingPathComponent("a")
    try Data([1]).write(to: source)
    await owner.sendFiles(urls: [source])
    guard case .failed = owner.state else { return XCTFail("Legacy peer accepted") }
    XCTAssertFalse(channel.sentData.compactMap { try? TransferMessage.decode($0) }.contains { $0.kind == 2 })
  }

  func testEmptyFileCompletesAndPreservesUnrelatedPartial() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel()
    owner.available(channel)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    try await offer(owner, channel)
    let unrelated = tempDir.appendingPathComponent("empty.bin.anice-part")
    try Data("keep".utf8).write(to: unrelated)
    await owner.acceptIncomingOffer(destination: tempDir)
    for _ in 0..<50 { if case .completed = owner.state { break }; try await Task.sleep(for: .milliseconds(10)) }
    guard case .completed = owner.state else { return XCTFail("Empty file did not complete") }
    XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("empty.bin")), Data())
    XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
  }

  func testFailedDestinationDoesNotAcceptOrReportSuccess() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel()
    owner.available(channel)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    try await offer(owner, channel)
    let blocked = tempDir.appendingPathComponent("not-a-folder")
    try Data("keep".utf8).write(to: blocked)
    await owner.acceptIncomingOffer(destination: blocked)
    guard case .failed = owner.state else { return XCTFail("Destination error ignored") }
    let messages = channel.sentData.compactMap { try? TransferMessage.decode($0) }
    XCTAssertFalse(messages.contains { $0.kind == 3 || $0.kind == 7 && $0.number(2) == 0 })
    XCTAssertEqual(try Data(contentsOf: blocked), Data("keep".utf8))
  }

  func testUnrelatedCancelAndBatchResultCannotCompleteCurrentOffer() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel()
    owner.available(channel)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
    try await offer(owner, channel, size: 1)
    let before = owner.state
    _ = await owner.handle(try TransferMessage.batchResult(batch: UUID().uuidString.lowercased(), result: 0).encode(), on: channel.descriptor)
    _ = await owner.handle(try TransferMessage.cancel(batch: UUID().uuidString.lowercased()).encode(), on: channel.descriptor)
    XCTAssertEqual(owner.state, before)
  }

  func testOfferAcceptStreamAndVerifyBatch() async throws { try await verifyBatch(transport: "lan") }

  func testBLEFallbackStreamsAndVerifiesBatch() async throws { try await verifyBatch(transport: "ble") }



  func testSlowLanCreditBoundsSubmittedBytesAndRejectsInvalidAcknowledgements() async throws {
    let owner = MacTransferModel(), channel = MockSecuredChannel(maximumDataBytes: 262144)
    owner.available(channel)
    defer { owner.dismiss() }
    _ = await owner.handle(try TransferMessage.capability(version: 3, maxChunkBytes: 262016, maxWindow: 8).encode(maximumChunkBytes: 262016), on: channel.descriptor)
    let source = tempDir.appendingPathComponent("credit.bin")
    try Data(repeating: 0, count: 8 * 262016 + 7).write(to: source)
    func chunks() -> [TransferMessage] {
      channel.sentData.compactMap { try? TransferMessage.decode($0, maximumChunkBytes: 262016) }.filter { $0.kind == 5 }
    }
    await owner.sendFiles(urls: [source])
    guard case .waitingForPeerApproval(let batch) = owner.state else { return XCTFail("Missing offer") }
    _ = await owner.handle(try TransferMessage.accept(batch: batch.idString, files: []).encode(), on: channel.descriptor)
    for _ in 0..<300 { if !chunks().isEmpty { break }; try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(chunks().count, 1, "Only one small record precedes confirmed progress")
    XCTAssertEqual(chunks().first?.bytes(3).count, 4096)
    _ = await owner.handle(try TransferMessage.ack(batch: batch.idString, file: batch.files[0].idString, written: 4096).encode(), on: channel.descriptor)
    for _ in 0..<300 { if chunks().count >= 3 { break }; try await Task.sleep(for: .milliseconds(10)) }
    _ = await owner.handle(try TransferMessage.ack(batch: batch.idString, file: batch.files[0].idString, written: 4097).encode(), on: channel.descriptor)
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(chunks().count, 3, "Partial ACK cannot admit a whole chunk beyond the byte budget")
    _ = await owner.handle(try TransferMessage.ack(batch: batch.idString, file: batch.files[0].idString, written: 9 * 262016 + 1).encode(), on: channel.descriptor)
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(chunks().count, 3, "Unsubmitted bytes cannot grant credit")
    _ = await owner.handle(try TransferMessage.ack(batch: batch.idString, file: batch.files[0].idString, written: 8192).encode(), on: channel.descriptor)
    for _ in 0..<300 { if chunks().count >= 4 { break }; try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(chunks().count, 4)
    XCTAssertTrue(chunks().allSatisfy { $0.bytes(3).count == 4096 })
    XCTAssertEqual(chunks().map { $0.number(2) }, (0..<4).map { Int64($0) * 4096 })
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }

  func testRequestedLanWaitsAndReceivesTheOffer() async throws {
    let owner = MacTransferModel()
    let ble = MockSecuredChannel(instance: "ble-token", transport: "ble")
    let lan = MockSecuredChannel(instance: "lan-token", transport: "lan", maximumDataBytes: 262144,
      peer: ble.descriptor.peer)
    owner.available(ble)
    defer { owner.dismiss() }
    _ = await owner.handle(try TransferMessage.capability().encode(), on: ble.descriptor)
    let source = tempDir.appendingPathComponent("lan-wait.bin")
    try Data(repeating: 0, count: 4096).write(to: source)
    let lanCapability = try TransferMessage.capability(version: 3, maxChunkBytes: 262016, maxWindow: 8)
      .encode(maximumChunkBytes: 262016)
    var demands = 0
    owner.onLanRequired = {
      demands += 1
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(20))
        owner.available(lan)
        _ = await owner.handle(lanCapability, on: lan.descriptor)
      }
      return true
    }
    await owner.sendFiles(urls: [source])
    guard case .waitingForPeerApproval = owner.state else { return XCTFail("Missing offer after LAN rendezvous") }
    XCTAssertEqual(demands, 1)
    XCTAssertEqual(owner.activeChannel?.descriptor.transport, "lan")
    XCTAssertTrue(lan.sentData.contains { (try? TransferMessage.decode($0))?.kind == 2 })
    XCTAssertFalse(ble.sentData.contains { (try? TransferMessage.decode($0))?.kind == 2 })
  }

  func testRendezvousDismissalCannotStartAnOffer() async throws {
    let owner = MacTransferModel()
    let ble = MockSecuredChannel(instance: "ble-token", transport: "ble")
    owner.available(ble)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: ble.descriptor)
    owner.onLanRequired = { true }
    let source = tempDir.appendingPathComponent("cancel-wait.bin")
    try Data([1]).write(to: source)
    let send = Task { await owner.sendFiles(urls: [source]) }
    await Task.yield()
    owner.dismiss()
    await send.value
    XCTAssertFalse(ble.sentData.contains { (try? TransferMessage.decode($0))?.kind == 2 })
    guard case .idle = owner.state else { return XCTFail("Dismissed send restarted") }
  }

  func testCancelledRendezvousAndConcurrentSendCannotOffer() async throws {
    let owner = MacTransferModel()
    let ble = MockSecuredChannel(instance: "ble-token", transport: "ble")
    owner.available(ble)
    defer { owner.dismiss() }
    _ = await owner.handle(try TransferMessage.capability().encode(), on: ble.descriptor)
    var demands = 0
    owner.onLanRequired = { demands += 1; return true }
    let source = tempDir.appendingPathComponent("concurrent-wait.bin")
    try Data([1]).write(to: source)
    let send = Task { await owner.sendFiles(urls: [source]) }
    await Task.yield()
    await owner.sendFiles(urls: [source])
    send.cancel()
    await send.value
    XCTAssertEqual(demands, 1)
    XCTAssertFalse(ble.sentData.contains { (try? TransferMessage.decode($0))?.kind == 2 })
  }

  func testIncomingOfferCannotReplaceRendezvousPreparation() async throws {
    let owner = MacTransferModel(), ble = MockSecuredChannel(transport: "ble")
    owner.available(ble)
    defer { owner.dismiss() }
    _ = await owner.handle(try TransferMessage.capability().encode(), on: ble.descriptor)
    owner.onLanRequired = { true }
    let source = tempDir.appendingPathComponent("reserved.bin")
    try Data([1]).write(to: source)
    let send = Task { await owner.sendFiles(urls: [source]) }
    await Task.yield()
    let batch = UUID().uuidString.lowercased()
    let offer = try TransferMessage.offer(batch: batch, sliceIndex: 0, totalSlices: 1,
      totalFiles: 1, totalBytes: 0, files: [.array([.text(UUID().uuidString.lowercased()),
        .text("empty.txt"), .integer(0), .bytes(Data(SHA256.hash(data: Data())))])]).encode()
    _ = await owner.handle(offer, on: ble.descriptor)
    XCTAssertNil(owner.pendingOffer)
    send.cancel()
    await send.value
    let lan = MockSecuredChannel(transport: "lan", peer: ble.descriptor.peer)
    owner.available(lan)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: lan.descriptor)
    XCTAssertFalse(lan.sentData.contains { (try? TransferMessage.decode($0))?.kind == 2 })
    XCTAssertFalse(ble.sentData.contains { (try? TransferMessage.decode($0))?.kind == 2 })
  }

  func testRendezvousRouteLossCannotRedirectPreparationToAnotherPeer() async throws {
    let owner = MacTransferModel(), ble = MockSecuredChannel(transport: "ble")
    let other = MockSecuredChannel(transport: "lan")
    owner.available(ble)
    defer { owner.dismiss() }
    _ = await owner.handle(try TransferMessage.capability().encode(), on: ble.descriptor)
    let entered = expectation(description: "Preparation owns rendezvous")
    owner.onLanRequired = { entered.fulfill(); return true }
    let source = tempDir.appendingPathComponent("peer-bound.bin")
    try Data([1]).write(to: source)
    let send = Task { await owner.sendFiles(urls: [source]) }
    await fulfillment(of: [entered], timeout: 1)
    owner.retired(ble.descriptor)
    owner.available(other)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: other.descriptor)
    await send.value
    XCTAssertFalse(other.sentData.contains { (try? TransferMessage.decode($0))?.kind == 2 })
    XCTAssertFalse(ble.sentData.contains { (try? TransferMessage.decode($0))?.kind == 2 })
    XCTAssertFalse(owner.preparing)
    guard case .failed = owner.state else { return XCTFail("Lost route did not release preparation") }
    owner.onLanRequired = { false }
    owner.available(ble)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: ble.descriptor)
    await owner.sendFiles(urls: [source])
    XCTAssertTrue(ble.sentData.contains { (try? TransferMessage.decode($0))?.kind == 2 })
  }

  func testIncapableLanDoesNotHideBluetooth() async throws {
    let owner = MacTransferModel()
    let ble = MockSecuredChannel(instance: "ble-token", transport: "ble")
    let lan = MockSecuredChannel(instance: "lan-token", transport: "lan", peer: ble.descriptor.peer)
    owner.available(ble)
    _ = await owner.handle(try TransferMessage.capability().encode(), on: ble.descriptor)
    owner.available(lan)
    defer { owner.dismiss() }
    let source = tempDir.appendingPathComponent("ble-fallback.bin")
    try Data([1]).write(to: source)
    await owner.sendFiles(urls: [source])
    XCTAssertTrue(ble.sentData.contains { (try? TransferMessage.decode($0))?.kind == 2 })
    XCTAssertFalse(lan.sentData.contains { (try? TransferMessage.decode($0))?.kind == 2 })
  }

  func testLargerLanChunksStreamAcrossCreditWindows() async throws { try await verifyBatch(transport: "lan", maximumChunkBytes: 262016) }

  func testDirectionAndFinalizationAreObservableAcrossAFullRoundTrip() async throws {
    let capability = try TransferMessage.capability().encode(maximumChunkBytes: 3072)
    let sender = MacTransferModel()
    let receiver = MacTransferModel()

    let senderChannel = MockSecuredChannel(transport: "lan", deviceName: "MacBook", maximumDataBytes: 4000)
    let receiverChannel = MockSecuredChannel(transport: "lan", deviceName: "Phone", maximumDataBytes: 4000)

    sender.available(senderChannel)
    _ = await sender.handle(capability, on: senderChannel.descriptor)
    receiver.available(receiverChannel)
    _ = await receiver.handle(capability, on: receiverChannel.descriptor)

    senderChannel.onSendData = { data in _ = await receiver.handle(data, on: receiverChannel.descriptor) }
    receiverChannel.onSendData = { data in _ = await sender.handle(data, on: senderChannel.descriptor) }

    // No batch exists yet, so neither side may claim a direction.
    XCTAssertFalse(sender.receiving)
    XCTAssertFalse(receiver.receiving)

    let testData = Data((0..<12288).map { UInt8($0 % 251) })
    let testFileURL = tempDir.appendingPathComponent("direction.bin")
    try testData.write(to: testFileURL)

    await sender.sendFiles(urls: [testFileURL])

    guard case .incomingOffer = receiver.state else {
      XCTFail("Expected incomingOffer on receiver, got \(receiver.state)")
      return
    }
    XCTAssertFalse(receiver.receiving, "An unapproved offer must not claim the receiving direction")

    let destFolder = tempDir.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
    await receiver.acceptIncomingOffer(destination: destFolder)
    XCTAssertTrue(receiver.receiving, "Receiver must report the receiving direction")

    var completed = false
    for _ in 0..<50 {
      if case .completed = receiver.state, case .completed = sender.state {
        completed = true
        break
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(completed, "Transfer did not complete in time")

    // The completed panel still reports which way the files moved, so the direction has to outlive
    // the cleanup that runs immediately after the completed state is published.
    XCTAssertTrue(receiver.receiving, "Receiver lost its direction at completion")
    XCTAssertFalse(sender.receiving, "Sender claimed the receiving direction")
    XCTAssertFalse(receiver.finalizing, "Finalization outlived the batch")
    XCTAssertFalse(sender.finalizing)

    receiver.dismiss()
    XCTAssertFalse(receiver.receiving, "Dismiss must clear the recorded direction")
  }

  private func verifyBatch(transport: String, maximumChunkBytes: Int = 3072) async throws {
    let maximumDataBytes = maximumChunkBytes > 3072 ? 262144 : 4000
    let capabilityVersion: Int64 = maximumChunkBytes > 131072 ? 3 : maximumChunkBytes > 3072 ? 2 : 1
    let capability = try TransferMessage.capability(version: capabilityVersion, maxChunkBytes: Int64(maximumChunkBytes), maxWindow: maximumChunkBytes > 3072 ? 8 : 64).encode(maximumChunkBytes: maximumChunkBytes)
    let sender = MacTransferModel()
    let receiver = MacTransferModel()

    let senderChannel = MockSecuredChannel(transport: transport, deviceName: "MacBook", maximumDataBytes: maximumDataBytes)
    let receiverChannel = MockSecuredChannel(transport: transport, deviceName: "Phone", maximumDataBytes: maximumDataBytes)

    sender.available(senderChannel)

    _ = await sender.handle(capability, on: senderChannel.descriptor)
    receiver.available(receiverChannel)
    _ = await receiver.handle(capability, on: receiverChannel.descriptor)

    // Route messages between sender and receiver
    senderChannel.onSendData = { data in
      _ = await receiver.handle(data, on: receiverChannel.descriptor)
    }
    receiverChannel.onSendData = { data in
      _ = await sender.handle(data, on: senderChannel.descriptor)
    }

    // Create a 10 KiB test file
    let testData = Data((0..<(maximumChunkBytes > 3072 ? 2097169 : 10240)).map { UInt8($0 % 251) })
    let testFileURL = tempDir.appendingPathComponent("sample.bin")
    try testData.write(to: testFileURL)

    // Send file
    await sender.sendFiles(urls: [testFileURL])

    // Receiver should have incoming offer
    guard case .incomingOffer(let batch) = receiver.state else {
      XCTFail("Expected incomingOffer on receiver, got \(receiver.state)")
      return
    }
    XCTAssertEqual(batch.files.count, 1)
    XCTAssertEqual(batch.files[0].name, "sample.bin")
    XCTAssertEqual(batch.files[0].size, Int64(testData.count))

    // Accept offer on receiver
    let destFolder = tempDir.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)

    await receiver.acceptIncomingOffer(destination: destFolder)

    // Wait briefly for transfer task to stream and complete
    var completed = false
    for _ in 0..<500 {
      if case .completed = receiver.state, case .completed = sender.state {
        completed = true
        break
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    XCTAssertTrue(completed, "Transfer did not complete in time")

    // Verify received file on disk
    let receivedFileURL = destFolder.appendingPathComponent("sample.bin")
    XCTAssertTrue(FileManager.default.fileExists(atPath: receivedFileURL.path))
    let receivedData = try Data(contentsOf: receivedFileURL)
    XCTAssertEqual(receivedData, testData)

    // Ensure .anice-part file was cleaned up
    let partURL = destFolder.appendingPathComponent("sample.bin.anice-part")
    XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
  }

  func testAdversarialHashMismatchFailsAndDeletesPartialFile() async throws {
    let receiver = MacTransferModel()
    let receiverChannel = MockSecuredChannel(deviceName: "Phone")
    receiver.available(receiverChannel)
    _ = await receiver.handle(try TransferMessage.capability().encode(), on: receiverChannel.descriptor)

    let batchId = UUID().uuidString.lowercased()
    let fileId = UUID().uuidString.lowercased()
    let correctHash = Data(SHA256.hash(data: Data([1, 2, 3, 4])))

    // Send offer
    let offer = TransferMessage.offer(
      batch: batchId,
      sliceIndex: 0,
      totalSlices: 1,
      totalFiles: 1,
      totalBytes: 4,
      files: [
        SessionCBOR.array([
          .text(fileId),
          .text("corrupted.bin"),
          .integer(4),
          .bytes(correctHash)
        ])
      ]
    )
    _ = await receiver.handle(try offer.encode(), on: receiverChannel.descriptor)

    guard case .incomingOffer = receiver.state else {
      XCTFail("Receiver did not enter incomingOffer")
      return
    }

    let destFolder = tempDir.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
    await receiver.acceptIncomingOffer(destination: destFolder)

    // Corrupted chunk data: [1, 2, 3, 99] instead of [1, 2, 3, 4]
    let corruptedChunk = TransferMessage.chunk(
      batch: batchId,
      file: fileId,
      offset: 0,
      data: Data([1, 2, 3, 99])
    )
    _ = await receiver.handle(try corruptedChunk.encode(), on: receiverChannel.descriptor)

    // Wait for failure
    guard case .failed(let reason) = receiver.state else {
      XCTFail("Expected failure on corrupted chunk, got \(receiver.state)")
      return
    }
    XCTAssertTrue(reason.contains("Hash mismatch") || reason.contains("mismatch"))

    // Destination file should NOT exist
    let targetURL = destFolder.appendingPathComponent("corrupted.bin")
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))

    // Part file should have been deleted
    let partURL = destFolder.appendingPathComponent("corrupted.bin.anice-part")
    XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
  }

  func testRejectOfferReturnsToIdle() async throws {
    let receiver = MacTransferModel()
    let receiverChannel = MockSecuredChannel(deviceName: "Phone")
    receiver.available(receiverChannel)
    _ = await receiver.handle(try TransferMessage.capability().encode(), on: receiverChannel.descriptor)

    let batchId = UUID().uuidString.lowercased()
    let fileId = UUID().uuidString.lowercased()

    let offer = TransferMessage.offer(
      batch: batchId,
      sliceIndex: 0,
      totalSlices: 1,
      totalFiles: 1,
      totalBytes: 100,
      files: [
        SessionCBOR.array([
          .text(fileId),
          .text("declined.bin"),
          .integer(100),
          .bytes(Data(repeating: 0xaa, count: 32))
        ])
      ]
    )
    _ = await receiver.handle(try offer.encode(), on: receiverChannel.descriptor)

    XCTAssertTrue(receiver.state != .idle)
    await receiver.rejectIncomingOffer(reason: 0)
    XCTAssertEqual(receiver.state, .idle)
  }

  func testLocalCancellationCleansUp() async throws {
    let receiver = MacTransferModel()
    let receiverChannel = MockSecuredChannel(deviceName: "Phone")
    receiver.available(receiverChannel)
    _ = await receiver.handle(try TransferMessage.capability().encode(), on: receiverChannel.descriptor)

    let batchId = UUID().uuidString.lowercased()
    let fileId = UUID().uuidString.lowercased()

    let offer = TransferMessage.offer(
      batch: batchId,
      sliceIndex: 0,
      totalSlices: 1,
      totalFiles: 1,
      totalBytes: 100,
      files: [
        SessionCBOR.array([
          .text(fileId),
          .text("cancelled.bin"),
          .integer(100),
          .bytes(Data(repeating: 0xaa, count: 32))
        ])
      ]
    )
    _ = await receiver.handle(try offer.encode(), on: receiverChannel.descriptor)

    let destFolder = tempDir.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
    await receiver.acceptIncomingOffer(destination: destFolder)

    // Send partial chunk
    let chunk = TransferMessage.chunk(batch: batchId, file: fileId, offset: 0, data: Data([1, 2, 3]))
    _ = await receiver.handle(try chunk.encode(), on: receiverChannel.descriptor)

    // Now cancel
    receiver.cancelTransfer(local: true)
    XCTAssertEqual(receiver.state, .cancelled)

    // Part file should be deleted
    let partURL = destFolder.appendingPathComponent("cancelled.bin.anice-part")
    XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
  }

  func testCumulativeCreditFlowControlWindow() async throws {
    let sender = MacTransferModel()
    let senderChannel = MockSecuredChannel(deviceName: "MacBook")
    sender.available(senderChannel)
    _ = await sender.handle(try TransferMessage.capability().encode(), on: senderChannel.descriptor)

    // Create 250,000 byte file (requires > 64 chunks of 3072 bytes)
    let totalSize: Int64 = 250_000
    let testData = Data((0..<Int(totalSize)).map { UInt8($0 % 241) })
    let testFileURL = tempDir.appendingPathComponent("large.bin")
    try testData.write(to: testFileURL)

    var sentChunkCount = 0
    var batchIdStr = ""
    var fileIdStr = ""

    senderChannel.onSendData = { data in
      guard let msg = try? TransferMessage.decode(data) else { return }
      if msg.kind == 2 {
        batchIdStr = msg.string(0)
        if case .array(let files) = msg.fields[5], let first = files.first, case .array(let row) = first {
          if case .text(let fid) = row[0] { fileIdStr = fid }
        }
      } else if msg.kind == 5 {
        sentChunkCount += 1
      }
    }

    await sender.sendFiles(urls: [testFileURL])
    XCTAssertFalse(batchIdStr.isEmpty)

    // Peer accepts
    let acceptMsg = TransferMessage.accept(batch: batchIdStr, files: [])
    _ = await sender.handle(try acceptMsg.encode(), on: senderChannel.descriptor)

    // Wait until sender pauses at 64 chunks (196,608 bytes)
    for _ in 0..<50 {
      if sentChunkCount >= 64 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(sentChunkCount, 64, "Sender should pause at exactly 64 chunks before receiving ack")

    _ = await sender.handle(try TransferMessage.ack(batch: UUID().uuidString.lowercased(), file: fileIdStr, written: Int64.max).encode(), on: senderChannel.descriptor)
    _ = await sender.handle(try TransferMessage.ack(batch: batchIdStr, file: fileIdStr, written: totalSize + 1).encode(), on: senderChannel.descriptor)
    _ = await sender.handle(try TransferMessage.batchResult(batch: batchIdStr, result: 0).encode(), on: senderChannel.descriptor)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(sentChunkCount, 64, "Wrong/future ACK cannot release credit")

    // Send ack for 64 chunks
    let ack = TransferMessage.ack(batch: batchIdStr, file: fileIdStr, written: 64 * 3072)
    _ = await sender.handle(try ack.encode(), on: senderChannel.descriptor)

    // Sender should resume and send the rest of the chunks
    for _ in 0..<50 {
      if sentChunkCount > 64 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertGreaterThan(sentChunkCount, 64, "Sender should have resumed sending after receiving ack")

    // Send file-result and batch-result to finish
    let fileRes = TransferMessage.fileResult(batch: batchIdStr, file: fileIdStr, result: 0, hash: Data(SHA256.hash(data: testData)))
    _ = await sender.handle(try fileRes.encode(), on: senderChannel.descriptor)
    let batchRes = TransferMessage.batchResult(batch: batchIdStr, result: 0)
    _ = await sender.handle(try batchRes.encode(), on: senderChannel.descriptor)

    for _ in 0..<50 {
      if case .completed = sender.state { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(sender.state, .completed(batchId: UUID(uuidString: batchIdStr)!, fileCount: 1, totalBytes: totalSize))
  }

  func testMultiWindowTransferWithBackpressure() async throws {
    let sender = MacTransferModel()
    let receiver = MacTransferModel()

    let senderChannel = MockSecuredChannel(deviceName: "MacBook")
    let receiverChannel = MockSecuredChannel(deviceName: "Phone")

    sender.available(senderChannel)

    _ = await sender.handle(try TransferMessage.capability().encode(), on: senderChannel.descriptor)
    receiver.available(receiverChannel)
    _ = await receiver.handle(try TransferMessage.capability().encode(), on: receiverChannel.descriptor)

    var senderAttempts = 0
    senderChannel.onSendData = { data in
      senderAttempts += 1
      if senderAttempts % 17 == 3 {
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 5_000_000)
          sender.capacityAvailable(senderChannel.descriptor)
        }
        throw SessionBackpressure()
      }
      _ = await receiver.handle(data, on: receiverChannel.descriptor)
    }

    var receiverAttempts = 0
    receiverChannel.onSendData = { data in
      receiverAttempts += 1
      if receiverAttempts % 5 == 2 {
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 5_000_000)
          receiver.capacityAvailable(receiverChannel.descriptor)
        }
        throw SessionBackpressure()
      }
      _ = await sender.handle(data, on: senderChannel.descriptor)
    }

    // 307,200 bytes = exactly 100 chunks of 3072 bytes (exceeds 64 chunk limit)
    let testData = Data((0..<307_200).map { UInt8($0 % 251) })
    let testFileURL = tempDir.appendingPathComponent("multiwindow.bin")
    try testData.write(to: testFileURL)

    await sender.sendFiles(urls: [testFileURL])

    guard case .incomingOffer(let batch) = receiver.state else {
      XCTFail("Expected incomingOffer on receiver, got \(receiver.state)")
      return
    }
    XCTAssertEqual(batch.totalBytes, 307_200)

    let destFolder = tempDir.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
    await receiver.acceptIncomingOffer(destination: destFolder)

    // Wait for transfer to complete across flow control windows
    var completed = false
    for _ in 0..<150 {
      if case .completed = receiver.state, case .completed = sender.state {
        completed = true
        break
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    XCTAssertTrue(completed, "Multi-window transfer did not complete in time; sender state: \(sender.state), receiver state: \(receiver.state)")

    let receivedFileURL = destFolder.appendingPathComponent("multiwindow.bin")
    XCTAssertTrue(FileManager.default.fileExists(atPath: receivedFileURL.path))
    let receivedData = try Data(contentsOf: receivedFileURL)
    XCTAssertEqual(receivedData, testData)
  }

  func testReceiverAccurateCumulativeProgressAcrossThrottleBoundaries() async throws {
    let receiver = MacTransferModel()
    let receiverChannel = MockSecuredChannel(deviceName: "Phone")
    receiver.available(receiverChannel)
    _ = await receiver.handle(try TransferMessage.capability().encode(), on: receiverChannel.descriptor)

    let batchId = UUID().uuidString.lowercased()
    let fileId = UUID().uuidString.lowercased()
    let chunkSize = 3072
    let chunkCount = 4
    let totalBytes = chunkSize * chunkCount
    let fileBytes = Data((0..<totalBytes).map { UInt8($0 % 251) })
    let fileHash = Data(SHA256.hash(data: fileBytes))

    let offer = TransferMessage.offer(
      batch: batchId,
      sliceIndex: 0,
      totalSlices: 1,
      totalFiles: 1,
      totalBytes: Int64(totalBytes),
      files: [
        SessionCBOR.array([
          .text(fileId),
          .text("rapid.bin"),
          .integer(Int64(totalBytes)),
          .bytes(fileHash)
        ])
      ]
    )
    _ = await receiver.handle(try offer.encode(), on: receiverChannel.descriptor)

    let destFolder = tempDir.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
    await receiver.acceptIncomingOffer(destination: destFolder)

    for i in 0..<chunkCount {
      let offset = i * chunkSize
      let chunkData = fileBytes.subdata(in: offset..<(offset + chunkSize))
      let chunkMsg = TransferMessage.chunk(
        batch: batchId,
        file: fileId,
        offset: Int64(offset),
        data: chunkData
      )
      _ = await receiver.handle(try chunkMsg.encode(), on: receiverChannel.descriptor)
    }

    if case .completed(_, let count, let bytes) = receiver.state {
      XCTAssertEqual(count, 1)
      XCTAssertEqual(bytes, Int64(totalBytes))
    } else if case .transferring(_, _, _, _, _, let bytes, let speed) = receiver.state {
      XCTAssertEqual(bytes, Int64(totalBytes))
      // A rate needs two observations separated in time. This burst completes inside one 100 ms UI
      // interval, so there is genuinely no rate to report, and reporting a lifetime average here is
      // exactly the drift the rolling window replaced.
      XCTAssertEqual(speed, 0)
    } else {
      XCTFail("Unexpected receiver state: \(receiver.state)")
    }

    let receivedFileURL = destFolder.appendingPathComponent("rapid.bin")
    XCTAssertTrue(FileManager.default.fileExists(atPath: receivedFileURL.path))
    XCTAssertEqual(try Data(contentsOf: receivedFileURL), fileBytes)
  }
}

final class TransferRateTests: XCTestCase {
  func testRecentSliceDecidesTheRateNotTheLifetimeAverage() {
    var rate = TransferRate(samples: 3)
    XCTAssertEqual(rate.add(0, at: 0), 0)
    XCTAssertEqual(rate.add(1048576, at: 0.1), 10485760, accuracy: 1)
    // The origin is still in the window, so this covers the whole 0.2 s observed so far.
    XCTAssertEqual(rate.add(1179648, at: 0.2), 5898240, accuracy: 1)
    // 1 MiB at t=0 has aged out: only 128 KiB across the window's 0.2 s remains, so the rate must
    // drop 16x. A lifetime average would still report 3932160 B/s here, which is the drift this
    // replaced.
    XCTAssertEqual(rate.add(1179648, at: 0.3), 655360, accuracy: 1)
    XCTAssertEqual(rate.add(1179648, at: 0.4), 0)
  }

  func testDefaultWindowKeepsBurstyConfirmationsButStillExpiresARealStall() {
    var rate = TransferRate()
    _ = rate.add(0, at: 0)
    for sample in 1...12 {
      XCTAssertEqual(rate.add(262144, at: Double(sample) * 0.25), 262144 / (Double(sample) * 0.25), accuracy: 0.001)
    }
    for sample in 13...20 { _ = rate.add(262144, at: Double(sample) * 0.25) }
    XCTAssertEqual(rate.add(262144, at: 5.25), 0)
  }

  func testAnIncompleteWindowMeasuresFromItsOldestSample() {
    var rate = TransferRate()
    XCTAssertEqual(rate.add(4096, at: 0), 0)
    // Two observations at one instant span no time and cannot yield a rate.
    XCTAssertEqual(rate.add(8192, at: 0), 0)
    XCTAssertEqual(rate.add(8192, at: 0), 0)
    // 4096 B arrived across the window's single elapsed second; the lifetime average is 8192 B/s.
    XCTAssertEqual(rate.add(8192, at: 1), 4096, accuracy: 0.001)
  }
}

final class TransferPublisherTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
  }

  private func name(_ suffix: Int) -> String { TransferPublisher.suffixed("sample.bin", suffix) }

  func testSuffixZeroIsTheNameItselfAndTheRestIsPlacedBeforeTheExtension() {
    XCTAssertEqual(TransferPublisher.suffixed("sample.bin", 0), "sample.bin")
    XCTAssertEqual(TransferPublisher.suffixed("sample.bin", 1), "sample (1).bin")
    XCTAssertEqual(TransferPublisher.suffixed("sample.bin", 12), "sample (12).bin")
    // Only the last dot separates an extension, so a compound suffix keeps its own dots.
    XCTAssertEqual(TransferPublisher.suffixed("archive.tar.gz", 4), "archive.tar (4).gz")
    XCTAssertEqual(TransferPublisher.suffixed("README", 3), "README (3)")
    // A leading dot names the file; it is not an extension separator.
    XCTAssertEqual(TransferPublisher.suffixed(".gitignore", 2), ".gitignore (2)")
  }

  func testATakenNameIsNeverOverwrittenAndPublicationStillSucceeds() throws {
    let folder = try makeFolder()
    let partial = try makePartial(in: folder)
    let taken = ["sample.bin", "sample (1).bin"]
    for takenName in taken { try Data([9, 9, 9]).write(to: folder.appendingPathComponent(takenName)) }

    try TransferPublisher.publish(partial, as: "sample.bin", in: folder)

    for takenName in taken {
      XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(takenName)), Data([9, 9, 9]))
    }
    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name(2))), payload)
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                   [name(2), "sample (1).bin", "sample.bin"].sorted())
  }

  func testAVolumeWithoutHardLinksPublishesByCopying() throws {
    let folder = try makeFolder()
    let partial = try makePartial(in: folder)
    try Data([9, 9, 9]).write(to: folder.appendingPathComponent("sample.bin"))

    try TransferPublisher.publish(partial, as: "sample.bin", in: folder) { _, _ in
      errno = ENOTSUP
      return -1
    }

    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("sample.bin")), Data([9, 9, 9]))
    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name(1))), payload)
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path),
                   "The staging partial must not survive publication")
  }

  func testARealFailureKeepsItsPosixReasonInsteadOfAnUnknownSaveError() throws {
    let folder = try makeFolder()
    let partial = try makePartial(in: folder)

    XCTAssertThrowsError(try TransferPublisher.publish(partial, as: "sample.bin", in: folder) { _, _ in
      errno = EACCES
      return -1
    }) { error in
      let failure = error as NSError
      XCTAssertEqual(failure.domain, NSPOSIXErrorDomain)
      XCTAssertEqual(failure.code, Int(EACCES))
      XCTAssertTrue(failure.localizedDescription.contains(String(cString: strerror(EACCES))))
      XCTAssertTrue(failure.localizedDescription.contains("sample.bin"))
    }
    // The verified partial survives a failed publication for recovery.
    XCTAssertEqual(try Data(contentsOf: partial), payload)
  }

  func testAFailureInsideTheCopyFallbackIsNotSwallowedAndLeavesNoTarget() throws {
    let folder = try makeFolder()
    let partial = try makePartial(in: folder)

    XCTAssertThrowsError(try TransferPublisher.publish(partial, as: "sample.bin", in: folder) { _, _ in
      // The link is refused and the staging partial vanishes before the copy can read it.
      try? FileManager.default.removeItem(at: partial)
      errno = ENOTSUP
      return -1
    })
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
  }

  /// A symlink occupying the destination name is a taken name, not a failed publication. It is
  /// reported as EEXIST or, under `O_NOFOLLOW`, as ELOOP; treating either as fatal would discard a
  /// completed, already verified transfer on exactly the volumes that take the copy path.
  func testASymlinkAtTheDestinationIsATakenNameRatherThanAFailedPublication() throws {
    let folder = try makeFolder()
    let partial = try makePartial(in: folder)
    let link = folder.appendingPathComponent("sample.bin")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "nowhere"))

    try TransferPublisher.publish(partial, as: "sample.bin", in: folder) { _, _ in
      errno = ENOTSUP
      return -1
    }

    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name(1))), payload)
    XCTAssertEqual(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                   [name(1), "sample.bin"].sorted())
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path),
                   "The staging partial must not survive publication")
  }

  private let payload = Data((0..<4096).map { UInt8($0 % 251) })

  private func makeFolder() throws -> URL {
    let folder = tempDir.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func makePartial(in folder: URL) throws -> URL {
    let partial = folder.appendingPathComponent(".anice-\(UUID().uuidString).part")
    try payload.write(to: partial)
    return partial
  }
}

