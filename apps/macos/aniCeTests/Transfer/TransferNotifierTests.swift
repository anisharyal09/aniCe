// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies native notification formatting, action dispatch, event sink emissions and multi-device ordering.
import XCTest
import CryptoKit
import UserNotifications
@testable import aniCe

@MainActor
final class TransferNotifierTests: XCTestCase {
  private var tempDir: URL!

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

  func testNotificationContentFormatting() {
    let batchId = UUID()
    let batch = TransferBatch(
      id: batchId,
      files: [
        TransferFile(id: UUID(), name: "photo1.jpg", size: 10_485_760, sha256: Data(repeating: 1, count: 32), localURL: nil),
        TransferFile(id: UUID(), name: "photo2.jpg", size: 5_242_880, sha256: Data(repeating: 2, count: 32), localURL: nil)
      ],
      totalBytes: 15_728_640,
      peerName: "Pixel 9"
    )

    let offerContent = TransferNotificationContent.offer(batch: batch)
    XCTAssertEqual(offerContent.title, "Incoming files from Pixel 9")
    XCTAssertTrue(offerContent.body.contains("2 files"))
    XCTAssertEqual(offerContent.categoryIdentifier, MacTransferNotifier.Category.offer)
    XCTAssertEqual(offerContent.userInfo["batchId"], batch.idString)
    XCTAssertFalse(offerContent.body.contains("photo1.jpg"), "Offer body must not contain unvalidated peer file names")

    let downloadFolder = tempDir.appendingPathComponent("Downloads")
    let completedContent = TransferNotificationContent.completed(fileCount: 2, totalBytes: batch.totalBytes, folder: downloadFolder)
    XCTAssertEqual(completedContent.title, "Transfer complete")
    XCTAssertTrue(completedContent.body.contains("2 files"))
    XCTAssertTrue(completedContent.body.contains("saved to Downloads."))
    XCTAssertEqual(completedContent.categoryIdentifier, MacTransferNotifier.Category.result)

    let failedContent = TransferNotificationContent.failed(reason: "Hash mismatch")
    XCTAssertEqual(failedContent.title, "Transfer failed")
    XCTAssertEqual(failedContent.body, "Hash mismatch")
    XCTAssertEqual(failedContent.categoryIdentifier, MacTransferNotifier.Category.result)

    let staleContent = TransferNotificationContent.staleOfferNotice()
    XCTAssertEqual(staleContent.title, "Transfer unavailable")
    XCTAssertEqual(staleContent.body, "The offer is no longer available.")
  }

  func testEventSinkFiresIncomingOfferCompletedAndFailedOnlyWhenReceiving() async throws {
    let model = MacTransferModel()
    let channel = MockSecuredChannel(instance: "test-channel")
    model.available(channel)
    _ = await model.handle(try TransferMessage.capability().encode(), on: channel.descriptor)

    var events: [TransferEvent] = []
    model.onEvent = { events.append($0) }

    let batchId = UUID().uuidString.lowercased()
    let fileId = UUID().uuidString.lowercased()
    let payload = Data([10, 20, 30, 40, 50])
    let hash = Data(SHA256.hash(data: payload))

    let offerMsg = TransferMessage.offer(
      batch: batchId,
      sliceIndex: 0,
      totalSlices: 1,
      totalFiles: 1,
      totalBytes: Int64(payload.count),
      files: [
        SessionCBOR.array([
          .text(fileId),
          .text("test.bin"),
          .integer(Int64(payload.count)),
          .bytes(hash)
        ])
      ]
    )
    _ = await model.handle(try offerMsg.encode(), on: channel.descriptor)

    XCTAssertEqual(events.count, 1)
    if case .incomingOffer(let batch) = events.first {
      XCTAssertEqual(batch.idString, batchId)
      XCTAssertEqual(batch.totalBytes, Int64(payload.count))
    } else {
      XCTFail("Expected incomingOffer event")
    }

    XCTAssertNotNil(model.pendingOffer)
    XCTAssertEqual(model.pendingOffer?.idString, batchId)

    // Accept offer and stream the file
    let dest = tempDir.appendingPathComponent("Received")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    await model.acceptIncomingOffer(destination: dest)

    XCTAssertNil(model.pendingOffer, "pendingOffer must be nil after acceptance")
    XCTAssertEqual(model.receiveFolder, dest)

    let chunkMsg = TransferMessage.chunk(batch: batchId, file: fileId, offset: 0, data: payload)
    _ = await model.handle(try chunkMsg.encode(), on: channel.descriptor)

    // Wait for async finalization
    for _ in 0..<50 {
      if case .completed = model.state { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    guard case .completed = model.state else {
      XCTFail("Model should reach completed state")
      return
    }

    XCTAssertEqual(events.count, 2)
    if case .completed(let count, let bytes) = events[1] {
      XCTAssertEqual(count, 1)
      XCTAssertEqual(bytes, Int64(payload.count))
    } else {
      XCTFail("Expected completed event for receiver")
    }

    // Published URLs survived cleanup
    XCTAssertEqual(model.publishedURLs.count, 1)
    XCTAssertEqual(model.publishedURLs.first?.lastPathComponent, "test.bin")
    XCTAssertEqual(model.receiveFolder, dest)

    // Dismiss clears published URLs and receive folder
    model.dismiss()
    XCTAssertTrue(model.publishedURLs.isEmpty)
    XCTAssertNil(model.receiveFolder)
  }

  func testStaleActionGuardDoesNotAcceptWhenPendingOfferIsNil() async {
    let model = MacTransferModel()
    var windowOpened = false
    let notifier = MacTransferNotifier(
      model: model,
      openMainWindow: { windowOpened = true }
    )

    XCTAssertNil(model.pendingOffer)
    notifier.handleAction(MacTransferNotifier.Action.accept)
    notifier.handleAction(MacTransferNotifier.Action.decline)

    // Neither accept nor decline changed model state
    XCTAssertEqual(model.state, .idle)

    notifier.handleAction(MacTransferNotifier.Action.choose)
    XCTAssertTrue(windowOpened)
  }

  func testPausedContentAndActionsFollowContinuationAvailability() throws {
    let batch = makeBatch(count: 2)
    let waitingContent = TransferNotificationContent.paused(
      batch: batch, reason: "Local network connection lost", canResumeOverBle: false)
    XCTAssertEqual(waitingContent.identifier, "transfer-paused-\(batch.idString)")
    XCTAssertEqual(waitingContent.categoryIdentifier, MacTransferNotifier.Category.paused)
    XCTAssertEqual(waitingContent.title, "Transfer paused")
    XCTAssertTrue(waitingContent.body.contains("Pixel 9"))
    XCTAssertTrue(waitingContent.body.contains("2 files"))
    XCTAssertTrue(waitingContent.body.contains("Local network connection lost"))
    XCTAssertEqual(waitingContent.userInfo["batchId"], batch.idString)

    let continuableContent = TransferNotificationContent.paused(
      batch: batch, reason: "Local network connection lost", canResumeOverBle: true)
    XCTAssertEqual(continuableContent.categoryIdentifier, MacTransferNotifier.Category.pausedSender)

    let categories = MacTransferNotifier.notificationCategories()
    let paused = try XCTUnwrap(categories.first { $0.identifier == MacTransferNotifier.Category.paused })
    XCTAssertEqual(paused.actions.map(\.identifier), [MacTransferNotifier.Action.cancelTransfer])
    let pausedSender = try XCTUnwrap(categories.first { $0.identifier == MacTransferNotifier.Category.pausedSender })
    XCTAssertEqual(pausedSender.actions.map(\.identifier),
      [MacTransferNotifier.Action.continueOverBluetooth, MacTransferNotifier.Action.cancelTransfer])
    XCTAssertTrue(try XCTUnwrap(pausedSender.actions.last).options.contains(.destructive))
  }

  func testPauseAndTerminalTransitionsNeverPostAlertsEvenWhenOffersAreEnabled() {
    let model = MacTransferModel()
    XCTAssertFalse(model.notificationPreferences.enabled)
    model.notificationPreferences.enabled = true
    let center = SpyNotificationCenter()
    let notifier = MacTransferNotifier(model: model, openMainWindow: {}, center: center)
    let batch = makeBatch(count: 1)
    for _ in 0..<20 {
      notifier.handle(.paused(batch: batch, reason: "Local network connection lost", canResumeOverBle: true))
      notifier.handle(.resumed)
    }
    notifier.handle(.completed(fileCount: 1, totalBytes: 10))
    notifier.handle(.failed(reason: "Connection lost"))
    XCTAssertFalse(center.requestedAuthorization)
    XCTAssertTrue(center.added.isEmpty)
    XCTAssertEqual(model.state, .idle)
  }

  func testPausedActionsAreIgnoredUnlessTheBatchIsStillPaused() {
    let model = MacTransferModel()
    let center = SpyNotificationCenter()
    let notifier = MacTransferNotifier(model: model, openMainWindow: {}, center: center)

    notifier.handleAction(MacTransferNotifier.Action.continueOverBluetooth)
    notifier.handleAction(MacTransferNotifier.Action.cancelTransfer)

    XCTAssertEqual(model.state, .idle)
    XCTAssertTrue(center.removedDelivered.isEmpty)
  }

  private func makeBatch(count: Int) -> TransferBatch {
    TransferBatch(
      id: UUID(),
      files: (0..<count).map { index in
        TransferFile(id: UUID(), name: "file\(index).bin", size: 1024,
          sha256: Data(repeating: UInt8(index), count: 32), localURL: nil)
      },
      totalBytes: Int64(count) * 1024,
      peerName: "Pixel 9"
    )
  }

  func testPrimaryPeerSelectionUsesConnectedPartitionAndPreservesOrder() {
    let idA = UUID().uuidString.lowercased()
    let idB = UUID().uuidString.lowercased()
    let idC = UUID().uuidString.lowercased()
    let keyA = P256.Signing.PrivateKey()
    let keyB = P256.Signing.PrivateKey()
    let keyC = P256.Signing.PrivateKey()
    let peerA = try! DeviceIdentity(deviceId: idA, deviceName: "Phone A", publicKey: keyA.publicKey.x963Representation)
    let peerB = try! DeviceIdentity(deviceId: idB, deviceName: "Phone B", publicKey: keyB.publicKey.x963Representation)
    let peerC = try! DeviceIdentity(deviceId: idC, deviceName: "Phone C", publicKey: keyC.publicKey.x963Representation)

    let recordA = PeerTrustRecord(peer: peerA, localFingerprint: "fp-a", method: .qr, pairedAt: Date(), transcriptHash: Data(), receipt: nil, active: true)
    let recordB = PeerTrustRecord(peer: peerB, localFingerprint: "fp-b", method: .qr, pairedAt: Date(), transcriptHash: Data(), receipt: nil, active: true)
    let recordC = PeerTrustRecord(peer: peerC, localFingerprint: "fp-c", method: .qr, pairedAt: Date(), transcriptHash: Data(), receipt: nil, active: true)

    let peers: [PeerTrustRecord] = [recordA, recordB, recordC]

    // Exercise the presentation path used by Devices and the companion instead of reimplementing
    // its partition locally.
    func displayed(_ connected: Set<String>) -> [String] {
      ConnectionPresentation.primaryPeers(peers) { connected.contains($0.peer.deviceId) }
        .map { $0.peer.deviceId }
    }

    XCTAssertEqual(displayed([idB]), [idB], "Only connected peers should appear while any peer is connected")
    XCTAssertEqual(displayed([idA, idC]), [idA, idC], "Connected peers must retain their stored order")
    XCTAssertEqual(displayed([idA, idB, idC]), [idA, idB, idC])
    XCTAssertEqual(displayed([]), [idA, idB, idC], "With no connection, all paired devices remain available")
  }
}

private final class SpyNotificationCenter: TransferNotificationCenter, @unchecked Sendable {
  var requestedAuthorization = false
  var added: [UNNotificationRequest] = []
  var removedDelivered: [String] = []
  var removedPending: [String] = []

  func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, Error?) -> Void) {
    requestedAuthorization = true
    completionHandler(true, nil)
  }

  func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
    added.append(request)
    completionHandler?(nil)
  }

  func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
    removedDelivered.append(contentsOf: identifiers)
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
    removedPending.append(contentsOf: identifiers)
  }
}
