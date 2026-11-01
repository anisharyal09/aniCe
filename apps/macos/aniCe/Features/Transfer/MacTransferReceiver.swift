// SPDX-License-Identifier: GPL-3.0-or-later
// Approves incoming offers, writes bounded chunks and finalizes verified files.
import Foundation
import CryptoKit

extension MacTransferModel {
  /// Recreates the current file from zero after the retained prefix failed verification.
  func resetReceiverFile(_ batch: TransferBatch, _ file: TransferFile) async -> Bool {
    let operation = epoch
    let previous = receiverStorage
    receiverStorage = nil
    receiverPartFileURL = nil
    await previous?.discard()
    guard operation == epoch, currentBatch?.id == batch.id else { return false }
    receiverTotalTransferred = max(receiverTotalTransferred - receiverWrittenBytes, 0)
    receiverWrittenBytes = 0
    lastAckedWrittenBytes = 0
    do {
      try await prepareReceiverForFile(at: receiverCurrentFileIndex, in: batch)
      return operation == epoch
    } catch {
      return false
    }
  }

  func replyStatus(_ channel: any SecuredChannel, batch: String, file: String, bytes: Int64, state: Int64) async {
    if let encoded = try? TransferMessage.status(batch: batch, file: file, bytesTransferred: bytes, state: state).encode() {
      try? await sendWithBackpressure(encoded, on: channel, jobBound: false)
    }
  }

  func filePrefixDigest(_ file: TransferFile, length: Int64) async throws -> Data {
    guard length >= 0, length <= file.size, let url = file.localURL else { throw CocoaError(.fileReadUnknown) }
    return try await TransferSendStorage.prefixDigest(url, length: length)
  }

  func handleOffer(_ message: TransferMessage, peerName: String, on descriptor: ChannelDescriptor) {
    let batchIdStr = message.string(0)
    guard !retiredBatches.contains(batchIdStr) || retainedBatch?.idString == batchIdStr else { return }
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

    if let assembly = offerAssembly, assembly.batch != batchIdStr { return }
    if offerAssembly == nil {
      offerAssembly = OfferAssembly(batch: batchIdStr, totalSlices: totalSlices, totalFiles: totalFiles, totalBytes: totalBytes)
      offerTimeout = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        self?.clearOfferAssembly()
        self?.selectPreferredChannel()
      }
    }
    guard var assembly = offerAssembly, assembly.totalSlices == totalSlices,
      assembly.totalFiles == totalFiles, assembly.totalBytes == totalBytes else { clearOfferAssembly(); return }
    if let previous = assembly.slices[sliceIdx] {
      if previous != sliceFiles { clearOfferAssembly() }
      return
    }
    assembly.slices[sliceIdx] = sliceFiles
    offerAssembly = assembly

    if Int64(assembly.slices.count) == totalSlices {
      let slices = assembly.slices
      var allFiles: [TransferFile] = []
      for i in 0..<totalSlices {
        allFiles.append(contentsOf: slices[i] ?? [])
      }

      var sum: Int64 = 0
      for file in allFiles {
        let next = sum.addingReportingOverflow(file.size)
        guard !next.overflow else { clearOfferAssembly(); return }
        sum = next.partialValue
      }
      guard allFiles.count == Int(totalFiles), sum == totalBytes,
        Set(allFiles.map(\.id)).count == allFiles.count else { clearOfferAssembly(); return }
      clearOfferAssembly()
      let batch = TransferBatch(id: batchUUID, files: allFiles, totalBytes: totalBytes, peerName: peerName)

      let remembered = currentBatch?.id == batch.id ? currentBatch : retainedBatch?.id == batch.id ? retainedBatch : nil
      if let remembered {
        guard remembered.files == batch.files, remembered.totalBytes == batch.totalBytes else { return }
        if case .incomingOffer = state { return }
        if let interruptedOffer, case .incomingOffer = interruptedOffer { return }
        if receiving, currentBatch?.id == batch.id || retainedBatch?.id == batch.id,
          let channel = channels[descriptor.transport] {
          Task { [weak self] in
            try? await self?.sendWithBackpressure(TransferMessage.accept(batch: batch.idString, files: []).encode(),
              on: channel, jobBound: false)
          }
          return
        }
      }

      let isBusy: Bool
      switch state {
      case .waitingForPeerApproval, .incomingOffer, .transferring, .paused:
        isBusy = true
      default:
        isBusy = false
      }

      if isBusy || preparing || transferTask != nil {
        // Busy with another active transfer
        guard let channel = activeChannel else { return }
        Task {
          let reject = TransferMessage.reject(batch: batchIdStr, reason: 3)
          if let encoded = try? reject.encode() {
            try? await sendWithBackpressure(encoded, on: channel, jobBound: false)
          }
        }
        return
      }

      cleanupActiveTransfer(selectChannel: false)
      currentBatch = batch
      state = .incomingOffer(batch: batch)
      acquireSleepAssertion()
      onEvent?(.incomingOffer(batch))
    }
  }

  func clearOfferAssembly() {
    offerTimeout?.cancel(); offerTimeout = nil
    offerAssembly = nil
  }

  func acceptIncomingOffer(destination: URL) async {
    guard case .incomingOffer(let batch) = state, let channel = activeChannel else { return }
    let operation = epoch
    do {
      if let identity = recoveryIdentity, recoveryStore != nil {
        let local = try await identity.publicIdentity().fingerprint
        guard operation == epoch else { return }
        recoveryLocal = local
      }
      try await TransferReceiveStorage.checkCapacity(destination, bytes: batch.totalBytes)
      guard operation == epoch else { return }
    } catch { if operation == epoch { failTransfer(reason: "Cannot use destination: \(error.localizedDescription)") }; return }
    destinationFolder = destination
    receiveFolder = destination
    publishedURLs.removeAll()
    receiving = true
    transferPeerDeviceId = channel.descriptor.peer.deviceId
    transferPeerFingerprint = channel.descriptor.peer.fingerprint
    retainedFileResult = nil
    receiverCurrentFileIndex = 0
    receiverWrittenBytes = 0
    receiverTotalTransferred = 0
    lastAckedWrittenBytes = 0
    lastReceiverUiUpdate = 0

    do { try await prepareReceiverForFile(at: 0, in: batch) }
    catch { failTransfer(reason: "Cannot create destination: \(error.localizedDescription)"); return }
    guard operation == epoch, activeChannel?.descriptor == channel.descriptor else { return }
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
      do {
        try await sendWithBackpressure(encoded, on: channel)
        guard operation == epoch else { return }
        if batch.files[0].size == 0 { await finalizeReceiverFile(batch) }
      } catch { if operation == epoch { failTransfer(reason: "Failed accepting offer") } }
    }
  }

  func rejectIncomingOffer(reason: Int64 = 0) async {
    guard case .incomingOffer(let batch) = state, let channel = activeChannel else { return }
    let operation = epoch
    let reject = TransferMessage.reject(batch: batch.idString, reason: reason)
    if let encoded = try? reject.encode() {
      try? await sendWithBackpressure(encoded, on: channel)
    }
    guard operation == epoch else { return }
    state = .idle
    cleanupActiveTransfer()
  }

  func prepareReceiverForFile(at index: Int, in batch: TransferBatch) async throws {
    guard batch.files.indices.contains(index), let dest = destinationFolder else { return }
    let file = batch.files[index]
    receiverCurrentFileIndex = index
    receiverWrittenBytes = 0
    lastAckedWrittenBytes = 0
    receiverAckChunkBytes = 3072
    let operation = epoch
    let storage = TransferReceiveStorage()
    do {
      let url = try await storage.create(folder: dest, batch: batch.idString, file: file.idString)
      guard operation == epoch else { await storage.discard(); throw SessionFailure.cancelled }
      receiverStorage = storage
      receiverPartFileURL = url
    } catch { await storage.discard(); throw error }
  }

  func scheduleAckTimer() {
    guard ackTimerTask == nil else { return }
    ackTimerTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 20_000_000)
      guard !Task.isCancelled else { return }
      self?.ackTimerTask = nil
      self?.flushAck()
    }
  }

  func flushAck() {
    guard !finalizing, ackTask == nil,
          case .transferring(let batch, _, _, _, _, _, _) = state,
          batch.files.indices.contains(receiverCurrentFileIndex) else { return }
    let currentFile = batch.files[receiverCurrentFileIndex]
    let bytesToAck = receiverWrittenBytes
    if bytesToAck <= lastAckedWrittenBytes && bytesToAck != currentFile.size { return }

    let operation = epoch
    let fileIndex = receiverCurrentFileIndex
    guard let channel = activeChannel else { return }
    ackTask = Task { [weak self] in
      guard let self, operation == self.epoch, self.activeChannel?.descriptor == channel.descriptor else { return }
      var submitted = false
      defer {
        if self.epoch == operation && self.receiverCurrentFileIndex == fileIndex {
          self.ackTask = nil
          let unacked = self.receiverWrittenBytes - self.lastAckedWrittenBytes
          let ackThreshold = transferAckThreshold(maximumChunk: self.peerMaxChunkBytes,
            maximumWindow: self.peerMaxWindow, chunkBytes: self.receiverAckChunkBytes)
          // Failure waits for an external event; only success may drain newer credit.
          if submitted && (unacked >= ackThreshold || (self.receiverWrittenBytes == currentFile.size && self.receiverWrittenBytes > self.lastAckedWrittenBytes)) {
            self.flushAck()
          } else if submitted && unacked > 0 {
            // A coalescing timer may have expired while this ACK was still submitting.
            self.scheduleAckTimer()
          }
        }
      }
      let ack = TransferMessage.ack(batch: batch.idString, file: currentFile.idString, written: bytesToAck)
      if let encoded = try? ack.encode() {
        do {
          try await self.sendWithBackpressure(encoded, on: channel)
          submitted = true
          guard operation == self.epoch, self.receiverCurrentFileIndex == fileIndex else { return }
          self.lastAckedWrittenBytes = max(self.lastAckedWrittenBytes, bytesToAck)
        } catch {
          // Will be retried on next flushAck or capacityAvailable
        }
      }
    }
  }

  func handleChunk(_ message: TransferMessage) async -> DataHandling {
    guard case .transferring(let batch, _, _, _, _, _, _) = state,
          destinationFolder != nil, let storage = receiverStorage,
          receiverPartFileURL != nil else { return .discarded }

    let fileId = message.string(1)
    let offset = message.number(2)
    let data = message.bytes(3)

    guard batch.files.indices.contains(receiverCurrentFileIndex) else { return .discarded }
    let currentFile = batch.files[receiverCurrentFileIndex]
    guard currentFile.idString == fileId else { return .discarded }
    guard offset == receiverWrittenBytes else { return .discarded }

    guard message.string(0) == batch.idString, data.count <= chunkLimit(activeChannel?.descriptor), Int64(data.count) <= currentFile.size - receiverWrittenBytes else { return .discarded }
    let operation = epoch
    do { try await storage.write(data) }
    catch { if operation == epoch { failTransfer(reason: "Destination write failed: \(error.localizedDescription)") }; return .discarded }
    guard operation == epoch, receiverStorage === storage else { return .discarded }
    pauseExpiresAt = nil; pauseDeadline = nil
    receiverWrittenBytes += Int64(data.count)
    receiverTotalTransferred += Int64(data.count)
    receiverAckChunkBytes = Int64(data.count)

    let now = ProcessInfo.processInfo.systemUptime
    if now - lastReceiverUiUpdate >= 0.1 || receiverWrittenBytes == currentFile.size {
      lastReceiverUiUpdate = now
      let speed = sampleProgress(receiverTotalTransferred, at: now)

      state = .transferring(
        batch: batch,
        fileIndex: receiverCurrentFileIndex + 1,
        fileName: currentFile.name,
        fileBytes: receiverWrittenBytes,
        fileSize: currentFile.size,
        totalBytes: receiverTotalTransferred,
        speedBps: speed
      )
    }

    let unacked = receiverWrittenBytes - lastAckedWrittenBytes
    let ackThreshold = transferAckThreshold(maximumChunk: peerMaxChunkBytes,
      maximumWindow: peerMaxWindow, chunkBytes: receiverAckChunkBytes)
    if unacked >= ackThreshold || receiverWrittenBytes == currentFile.size {
      flushAck()
    } else if receiverWrittenBytes > lastAckedWrittenBytes {
      scheduleAckTimer()
    }

    if receiverWrittenBytes == currentFile.size { await finalizeReceiverFile(batch) }
    return .handled
  }

  func finalizeReceiverFile(_ batch: TransferBatch) async {
    guard !finalizing, batch.files.indices.contains(receiverCurrentFileIndex),
      let storage = receiverStorage, receiverPartFileURL != nil, destinationFolder != nil else { return }
    finalizing = true
    finalizationResumed = false
    let operation = epoch
    let file = batch.files[receiverCurrentFileIndex]
    ackTimerTask?.cancel(); ackTimerTask = nil
    // Hashing and publication move no further bytes, so the last measured rate is stale. Both
    // receivers present a zero rate as "no rate available" while the file is being saved.
    if case .transferring(let active, let index, let name, let bytes, let size, let total, _) = state {
      state = .transferring(
        batch: active, fileIndex: index, fileName: name, fileBytes: bytes, fileSize: size,
        totalBytes: total, speedBps: 0)
    }
    let digest: Data
    do {
      checkpoint(force: true, publishingIdentity: try await storage.fileIdentity())
      await recoveryWrite?.value
      guard operation == epoch, receiverStorage === storage else { return }
      let finished = try await storage.finish(name: file.name, expected: file.sha256)
      digest = finished.digest
      guard operation == epoch, receiverStorage === storage else { return }
      publishedURLs.append(finished.url)
    } catch {
      if operation == epoch {
        finalizing = false
        // Verification and publication fail for different reasons; the receiver is told which one,
        // and a digest mismatch reports the same wording Android uses for the same condition.
        var reason = "Cannot save the received file: \(error.localizedDescription)"
        if let failure = error as? SessionFailure, failure == .authentication {
          reason = "Hash mismatch"
        }
        failTransfer(reason: reason)
      }
      return
    }
    guard operation == epoch, receiverStorage === storage else { return }
    // Kept across completion so a resume that lands after the last chunk can still be answered.
    retainedFileResult = RetainedFileResult(
      batchId: batch.idString,
      fileId: file.idString,
      fileSize: file.size,
      result: TransferMessage.fileResult(batch: batch.idString, file: file.idString, result: 0, hash: digest),
      peerId: recoveryPeer?.peer.deviceId ?? transferPeerDeviceId ?? "",
      peerFingerprint: recoveryPeer?.peer.fingerprint ?? transferPeerFingerprint ?? ""
    )
    receiverStorage = nil
    receiverPartFileURL = nil
    Task { [weak self] in
      guard let self else { return }
      do {
        await self.ackTask?.value
        guard operation == self.epoch else { return }
        let next = self.receiverCurrentFileIndex + 1
        if next < batch.files.count {
          try await self.prepareReceiverForFile(at: next, in: batch)
          self.state = .transferring(batch: batch, fileIndex: next + 1, fileName: batch.files[next].name,
            fileBytes: 0, fileSize: batch.files[next].size, totalBytes: self.receiverTotalTransferred, speedBps: 0)
        }
        if let lost = self.finalizationRetired, !self.finalizationResumed || self.activeChannel == nil {
          self.finalizationRetired = nil; self.finalizing = false
          if next == batch.files.count { self.completeReceiver(batch) }
          else { self.pauseTransfer(batch: batch, transport: lost.transport); self.selectPreferredChannel() }
          return
        }
        self.finalizationRetired = nil
        try await self.sendWithBackpressure(TransferMessage.fileResult(batch: batch.idString, file: file.idString, result: 0, hash: digest).encode())
        guard operation == self.epoch else { return }
        self.finalizing = false
        if next < batch.files.count {
          if self.receiverWrittenBytes == batch.files[next].size { await self.finalizeReceiverFile(batch) }
        } else {
          try await self.sendWithBackpressure(TransferMessage.batchResult(batch: batch.idString, result: 0).encode())
          guard operation == self.epoch else { return }
          self.completeReceiver(batch)
        }
      } catch {
        guard operation == self.epoch else { return }
        if self.finalizationRetired != nil,
          self.retainedFileResult?.fileId == batch.files.last?.idString {
          self.finalizationRetired = nil; self.finalizing = false
          self.completeReceiver(batch)
        } else if let lost = self.finalizationRetired, self.receiverStorage != nil {
          self.finalizationRetired = nil; self.finalizing = false
          self.pauseTransfer(batch: batch, transport: lost.transport); self.selectPreferredChannel()
        } else { self.failTransfer(reason: "Completion delivery failed") }
      }
    }
  }

  func completeReceiver(_ batch: TransferBatch) {
    let saved: TransferCheckpoint?
    if let local = recoveryLocal, let peer = activeChannel?.descriptor ?? recoveryPeer {
      saved = TransferCheckpoint(localFingerprint: local, peerId: peer.peer.deviceId,
        peerFingerprint: peer.peer.fingerprint, batch: batch, receiving: true, index: batch.files.count - 1,
        offset: batch.files[batch.files.count - 1].size, folder: nil, partial: nil, transport: peer.transport,
        expiresAt: Date().addingTimeInterval(Double(pauseTimeout.components.seconds)), stage: 3)
    } else { saved = nil }
    state = .completed(batchId: batch.id, fileCount: batch.files.count, totalBytes: batch.totalBytes)
    cleanupActiveTransfer()
    retainedBatch = batch
    if let saved, let store = recoveryStore {
      let previous = recoveryWrite
      recoveryWrite = Task {
        await previous?.value
        do { try await store.save(saved) }
        catch { NSLog("Transfer receipt storage failed: %@", error.localizedDescription) }
      }
    }
    expireReceipt(batch.idString, after: Double(pauseTimeout.components.seconds))
    onEvent?(.completed(fileCount: batch.files.count, totalBytes: batch.totalBytes))
  }

  func expireReceipt(_ batchId: String, after remaining: TimeInterval) {
    receiptExpiry?.cancel()
    receiptDeadline = pauseClock.now.advanced(by: .seconds(remaining))
    receiptExpiry = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
      guard let self, self.retainedFileResult?.batchId == batchId, self.currentBatch == nil else { return }
      self.retainedFileResult = nil; self.retainedBatch = nil; self.receiptDeadline = nil
      if let store = self.recoveryStore {
        let previous = self.recoveryWrite
        self.recoveryWrite = Task {
          await previous?.value
          do { try await store.clear() }
          catch { NSLog("Transfer receipt cleanup failed: %@", error.localizedDescription) }
        }
      }
    }
  }
}
