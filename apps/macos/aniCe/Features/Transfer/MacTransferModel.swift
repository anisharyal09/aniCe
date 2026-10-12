// SPDX-License-Identifier: GPL-3.0-or-later
// Coordinates bidirectional file transfer batches, cumulative flow control and sleep assertions over authenticated LAN.
import Foundation
import Observation
import CryptoKit
import IOKit.pwr_mgt

struct TransferFile: Identifiable, Equatable, Hashable, Sendable {
  let id: UUID
  let name: String
  let size: Int64
  let sha256: Data
  let localURL: URL?

  var idString: String { id.uuidString.lowercased() }
}

struct TransferBatch: Identifiable, Equatable, Sendable {
  let id: UUID
  let files: [TransferFile]
  let totalBytes: Int64
  let peerName: String

  var idString: String { id.uuidString.lowercased() }
}

enum TransferState: Equatable {
  case idle
  case waitingForPeerApproval(batch: TransferBatch)
  case incomingOffer(batch: TransferBatch)
  case transferring(batch: TransferBatch, fileIndex: Int, fileName: String, fileBytes: Int64, fileSize: Int64, totalBytes: Int64, speedBps: Double)
  case completed(batchId: UUID, fileCount: Int, totalBytes: Int64)
  case rejected(batchId: UUID, reason: Int64)
  case failed(reason: String)
  case cancelled
}

@Observable @MainActor final class MacTransferModel: FeatureHandler {
  private(set) var state: TransferState = .idle
  private(set) var activeChannel: (any SecuredChannel)?
  private(set) var peerConnected = false

  @ObservationIgnored nonisolated(unsafe) private var sleepAssertionID: IOPMAssertionID = 0
  @ObservationIgnored nonisolated(unsafe) private var hasSleepAssertion = false

  private var peerMaxChunkBytes: Int64 = 3072
  private var peerMaxWindow: Int64 = 64

  private var currentBatch: TransferBatch?
  private var transferTask: Task<Void, Never>?

  // Sender flow-control & backpressure
  private var sentBytes: Int64 = 0
  private var acknowledgedBytes: Int64 = 0
  private var creditResume: (() -> Void)?
  private var capacityWaiters: [() -> Void] = []
  private var fileResultContinuation: CheckedContinuation<TransferMessage, Never>?

  // Receiver state
  private var bufferedOfferSlices: [String: [Int64: [TransferFile]]] = [:]
  private var expectedSlices: [String: Int64] = [:]
  private var totalBatchFiles: [String: Int64] = [:]
  private var totalBatchBytes: [String: Int64] = [:]
  private var destinationFolder: URL?
  private var receiverCurrentFileIndex = 0
  private var receiverPartFileURL: URL?
  private var receiverPartFileHandle: FileHandle?
  private var receiverHasher = SHA256()
  private var receiverWrittenBytes: Int64 = 0
  private var lastAckedWrittenBytes: Int64 = 0
  private var unackedChunksCount = 0
  private var ackTask: Task<Void, Never>?
  private var ackTimerTask: Task<Void, Never>?
  private var receiverStartTime: TimeInterval = 0
  private var lastReceiverUiUpdate: TimeInterval = 0

  deinit {
    if hasSleepAssertion {
      IOPMAssertionRelease(sleepAssertionID)
    }
  }

  // MARK: - FeatureHandler conformance

  func available(_ channel: any SecuredChannel) {
    guard channel.descriptor.transport == "lan" else { return }
    activeChannel = channel
    peerConnected = true
    Task {
      let cap = TransferMessage.capability()
      if let data = try? cap.encode() {
        try? await self.sendWithBackpressure(data)
      }
    }
  }

  func retired(_ descriptor: ChannelDescriptor) {
    guard descriptor.transport == "lan" else { return }
    activeChannel = nil
    peerConnected = false
    creditResume?()
    creditResume = nil
    clearCapacityWaiters()
    ackTask?.cancel()
    ackTask = nil
    ackTimerTask?.cancel()
    ackTimerTask = nil
    if case .transferring = state {
      failTransfer(reason: "LAN connection closed during transfer")
    } else if case .waitingForPeerApproval = state {
      state = .failed(reason: "LAN connection closed while waiting for peer approval")
      releaseSleepAssertion()
    }
  }

  private func clearCapacityWaiters() {
    let waiters = capacityWaiters
    capacityWaiters.removeAll()
    for waiter in waiters {
      waiter()
    }
  }

  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    guard descriptor.transport == "lan" else { return }
    clearCapacityWaiters()
    checkCreditAndResume()
    flushAck()
  }

  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) -> DataHandling {
    guard descriptor.transport == "lan" else { return .unrecognized }
    guard let message = try? TransferMessage.decode(bytes) else { return .unrecognized }
    processMessage(message, peerName: descriptor.peer.deviceName)
    return .handled
  }

  // MARK: - Message Processing

  private func processMessage(_ message: TransferMessage, peerName: String) {
    switch message.kind {
    case 1: // capability
      peerMaxChunkBytes = min(message.number(1), 3072)
      peerMaxWindow = min(message.number(2), 64)

    case 2: // offer
      handleOffer(message, peerName: peerName)

    case 3: // accept
      handleAccept(message)

    case 4: // reject
      handleReject(message)

    case 5: // chunk
      handleChunk(message)

    case 6: // ack
      handleAck(message)

    case 7: // file-result
      fileResultContinuation?.resume(returning: message)
      fileResultContinuation = nil

    case 8: // batch-result
      if case .transferring(let batch, _, _, _, _, _, _) = state {
        state = .completed(batchId: batch.id, fileCount: batch.files.count, totalBytes: batch.totalBytes)
        cleanupActiveTransfer()
      }

    case 9: // cancel
      cancelTransfer(local: false)

    default:
      break
    }
  }

  // MARK: - Sender Flow

  private func sendWithBackpressure(_ data: Data) async throws {
    guard let channel = activeChannel else { throw SessionFailure.cancelled }
    while !Task.isCancelled && activeChannel != nil {
      do {
        try await channel.sendData(data)
        return
      } catch is SessionBackpressure {
        await withCheckedContinuation { cont in
          var resumed = false
          let resumeOnce = {
            if !resumed {
              resumed = true
              cont.resume()
            }
          }
          self.capacityWaiters.append(resumeOnce)
          Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000)
            await MainActor.run {
              guard self != nil else { return }
              resumeOnce()
            }
          }
        }
      }
    }
    if Task.isCancelled || activeChannel == nil {
      throw SessionFailure.cancelled
    }
  }

  func sendFiles(urls: [URL]) async {
    guard let channel = activeChannel, peerConnected else {
      state = .failed(reason: "No active LAN session")
      return
    }
    guard (1...128).contains(urls.count) else {
      state = .failed(reason: "Transfer batch must contain 1 to 128 files")
      return
    }

    var files: [TransferFile] = []
    var totalBytes: Int64 = 0

    for url in urls {
      let name = url.lastPathComponent
      guard (1...255).contains(name.utf8.count),
            !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
            name != ".", name != ".." else {
        state = .failed(reason: "Invalid filename: \(name)")
        return
      }
      guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attr[.size] as? Int64,
            let handle = try? FileHandle(forReadingFrom: url) else {
        state = .failed(reason: "Cannot read file: \(name)")
        return
      }
      var hasher = SHA256()
      while autoreleasepool(invoking: {
        let chunk = handle.readData(ofLength: 64 * 1024)
        if chunk.isEmpty { return false }
        hasher.update(data: chunk)
        return true
      }) {}
      try? handle.close()
      let digest = Data(hasher.finalize())
      let file = TransferFile(id: UUID(), name: name, size: size, sha256: digest, localURL: url)
      files.append(file)
      totalBytes += size
    }

    let batchId = UUID()
    let batch = TransferBatch(id: batchId, files: files, totalBytes: totalBytes, peerName: channel.descriptor.peer.deviceName)
    currentBatch = batch
    state = .waitingForPeerApproval(batch: batch)
    acquireSleepAssertion()

    // Send offer slices
    let totalFiles = Int64(files.count)
    let totalSlices = Int64((files.count + 7) / 8)
    for sliceIdx in 0..<Int(totalSlices) {
      let start = sliceIdx * 8
      let end = min(start + 8, files.count)
      let sliceFiles = files[start..<end].map { f in
        SessionCBOR.array([
          .text(f.idString),
          .text(f.name),
          .integer(f.size),
          .bytes(f.sha256)
        ])
      }
      let offer = TransferMessage.offer(
        batch: batch.idString,
        sliceIndex: Int64(sliceIdx),
        totalSlices: totalSlices,
        totalFiles: totalFiles,
        totalBytes: totalBytes,
        files: sliceFiles
      )
      if let encoded = try? offer.encode() {
        do {
          try await sendWithBackpressure(encoded)
        } catch {
          failTransfer(reason: "Failed sending offer: \(error.localizedDescription)")
          return
        }
      }
    }
  }

  private func handleAccept(_ message: TransferMessage) {
    guard case .waitingForPeerApproval(let batch) = state,
          message.string(0) == batch.idString else { return }

    // Start streaming files
    transferTask = Task {
      await streamAcceptedBatch(batch)
    }
  }

  private func streamAcceptedBatch(_ batch: TransferBatch) async {
    guard activeChannel != nil else { return }
    var totalTransferred: Int64 = 0
    let startTime = ProcessInfo.processInfo.systemUptime
    var lastUiUpdate: TimeInterval = 0

    for (fileIndex, file) in batch.files.enumerated() {
      guard let url = file.localURL,
            let handle = try? FileHandle(forReadingFrom: url) else {
        failTransfer(reason: "Failed reading local file \(file.name)")
        return
      }

      sentBytes = 0
      acknowledgedBytes = 0
      var fileBytesSent: Int64 = 0

      while fileBytesSent < file.size {
        // Enforce credit flow control: at most maxWindow unacknowledged chunks
        let inFlight = sentBytes - acknowledgedBytes
        if inFlight >= peerMaxWindow * peerMaxChunkBytes {
          await withCheckedContinuation { cont in
            if self.sentBytes - self.acknowledgedBytes < self.peerMaxWindow * self.peerMaxChunkBytes {
              cont.resume()
            } else {
              self.creditResume = { cont.resume() }
            }
          }
        }
        guard !Task.isCancelled, self.activeChannel != nil else {
          try? handle.close()
          return
        }

        let chunkSize = min(Int(peerMaxChunkBytes), Int(file.size - fileBytesSent))
        let chunkData = handle.readData(ofLength: chunkSize)
        guard chunkData.count == chunkSize else {
          try? handle.close()
          failTransfer(reason: "I/O error reading \(file.name)")
          return
        }

        let chunkMsg = TransferMessage.chunk(
          batch: batch.idString,
          file: file.idString,
          offset: fileBytesSent,
          data: chunkData
        )
        guard let encoded = try? chunkMsg.encode() else {
          try? handle.close()
          failTransfer(reason: "Failed encoding chunk")
          return
        }

        do {
          try await sendWithBackpressure(encoded)
          fileBytesSent += Int64(chunkData.count)
          sentBytes += Int64(chunkData.count)
          totalTransferred += Int64(chunkData.count)

          let now = ProcessInfo.processInfo.systemUptime
          if now - lastUiUpdate >= 0.1 || fileBytesSent == file.size {
            lastUiUpdate = now
            let elapsed = max(0.001, now - startTime)
            let speed = Double(totalTransferred) / elapsed

            self.state = .transferring(
              batch: batch,
              fileIndex: fileIndex + 1,
              fileName: file.name,
              fileBytes: fileBytesSent,
              fileSize: file.size,
              totalBytes: totalTransferred,
              speedBps: speed
            )
          }
        } catch {
          try? handle.close()
          failTransfer(reason: "Failed sending chunk: \(error.localizedDescription)")
          return
        }
      }

      try? handle.close()

      // Wait for file-result from receiver
      let fileResult = await withCheckedContinuation { cont in
        self.fileResultContinuation = cont
      }
      if fileResult.number(2) != 0 {
        failTransfer(reason: "Receiver reported error for file \(file.name)")
        return
      }
    }

    // All files completed
    let batchResult = TransferMessage.batchResult(batch: batch.idString, result: 0)
    if let encoded = try? batchResult.encode() {
      try? await sendWithBackpressure(encoded)
    }
    state = .completed(batchId: batch.id, fileCount: batch.files.count, totalBytes: batch.totalBytes)
    cleanupActiveTransfer()
  }

  private func handleAck(_ message: TransferMessage) {
    let written = message.number(2)
    acknowledgedBytes = written
    checkCreditAndResume()
  }

  private func checkCreditAndResume() {
    let inFlight = sentBytes - acknowledgedBytes
    if inFlight < peerMaxWindow * peerMaxChunkBytes {
      creditResume?()
      creditResume = nil
    }
  }

  private func handleReject(_ message: TransferMessage) {
    guard case .waitingForPeerApproval(let batch) = state,
          message.string(0) == batch.idString else { return }
    state = .rejected(batchId: batch.id, reason: message.number(1))
    cleanupActiveTransfer()
  }

  // MARK: - Receiver Flow

  private func handleOffer(_ message: TransferMessage, peerName: String) {
    let batchIdStr = message.string(0)
    guard let batchUUID = UUID(uuidString: batchIdStr) else { return }
    let sliceIdx = message.number(1)
    let totalSlices = message.number(2)
    let totalFiles = message.number(3)
    let totalBytes = message.number(4)

    guard case .array(let filesCbor) = message.fields[5] else { return }
    var sliceFiles: [TransferFile] = []
    for f in filesCbor {
      guard case .array(let row) = f, row.count == 4,
            case .text(let idStr) = row[0], let id = UUID(uuidString: idStr),
            case .text(let name) = row[1],
            case .integer(let sz) = row[2],
            case .bytes(let hash) = row[3] else { continue }
      sliceFiles.append(TransferFile(id: id, name: name, size: sz, sha256: hash, localURL: nil))
    }

    if bufferedOfferSlices[batchIdStr] == nil {
      bufferedOfferSlices[batchIdStr] = [:]
      expectedSlices[batchIdStr] = totalSlices
      totalBatchFiles[batchIdStr] = totalFiles
      totalBatchBytes[batchIdStr] = totalBytes
    }
    bufferedOfferSlices[batchIdStr]?[sliceIdx] = sliceFiles

    // Check if all slices received
    if let slices = bufferedOfferSlices[batchIdStr], Int64(slices.count) == totalSlices {
      var allFiles: [TransferFile] = []
      for i in 0..<totalSlices {
        allFiles.append(contentsOf: slices[i] ?? [])
      }

      let batch = TransferBatch(id: batchUUID, files: allFiles, totalBytes: totalBytes, peerName: peerName)
      bufferedOfferSlices.removeValue(forKey: batchIdStr)
      expectedSlices.removeValue(forKey: batchIdStr)
      totalBatchFiles.removeValue(forKey: batchIdStr)
      totalBatchBytes.removeValue(forKey: batchIdStr)

      let isBusy: Bool
      switch state {
      case .waitingForPeerApproval, .incomingOffer, .transferring:
        isBusy = true
      default:
        isBusy = false
      }

      if isBusy {
        // Busy with another active transfer
        Task {
          let reject = TransferMessage.reject(batch: batchIdStr, reason: 3)
          if let encoded = try? reject.encode() {
            try? await activeChannel?.sendData(encoded)
          }
        }
        return
      }

      cleanupActiveTransfer()
      currentBatch = batch
      state = .incomingOffer(batch: batch)
      acquireSleepAssertion()
    }
  }

  func acceptIncomingOffer(destination: URL) async {
    guard case .incomingOffer(let batch) = state, let channel = activeChannel else { return }
    destinationFolder = destination
    receiverCurrentFileIndex = 0
    receiverWrittenBytes = 0
    lastAckedWrittenBytes = 0
    unackedChunksCount = 0
    receiverStartTime = ProcessInfo.processInfo.systemUptime
    lastReceiverUiUpdate = 0

    // Prepare for first file
    prepareReceiverForFile(at: 0, in: batch)
    state = .transferring(
      batch: batch,
      fileIndex: 1,
      fileName: batch.files[0].name,
      fileBytes: 0,
      fileSize: batch.files[0].size,
      totalBytes: 0,
      speedBps: 0
    )

    let accept = TransferMessage.accept(batch: batch.idString, files: [])
    if let encoded = try? accept.encode() {
      try? await sendWithBackpressure(encoded)
    }
  }

  func rejectIncomingOffer(reason: Int64 = 0) async {
    guard case .incomingOffer(let batch) = state, let channel = activeChannel else { return }
    let reject = TransferMessage.reject(batch: batch.idString, reason: reason)
    if let encoded = try? reject.encode() {
      try? await sendWithBackpressure(encoded)
    }
    state = .idle
    cleanupActiveTransfer()
  }

  private func prepareReceiverForFile(at index: Int, in batch: TransferBatch) {
    guard batch.files.indices.contains(index), let dest = destinationFolder else { return }
    let file = batch.files[index]
    receiverCurrentFileIndex = index
    receiverWrittenBytes = 0
    lastAckedWrittenBytes = 0
    unackedChunksCount = 0
    receiverHasher = SHA256()

    let partURL = dest.appendingPathComponent("\(file.name).anice-part")
    receiverPartFileURL = partURL
    FileManager.default.createFile(atPath: partURL.path, contents: nil)
    receiverPartFileHandle = try? FileHandle(forWritingTo: partURL)
  }

  private func scheduleAckTimer() {
    guard ackTimerTask == nil else { return }
    ackTimerTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 20_000_000)
      guard !Task.isCancelled else { return }
      self?.ackTimerTask = nil
      self?.flushAck()
    }
  }

  private func flushAck() {
    guard ackTask == nil,
          case .transferring(let batch, _, _, _, _, _, _) = state,
          batch.files.indices.contains(receiverCurrentFileIndex) else { return }
    let currentFile = batch.files[receiverCurrentFileIndex]
    let bytesToAck = receiverWrittenBytes
    if bytesToAck <= lastAckedWrittenBytes && bytesToAck != currentFile.size { return }

    ackTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.ackTask = nil
        let unacked = self.receiverWrittenBytes - self.lastAckedWrittenBytes
        if unacked >= 8 * self.peerMaxChunkBytes || (self.receiverWrittenBytes == currentFile.size && self.receiverWrittenBytes > self.lastAckedWrittenBytes) {
          self.flushAck()
        }
      }
      let ack = TransferMessage.ack(batch: batch.idString, file: currentFile.idString, written: bytesToAck)
      if let encoded = try? ack.encode() {
        do {
          try await self.sendWithBackpressure(encoded)
          self.lastAckedWrittenBytes = max(self.lastAckedWrittenBytes, bytesToAck)
          self.unackedChunksCount = 0
        } catch {
          // Will be retried on next flushAck or capacityAvailable
        }
      }
    }
  }

  private func handleChunk(_ message: TransferMessage) {
    guard case .transferring(let batch, _, _, _, _, let totalBytesTransferred, _) = state,
          let dest = destinationFolder,
          let handle = receiverPartFileHandle,
          let partURL = receiverPartFileURL else { return }

    let fileId = message.string(1)
    let offset = message.number(2)
    let data = message.bytes(3)

    guard batch.files.indices.contains(receiverCurrentFileIndex) else { return }
    let currentFile = batch.files[receiverCurrentFileIndex]
    guard currentFile.idString == fileId else { return }
    guard offset == receiverWrittenBytes else { return }

    try? handle.write(contentsOf: data)
    receiverHasher.update(data: data)
    receiverWrittenBytes += Int64(data.count)
    unackedChunksCount += 1

    let nextTotalBytes = totalBytesTransferred + Int64(data.count)
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastReceiverUiUpdate >= 0.1 || receiverWrittenBytes == currentFile.size {
      lastReceiverUiUpdate = now
      let elapsed = max(0.001, now - receiverStartTime)
      let speed = Double(nextTotalBytes) / elapsed

      state = .transferring(
        batch: batch,
        fileIndex: receiverCurrentFileIndex + 1,
        fileName: currentFile.name,
        fileBytes: receiverWrittenBytes,
        fileSize: currentFile.size,
        totalBytes: nextTotalBytes,
        speedBps: speed
      )
    }

    // Ack every 8 chunks or at end of file
    let unacked = receiverWrittenBytes - lastAckedWrittenBytes
    if unacked >= 8 * peerMaxChunkBytes || receiverWrittenBytes == currentFile.size {
      flushAck()
    } else if receiverWrittenBytes > lastAckedWrittenBytes {
      scheduleAckTimer()
    }

    // Check file completion
    if receiverWrittenBytes == currentFile.size {
      ackTimerTask?.cancel()
      ackTimerTask = nil
      flushAck()
      try? handle.close()
      receiverPartFileHandle = nil

      let digest = Data(receiverHasher.finalize())
      if digest == currentFile.sha256 {
        // Atomic rename
        let finalURL = uniqueDestinationURL(folder: dest, name: currentFile.name)
        try? FileManager.default.moveItem(at: partURL, to: finalURL)

        let resultMsg = TransferMessage.fileResult(batch: batch.idString, file: fileId, result: 0, hash: digest)
        if let encoded = try? resultMsg.encode() {
          Task { [weak self] in try? await self?.sendWithBackpressure(encoded) }
        }

        // Advance to next file or complete batch
        let nextIndex = receiverCurrentFileIndex + 1
        if nextIndex < batch.files.count {
          prepareReceiverForFile(at: nextIndex, in: batch)
        } else {
          // All files in batch received!
          let batchRes = TransferMessage.batchResult(batch: batch.idString, result: 0)
          if let encoded = try? batchRes.encode() {
            Task { [weak self] in try? await self?.sendWithBackpressure(encoded) }
          }
          state = .completed(batchId: batch.id, fileCount: batch.files.count, totalBytes: batch.totalBytes)
          cleanupActiveTransfer()
        }
      } else {
        // Mismatch!
        try? FileManager.default.removeItem(at: partURL)
        let resultMsg = TransferMessage.fileResult(batch: batch.idString, file: fileId, result: 1, hash: digest)
        if let encoded = try? resultMsg.encode() {
          Task { [weak self] in try? await self?.sendWithBackpressure(encoded) }
        }
        failTransfer(reason: "Hash mismatch on received file \(currentFile.name)")
      }
    }
  }

  private func uniqueDestinationURL(folder: URL, name: String) -> URL {
    var candidate = folder.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
    let ext = (name as NSString).pathExtension
    let base = (name as NSString).deletingPathExtension
    var counter = 1
    while FileManager.default.fileExists(atPath: candidate.path) {
      let nextName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
      candidate = folder.appendingPathComponent(nextName)
      counter += 1
    }
    return candidate
  }

  // MARK: - Cancellation and Cleanup

  func cancelTransfer(local: Bool = true) {
    if local, let batch = currentBatch {
      let cancelMsg = TransferMessage.cancel(batch: batch.idString, file: "", reason: 0)
      if let encoded = try? cancelMsg.encode() {
        Task { [weak self] in try? await self?.sendWithBackpressure(encoded) }
      }
    }
    state = .cancelled
    cleanupActiveTransfer()
  }

  func dismiss() {
    state = .idle
    cleanupActiveTransfer()
  }

  private func failTransfer(reason: String) {
    state = .failed(reason: reason)
    cleanupActiveTransfer()
  }

  private func cleanupActiveTransfer() {
    transferTask?.cancel()
    transferTask = nil
    ackTask?.cancel()
    ackTask = nil
    ackTimerTask?.cancel()
    ackTimerTask = nil
    try? receiverPartFileHandle?.close()
    receiverPartFileHandle = nil
    if let partURL = receiverPartFileURL, FileManager.default.fileExists(atPath: partURL.path) {
      try? FileManager.default.removeItem(at: partURL)
    }
    receiverPartFileURL = nil
    creditResume?()
    creditResume = nil
    clearCapacityWaiters()
    releaseSleepAssertion()
  }

  // MARK: - Sleep Assertion Management

  private func acquireSleepAssertion() {
    guard !hasSleepAssertion else { return }
    let reason = "aniCe active file transfer" as CFString
    let res = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      reason,
      &sleepAssertionID
    )
    if res == kIOReturnSuccess {
      hasSleepAssertion = true
    }
  }

  private func releaseSleepAssertion() {
    guard hasSleepAssertion else { return }
    IOPMAssertionRelease(sleepAssertionID)
    hasSleepAssertion = false
    sleepAssertionID = 0
  }
}
