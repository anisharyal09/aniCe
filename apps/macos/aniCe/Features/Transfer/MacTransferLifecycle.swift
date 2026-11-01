// SPDX-License-Identifier: GPL-3.0-or-later
// Cancels and retires transfer work while releasing owned resources and sleep assertions.
import Foundation
import IOKit.pwr_mgt

extension MacTransferModel {
  func cancelTransfer(local: Bool = true) {
    if local, let batch = currentBatch, let channel = activeChannel {
      let cancelMsg = TransferMessage.cancel(batch: batch.idString, file: "", reason: 0)
      if let encoded = try? cancelMsg.encode() {
        Task { [weak self] in
          guard let self, self.channels[channel.descriptor.transport]?.descriptor == channel.descriptor else { return }
          try? await self.sendWithBackpressure(encoded, on: channel, jobBound: false)
        }
      }
    }
    retainedFileResult = nil
    state = .cancelled
    cleanupActiveTransfer()
  }

  func dismiss() {
    receiving = false
    publishedURLs.removeAll()
    receiveFolder = nil
    retainedFileResult = nil
    state = .idle
    cleanupActiveTransfer()
  }

  func invalidate() {
    let active = isBusy
    retainedFileResult = nil
    state = active ? .failed(reason: "Trust or identity changed. Send the files again after pairing.") : .idle
    cleanupActiveTransfer()
    let operation = epoch
    Task { [weak self] in
      guard let self, let identity = self.recoveryIdentity else { return }
      let local = try? await identity.publicIdentity().fingerprint
      if operation == self.epoch { self.recoveryLocal = local }
    }
  }

  func failTransfer(reason: String) {
    if case .completed = state { return }
    if case .cancelled = state { return }
    // A paused batch has no channel to report through; the retained prefix is discarded below.
    if !isPaused,
      let batch = currentBatch, receiverPartFileURL != nil,
      batch.files.indices.contains(receiverCurrentFileIndex), let channel = activeChannel {
      let file = batch.files[receiverCurrentFileIndex]
      let result = TransferMessage.fileResult(batch: batch.idString, file: file.idString, result: 2, hash: Data(repeating: 0, count: 32))
      Task { [weak self] in
        guard let self, self.channels[channel.descriptor.transport]?.descriptor == channel.descriptor else { return }
        try? await self.sendWithBackpressure(result.encode(), on: channel, jobBound: false)
      }
    }
    retainedFileResult = nil
    state = .failed(reason: reason)
    let wasReceiving = receiving
    cleanupActiveTransfer()
    if wasReceiving { onEvent?(.failed(reason: reason)) }
  }

  func cleanupActiveTransfer(selectChannel: Bool = true) {
    rendezvousWait?()
    retainedBatch = nil; offerReplayed = false; restoredSender = false
    let failed = failedRecovery
    failedRecovery = nil
    if let failed, failed.receiving, failed.stage == 0 || failed.stage == 4,
      let folder = failed.folder, let partial = failed.partial {
      Task.detached {
        do { try TransferReceiveStorage.discardOwned(folder: folder, partial: partial,
          batch: failed.batch.idString, file: failed.batch.files[failed.index].idString) }
        catch { NSLog("Retained partial cleanup failed: %@", error.localizedDescription) }
      }
    }
    checkpointAt = 0; checkpointPosition = nil
    finalizationRetired = nil
    finalizationResumed = false
    receiptExpiry?.cancel(); receiptExpiry = nil
    receiptDeadline = nil
    interruptedOffer = nil
    if let store = recoveryStore {
      let previous = recoveryWrite
      recoveryWrite = Task {
        await previous?.value
        do { try await store.clear() }
        catch { NSLog("Transfer recovery cleanup failed: %@", error.localizedDescription) }
      }
    }
    recoveryPeer = nil; pauseExpiresAt = nil; pauseDeadline = nil
    resumeAttemptChannel = nil; nextResumeAttemptAt = 0
    progressTask?.cancel(); progressTask = nil; progressEpoch = nil
    preparation?.cancel(); preparation = nil; preparing = false
    clearOfferAssembly()
    pauseTimerTask?.cancel(); pauseTimerTask = nil
    resumeTask?.cancel(); resumeTask = nil
    upgradeTask?.cancel(); upgradeTask = nil
    abandonStatus()
    allowBleResume = false
    pausedTransport = nil
    pausedFileIndex = 0
    pausedFileOffset = 0
    pausedCompletedBytes = 0
    transferPeerDeviceId = nil
    transferPeerFingerprint = nil
    senderFileIndex = 0
    epoch = UUID()
    // Cancel unsealed work; SecureSession finishes nonce-owned submissions under the old epoch.
    transferTask?.cancel(); transferTask = nil
    fileResultContinuation?.resume(throwing: SessionFailure.cancelled)
    fileResultContinuation = nil
    receivedFileResult = nil
    if let batch = currentBatch {
      retiredBatches.append(batch.idString)
      if retiredBatches.count > 32 { retiredBatches.removeFirst() }
    }
    currentBatch = nil
    destinationFolder = nil
    sendingFile = nil
    sendWindow = nil
    finalizing = false
    ackTask?.cancel(); ackTask = nil
    ackTimerTask?.cancel()
    ackTimerTask = nil
    let storage = receiverStorage
    receiverStorage = nil
    receiverPartFileURL = nil
    Task { await storage?.discard() }
    resumeCredit()
    clearCapacityWaiters()
    receiverTotalTransferred = 0
    releaseSleepAssertion()
    if selectChannel { selectPreferredChannel() }
  }

  func acquireSleepAssertion() {
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

  func releaseSleepAssertion() {
    guard hasSleepAssertion else { return }
    IOPMAssertionRelease(sleepAssertionID)
    hasSleepAssertion = false
    sleepAssertionID = 0
  }
}
