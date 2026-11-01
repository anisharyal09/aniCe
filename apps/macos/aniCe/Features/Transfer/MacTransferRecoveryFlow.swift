// SPDX-License-Identifier: GPL-3.0-or-later
// Restores and checkpoints transfer jobs against the feature-owned recovery store.
import Foundation

extension MacTransferModel {
  func checkpoint(force: Bool = false, publishingIdentity: String? = nil) {
    if finalizing, publishingIdentity == nil { return }
    guard recoveryReady, let store = recoveryStore, let local = recoveryLocal, let batch = currentBatch else { return }
    let stage: Int
    switch interruptedOffer ?? state {
    case .waitingForPeerApproval: stage = 1
    case .incomingOffer: stage = 2
    default: stage = publishingIdentity != nil ? 4 : 0
    }
    guard isTransferring || isPaused || stage != 0 else { return }
    let now = ProcessInfo.processInfo.systemUptime
    // Keep synchronous storage flushes off the frequent progress-publication cadence.
    guard force || now - checkpointAt >= 5 else { return }
    guard let peer = activeChannel?.descriptor ?? recoveryPeer else { return }
    recoveryPeer = peer
    let index = stage == 1 || stage == 2 ? 0 : receiving ? receiverCurrentFileIndex : senderFileIndex
    guard batch.files.indices.contains(index) else { return }
    if receiving, receiverStorage == nil, stage == 0 { return }
    let offset: Int64 = stage == 1 || stage == 2 ? 0 : receiving ? receiverWrittenBytes : acknowledgedBytes
    let position = "\(batch.id):\(index):\(offset):\(stage)"
    if !force, checkpointPosition == position { return }
    checkpointPosition = position
    checkpointAt = now
    let snapshot = TransferCheckpoint(localFingerprint: local, peerId: peer.peer.deviceId,
      peerFingerprint: peer.peer.fingerprint, batch: batch, receiving: receiving || stage == 2, index: index,
      offset: offset, folder: destinationFolder,
      partial: receiverPartFileURL, transport: pausedTransport ?? peer.transport,
      expiresAt: pauseExpiresAt ?? Date().addingTimeInterval(Double(pauseTimeout.components.seconds)),
      stage: stage, fileIdentity: publishingIdentity ?? "")
    let previous = recoveryWrite, storage = receiving ? receiverStorage : nil
    recoveryWrite = Task { [weak self] in
      await previous?.value
      do { try await storage?.flush(); try await store.save(snapshot) }
      catch {
        guard let self, self.currentBatch?.id == snapshot.batch.id else { return }
        self.failTransfer(reason: "Cannot save transfer recovery: \(error.localizedDescription)")
      }
    }
  }

  func restoreRecovery(_ snapshot: TransferCheckpoint, local: String) async throws {
    var saved = snapshot
    let operation = epoch
    let remaining = saved.expiresAt.timeIntervalSinceNow
    guard saved.localFingerprint == local, remaining > 0,
      remaining <= Double(pauseTimeout.components.seconds) else {
      if saved.receiving, saved.stage == 0 || saved.stage == 4, let folder = saved.folder, let partial = saved.partial {
        let expired = saved
        try await Task.detached {
          try TransferReceiveStorage.discardOwned(folder: folder, partial: partial, batch: expired.batch.idString,
            file: expired.batch.files[expired.index].idString)
        }.value
      }
      try await recoveryStore?.clear()
      state = .failed(reason: "The saved transfer expired or its local identity changed. Send the files again.")
      return
    }
    if saved.stage == 4, let folder = saved.folder {
      let candidate = saved
      let published = try await Task.detached {
        try TransferReceiveStorage.published(folder: folder, file: candidate.batch.files[candidate.index],
          identity: candidate.fileIdentity)
      }.value
      guard operation == epoch else { return }
      if let published {
        if let partial = saved.partial {
          try await Task.detached {
            try TransferReceiveStorage.discardOwned(folder: folder, partial: partial, batch: candidate.batch.idString,
              file: candidate.batch.files[candidate.index].idString)
          }.value
        }
        publishedURLs.append(published)
        if saved.index == saved.batch.files.count - 1 { saved.stage = 3 }
        else {
          let storage = TransferReceiveStorage()
          saved.index += 1; saved.offset = 0; saved.stage = 0
          let partial = try await storage.create(folder: folder, batch: saved.batch.idString,
            file: saved.batch.files[saved.index].idString)
          guard operation == epoch else { await storage.discard(); return }
          receiverStorage = storage; receiverPartFileURL = partial
          destinationFolder = folder; receiveFolder = folder; saved.partial = partial
        }
        try await recoveryStore?.save(saved)
      }
    }
    if saved.stage == 3 {
      let file = saved.batch.files[saved.batch.files.count - 1]
      retainedFileResult = RetainedFileResult(batchId: saved.batch.idString, fileId: file.idString,
        fileSize: file.size, result: TransferMessage.fileResult(batch: saved.batch.idString,
          file: file.idString, result: 0, hash: file.sha256), peerId: saved.peerId, peerFingerprint: saved.peerFingerprint)
      receiving = true
      retainedBatch = saved.batch
      state = .completed(batchId: saved.batch.id, fileCount: saved.batch.files.count, totalBytes: saved.batch.totalBytes)
      expireReceipt(saved.batch.idString, after: remaining)
      return
    }
    if saved.receiving, saved.stage == 0 || saved.stage == 4, receiverStorage == nil {
      guard let folder = saved.folder, let partial = saved.partial else { throw CocoaError(.fileReadCorruptFile) }
      let storage = TransferReceiveStorage()
      try await storage.restore(folder: folder, partial: partial, batch: saved.batch.idString,
        file: saved.batch.files[saved.index].idString, length: saved.offset)
      guard operation == epoch else { await storage.discard(); return }
      receiverStorage = storage; receiverPartFileURL = partial
      destinationFolder = folder; receiveFolder = folder
    }
    currentBatch = saved.batch; receiving = saved.receiving; restoredSender = !saved.receiving
    interruptedOffer = saved.stage == 1 ? .waitingForPeerApproval(batch: saved.batch)
      : saved.stage == 2 ? .incomingOffer(batch: saved.batch) : nil
    transferPeerDeviceId = saved.peerId; transferPeerFingerprint = saved.peerFingerprint
    senderFileIndex = saved.index; receiverCurrentFileIndex = saved.index
    acknowledgedBytes = saved.offset; receiverWrittenBytes = saved.offset; sentBytes = saved.offset
    if saved.receiving, saved.index > 0 {
      let file = saved.batch.files[saved.index - 1]
      retainedFileResult = RetainedFileResult(batchId: saved.batch.idString, fileId: file.idString,
        fileSize: file.size, result: TransferMessage.fileResult(batch: saved.batch.idString,
          file: file.idString, result: 0, hash: file.sha256), peerId: saved.peerId, peerFingerprint: saved.peerFingerprint)
    }
    pausedFileIndex = saved.index; pausedFileOffset = saved.offset
    pausedCompletedBytes = saved.batch.files.prefix(saved.index).reduce(0) { $0 + $1.size }
    receiverTotalTransferred = pausedCompletedBytes + saved.offset
    pausedTransport = saved.transport; pauseExpiresAt = saved.expiresAt; pauseDeadline = pauseClock.now.advanced(by: .seconds(remaining))
    let file = saved.batch.files[saved.index]
    state = .paused(batch: saved.batch, fileIndex: saved.index + 1, fileName: file.name,
      fileBytes: saved.offset, fileSize: file.size, totalBytes: pausedCompletedBytes + saved.offset,
      reason: "Waiting to reconnect", canResumeOverBle: false)
    startPauseTimer()
  }
}
