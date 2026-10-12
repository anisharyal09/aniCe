// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies transfer engine lifecycle, cumulative flow control and adversarial chunk handling.
import XCTest
import CryptoKit
@testable import aniCe

@MainActor
final class MockSecuredChannel: SecuredChannel {
  let descriptor: ChannelDescriptor
  var sentData: [Data] = []
  var onSendData: ((Data) async throws -> Void)?

  init(instance: String = "test-token", transport: String = "lan", deviceName: String = "Pixel 9") {
    let key = P256.Signing.PrivateKey()
    let peer = try! DeviceIdentity(deviceId: UUID().uuidString.lowercased(), deviceName: deviceName, publicKey: key.publicKey.x963Representation)
    self.descriptor = ChannelDescriptor(instance: instance, transport: transport, peer: peer)
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

  func testOfferAcceptStreamAndVerifyBatch() async throws {
    let sender = MacTransferModel()
    let receiver = MacTransferModel()

    let senderChannel = MockSecuredChannel(deviceName: "MacBook")
    let receiverChannel = MockSecuredChannel(deviceName: "Phone")

    sender.available(senderChannel)
    receiver.available(receiverChannel)

    // Route messages between sender and receiver
    senderChannel.onSendData = { data in
      _ = receiver.handle(data, on: receiverChannel.descriptor)
    }
    receiverChannel.onSendData = { data in
      _ = sender.handle(data, on: senderChannel.descriptor)
    }

    // Create a 10 KiB test file
    let testData = Data((0..<10240).map { UInt8($0 % 251) })
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
    XCTAssertEqual(batch.files[0].size, 10240)

    // Accept offer on receiver
    let destFolder = tempDir.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)

    await receiver.acceptIncomingOffer(destination: destFolder)

    // Wait briefly for transfer task to stream and complete
    var completed = false
    for _ in 0..<50 {
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
    _ = receiver.handle(try offer.encode(), on: receiverChannel.descriptor)

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
    _ = receiver.handle(try corruptedChunk.encode(), on: receiverChannel.descriptor)

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
    _ = receiver.handle(try offer.encode(), on: receiverChannel.descriptor)

    XCTAssertTrue(receiver.state != .idle)
    await receiver.rejectIncomingOffer(reason: 0)
    XCTAssertEqual(receiver.state, .idle)
  }

  func testLocalCancellationCleansUp() async throws {
    let receiver = MacTransferModel()
    let receiverChannel = MockSecuredChannel(deviceName: "Phone")
    receiver.available(receiverChannel)

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
    _ = receiver.handle(try offer.encode(), on: receiverChannel.descriptor)

    let destFolder = tempDir.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
    await receiver.acceptIncomingOffer(destination: destFolder)

    // Send partial chunk
    let chunk = TransferMessage.chunk(batch: batchId, file: fileId, offset: 0, data: Data([1, 2, 3]))
    _ = receiver.handle(try chunk.encode(), on: receiverChannel.descriptor)

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
    _ = sender.handle(try acceptMsg.encode(), on: senderChannel.descriptor)

    // Wait until sender pauses at 64 chunks (196,608 bytes)
    for _ in 0..<50 {
      if sentChunkCount >= 64 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(sentChunkCount, 64, "Sender should pause at exactly 64 chunks before receiving ack")

    // Send ack for 64 chunks
    let ack = TransferMessage.ack(batch: batchIdStr, file: fileIdStr, written: 64 * 3072)
    _ = sender.handle(try ack.encode(), on: senderChannel.descriptor)

    // Sender should resume and send the rest of the chunks
    for _ in 0..<50 {
      if sentChunkCount > 64 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertGreaterThan(sentChunkCount, 64, "Sender should have resumed sending after receiving ack")

    // Send file-result and batch-result to finish
    let fileRes = TransferMessage.fileResult(batch: batchIdStr, file: fileIdStr, result: 0, hash: Data(SHA256.hash(data: testData)))
    _ = sender.handle(try fileRes.encode(), on: senderChannel.descriptor)
    let batchRes = TransferMessage.batchResult(batch: batchIdStr, result: 0)
    _ = sender.handle(try batchRes.encode(), on: senderChannel.descriptor)

    XCTAssertEqual(sender.state, .completed(batchId: UUID(uuidString: batchIdStr)!, fileCount: 1, totalBytes: totalSize))
  }

  func testMultiWindowTransferWithBackpressure() async throws {
    let sender = MacTransferModel()
    let receiver = MacTransferModel()

    let senderChannel = MockSecuredChannel(deviceName: "MacBook")
    let receiverChannel = MockSecuredChannel(deviceName: "Phone")

    sender.available(senderChannel)
    receiver.available(receiverChannel)

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
      _ = receiver.handle(data, on: receiverChannel.descriptor)
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
      _ = sender.handle(data, on: senderChannel.descriptor)
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
}

