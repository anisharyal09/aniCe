// SPDX-License-Identifier: GPL-3.0-or-later
// Pauses and resumes transfer jobs across authenticated transport replacement.
import Foundation

extension MacTransferModel {
  func expirePausedIfNeeded() -> Bool {
    guard isPaused, let deadline = pauseDeadline, pauseClock.now >= deadline else { return false }
    failTransfer(reason: "Transfer paused for too long without a connection. Send the files again.")
    return true
  }

  func claimResumeAttempt(_ descriptor: ChannelDescriptor) -> Bool {
    let now = ProcessInfo.processInfo.systemUptime
    if resumeAttemptChannel == descriptor, now < nextResumeAttemptAt { return false }
    resumeAttemptChannel = descriptor; nextResumeAttemptAt = now + 2
    return true
  }

  func pauseOnConfirmationTimeout() {
    guard case .transferring(let batch, _, _, _, _, _, _) = state, let channel = activeChannel else { return }
    pauseTransfer(batch: batch, transport: channel.descriptor.transport)
    selectPreferredChannel()
  }

  func pauseOffer(_ previous: TransferState, descriptor: ChannelDescriptor) {
    guard let batch = currentBatch, let file = batch.files.first else { return }
    interruptedOffer = previous
    recoveryPeer = descriptor; pausedTransport = descriptor.transport
    pauseExpiresAt = pauseExpiresAt ?? Date().addingTimeInterval(Double(pauseTimeout.components.seconds))
    pauseDeadline = pauseDeadline ?? pauseClock.now.advanced(by: pauseTimeout)
    pausedFileIndex = 0; pausedFileOffset = 0; pausedCompletedBytes = 0
    epoch = UUID()
    state = .paused(batch: batch, fileIndex: 1, fileName: file.name, fileBytes: 0,
      fileSize: file.size, totalBytes: 0, reason: "Waiting to reconnect", canResumeOverBle: false)
    startPauseTimer(); checkpoint(force: true)
  }

  func resumeInterruptedOffer() -> Bool {
    if expirePausedIfNeeded() { return true }
    guard let previous = interruptedOffer else { return false }
    guard isPaused, peerCompatible, let channel = activeChannel else { return true }
    if pausedTransport == "lan", channel.descriptor.transport == "ble", !allowBleResume {
      refreshPausedCapability(); return true
    }
    interruptedOffer = nil
    pauseTimerTask?.cancel(); pauseTimerTask = nil; pauseExpiresAt = nil; pauseDeadline = nil
    if case .waitingForPeerApproval = previous { offerReplayed = true }
    state = previous
    acquireSleepAssertion()
    if case .waitingForPeerApproval(let batch) = previous {
      Task { [weak self] in await self?.sendOfferBatch(batch, channel: channel) }
    }
    return true
  }

  var isTransferring: Bool {
    if case .transferring = state { return true }
    return false
  }

  /// Retains a mid-stream batch after its active channel retired. Nothing is published, discarded
  /// or released here: the partial, destination and sleep assertion stay alive for `pauseTimeout`,
  /// and only Cancel, a permanent recovery failure or the timer ends them.
  func pauseTransfer(batch: TransferBatch, transport: String) {
    let fileIndex = receiving ? receiverCurrentFileIndex : senderFileIndex
    guard batch.files.indices.contains(fileIndex) else {
      failTransfer(reason: "Connection closed. Send the files again using the remaining connection.")
      return
    }
    let file = batch.files[fileIndex]
    if receiving, receiverStorage == nil {
      failTransfer(reason: "Connection closed while saving \(file.name). Send the files again.")
      return
    }
    pausedTransport = transport
    recoveryPeer = activeChannel?.descriptor ?? recoveryPeer
    pauseExpiresAt = pauseExpiresAt ?? Date().addingTimeInterval(Double(pauseTimeout.components.seconds))
    pauseDeadline = pauseDeadline ?? pauseClock.now.advanced(by: pauseTimeout)
    pausedFileIndex = fileIndex
    pausedFileOffset = max(0, min(receiving ? receiverWrittenBytes : acknowledgedBytes, file.size))
    pausedCompletedBytes = receiving
      ? max(receiverTotalTransferred - receiverWrittenBytes, 0)
      : batch.files.prefix(fileIndex).reduce(0) { $0 + $1.size }
    allowBleResume = false
    transferTask?.cancel(); transferTask = nil
    fileResultContinuation?.resume(throwing: SessionFailure.cancelled)
    fileResultContinuation = nil
    ackTask?.cancel(); ackTask = nil
    ackTimerTask?.cancel(); ackTimerTask = nil
    resumeCredit()
    clearCapacityWaiters()
    resumeTask?.cancel(); resumeTask = nil
    upgradeTask?.cancel(); upgradeTask = nil
    abandonStatus()
    // Old-channel callbacks must not touch the retained batch after the channel is gone.
    epoch = UUID()
    let reason = transport == "lan" ? "Local network connection lost" : "Bluetooth connection lost"
    state = .paused(
      batch: batch,
      fileIndex: fileIndex + 1,
      fileName: file.name,
      fileBytes: pausedFileOffset,
      fileSize: file.size,
      totalBytes: pausedCompletedBytes + pausedFileOffset,
      reason: reason,
      canResumeOverBle: false
    )
    startPauseTimer()
    checkpoint(force: true)
    // Automatic LAN policy decides whether a new window may open; an explicit Disconnect still
    // wins, so a paused batch never forces LAN back on by itself.
    _ = onLanRequired()
    onEvent?(.paused(batch: batch, reason: reason, canResumeOverBle: false))
  }

  func startPauseTimer() {
    pauseTimerTask?.cancel()
    let operation = epoch
    let deadline = pauseDeadline ?? pauseClock.now.advanced(by: pauseTimeout)
    pauseTimerTask = Task { [weak self] in
      do { try await Task.sleep(until: deadline, clock: ContinuousClock()) } catch { return }
      guard let self, self.epoch == operation, self.isPaused else { return }
      self.failTransfer(reason: "Transfer paused for too long without a connection. Send the files again.")
    }
  }

  /// Explicit Bluetooth continuation for either side. The sender asks the receiver to continue at
  /// its acknowledged offset; the receiver asks the sender to validate the prefix it already holds
  /// and stream the rest over BLE. Both use the same resume/status kinds with no framing change.
  func resumeOverBluetooth() {
    guard case .paused = state, pausedTransport == "lan" else { return }
    allowBleResume = true
    if let ble = channels["ble"], activeChannel?.descriptor != ble.descriptor {
      activeChannel = ble
      peerConnected = true
      peerCompatible = false
      peerMaxChunkBytes = 3072
      peerMaxWindow = 64
      if let capability = capabilities["ble"] { applyCapability(capability) }
    }
    refreshPausedCapability()
    guard peerCompatible else { return }
    if !resumeInterruptedOffer() {
      if receiving { requestPeerContinuation() } else { attemptResume() }
    }
  }

  func refreshPausedCapability() {
    guard case .paused(let batch, let fileIndex, let fileName, let fileBytes, let fileSize, let totalBytes, let reason, let canBle) = state else { return }
    let canResume = !allowBleResume && pausedTransport == "lan" &&
      channels["lan"] == nil && channels["ble"] != nil && capabilities["ble"] != nil
    guard canResume != canBle else { return }
    state = .paused(
      batch: batch,
      fileIndex: fileIndex,
      fileName: fileName,
      fileBytes: fileBytes,
      fileSize: fileSize,
      totalBytes: totalBytes,
      reason: reason,
      canResumeOverBle: canResume
    )
    onEvent?(.paused(batch: batch, reason: reason, canResumeOverBle: canResume))
  }

  /// Sender-initiated handshake. The prefix hash proves the receiver's retained bytes are the ones
  /// this source would have sent; the receiver's answer is authoritative for the continue offset.
  func attemptResume() {
    if expirePausedIfNeeded() { return }
    guard case .paused(let batch, _, _, _, _, _, _, _) = state else { return }
    guard !receiving, resumeTask == nil, let channel = activeChannel, peerCompatible else { return }
    let transport = channel.descriptor.transport
    let allowed = transport == "lan" || pausedTransport != "lan" || allowBleResume
    guard allowed else { refreshPausedCapability(); return }
    guard claimResumeAttempt(channel.descriptor) else { return }
    let fileIndex = pausedFileIndex
    guard batch.files.indices.contains(fileIndex) else { return }
    let file = batch.files[fileIndex]
    let completedBefore = pausedCompletedBytes
    let operation = epoch
    let initialOffset = pausedFileOffset

    resumeTask = Task { [weak self] in
      guard let self else { return }
      defer { if self.epoch == operation { self.resumeTask = nil } }
      var offset = initialOffset
      var retriedOffset = false
      var restarted = false
      var accepted = false
      do {
        while !accepted {
          guard self.epoch == operation, !Task.isCancelled else { return }
          let prefix = try await self.filePrefixDigest(file, length: offset)
          guard self.epoch == operation, !Task.isCancelled else { return }
          let message = TransferMessage.resume(batch: batch.idString, file: file.idString, offset: offset, prefixHash: prefix)
          guard let request = try? message.encode(maximumChunkBytes: self.chunkLimit(channel.descriptor)) else {
            self.failTransfer(reason: "Failed encoding resume request")
            return
          }
          guard let status = await self.requestStatus(request, on: channel) else {
            return
          }
          guard self.epoch == operation, !Task.isCancelled else { return }
          switch status.number(3) {
          case 0:
            offset = max(0, min(status.number(2), file.size))
            accepted = true
          case 1:
            if retriedOffset {
              self.failTransfer(reason: "The other device keeps reporting a different transfer offset.")
              return
            }
            retriedOffset = true
            offset = max(0, min(status.number(2), file.size))
          case 2:
            if restarted {
              self.failTransfer(reason: "The retained file no longer matches. Send the files again.")
              return
            }
            restarted = true
            offset = 0
          default:
            return
          }
        }
        guard self.epoch == operation, !Task.isCancelled else { return }
        self.pauseTimerTask?.cancel(); self.pauseTimerTask = nil
        self.acquireSleepAssertion()
        self.resumeTask = nil
        self.state = .transferring(
          batch: batch,
          fileIndex: fileIndex + 1,
          fileName: file.name,
          fileBytes: offset,
          fileSize: file.size,
          totalBytes: completedBefore + offset,
          speedBps: 0
        )
        self.onEvent?(.resumed)
        let streamOperation = self.epoch
        self.transferTask = Task { [weak self] in
          guard let self, streamOperation == self.epoch, self.activeChannel != nil else { return }
          await self.streamBatchFrom(batch, startFileIndex: fileIndex, startOffset: offset, completedBefore: completedBefore, recovered: true)
        }
      } catch is CancellationError {
        return
      } catch {
        if self.epoch == operation, !Task.isCancelled {
          self.failTransfer(reason: "Cannot read \(file.name) to resume: \(error.localizedDescription)")
        }
      }
    }
  }

  /// Receiver-initiated continuation. The receiver hashes what it retained and asks the sender;
  /// the sender validates its own source prefix and, when it matches, starts streaming from the
  /// retained offset. The request follows the currently preferred channel, so a LAN that returns
  /// while the user is opting into Bluetooth wins instead of racing the sender.
  func requestPeerContinuation() {
    if expirePausedIfNeeded() { return }
    guard case .paused(let batch, _, _, _, _, _, _, _) = state, receiving,
      allowBleResume, resumeTask == nil, let channel = activeChannel, peerCompatible else { return }
    guard channel.descriptor.transport == "ble", claimResumeAttempt(channel.descriptor) else { return }
    let fileIndex = receiverCurrentFileIndex
    guard batch.files.indices.contains(fileIndex) else { return }
    let file = batch.files[fileIndex]
    let operation = epoch
    resumeTask = Task { [weak self] in
      guard let self else { return }
      var restarted = false
      defer {
        if self.epoch == operation {
          if self.isPaused { self.refreshPausedCapability() }
          self.resumeTask = nil
        }
      }
      loop: while true {
        guard self.epoch == operation, !Task.isCancelled else { return }
        guard let channel = self.activeChannel, self.peerCompatible,
          channel.descriptor.transport == "ble", let storage = self.receiverStorage else { break loop }
        let offset = max(0, min(self.receiverWrittenBytes, file.size))
        guard let prefix = try? await storage.prefixDigest(offset),
          self.epoch == operation, !Task.isCancelled,
          self.activeChannel?.descriptor == channel.descriptor else { break loop }
        let message = TransferMessage.resume(
          batch: batch.idString, file: file.idString, offset: offset, prefixHash: prefix)
        guard let request = try? message.encode(
          maximumChunkBytes: self.chunkLimit(channel.descriptor)) else { break loop }
        guard let status = await self.requestStatus(request, on: channel),
          self.epoch == operation, !Task.isCancelled else { break loop }
        switch status.number(3) {
        case 0:
          // The sender streams on the channel that carried the request. If the preferred channel
          // changed meanwhile, ask again there so both sides converge.
          guard self.activeChannel?.descriptor == channel.descriptor else { continue }
          guard self.isPaused else { return }
          self.pauseTimerTask?.cancel(); self.pauseTimerTask = nil
          self.lastAckedWrittenBytes = self.receiverWrittenBytes
          self.state = .transferring(
            batch: batch,
            fileIndex: fileIndex + 1,
            fileName: file.name,
            fileBytes: self.receiverWrittenBytes,
            fileSize: file.size,
            totalBytes: self.receiverTotalTransferred,
            speedBps: 0
          )
          self.onEvent?(.resumed)
          return
        case 2:
          guard !restarted else { break loop }
          restarted = true
          guard await self.resetReceiverFile(batch, file) else { break loop }
          if case .paused(let currentBatch, let pausedIndex, let pausedName, _, let pausedSize,
            _, let reason, let canBle) = self.state {
            self.state = .paused(
              batch: currentBatch,
              fileIndex: pausedIndex,
              fileName: pausedName,
              fileBytes: 0,
              fileSize: pausedSize,
              totalBytes: self.receiverTotalTransferred,
              reason: reason,
              canResumeOverBle: canBle
            )
          }
        default:
          break loop
        }
      }
    }
  }

  func requestStatus(_ request: Data, on channel: any SecuredChannel) async -> TransferMessage? {
    let operation = epoch
    let token = UUID()
    return await withCheckedContinuation { (continuation: CheckedContinuation<TransferMessage?, Never>) in
      let finish: (TransferMessage?) -> Void = { [weak self] message in
        guard let self, self.statusWaiterToken == token else { return }
        self.statusWaiter = nil
        self.statusWaiterToken = nil
        self.statusTimeoutTask?.cancel()
        self.statusTimeoutTask = nil
        // An accepted reply may precede local send completion; only abandonment cancels submission.
        if message == nil { self.statusSubmissionTask?.cancel() }
        self.statusSubmissionTask = nil
        continuation.resume(returning: message)
      }
      statusWaiter = finish
      statusWaiterToken = token
      statusTimeoutTask = Task { [weak self] in
        do { try await Task.sleep(for: self?.resumeTimeout ?? .seconds(15)) } catch { return }
        guard let self, self.epoch == operation else { return }
        finish(nil)
      }
      statusSubmissionTask = Task { [weak self] in
        guard let self else { return }
        do { try await self.sendWithBackpressure(request, on: channel, jobBound: false) }
        catch { finish(nil) }
      }
    }
  }

  func handleStatus(_ message: TransferMessage) {
    guard let batch = currentBatch, message.string(0) == batch.idString else { return }
    // The waiter belongs to whichever side initiated the handshake: the sender after its own
    // resume, or the receiver after a receiver-initiated Bluetooth continuation.
    let index = receiving ? receiverCurrentFileIndex : senderFileIndex
    guard batch.files.indices.contains(index),
      message.string(1) == batch.files[index].idString,
      (0...batch.files[index].size).contains(message.number(2)) else { return }
    if statusWaiter != nil, !receiving, message.number(3) == 0,
      (0...batch.files[index].size).contains(message.number(2)) {
      sendingFile = batch.files[index]; sentBytes = message.number(2)
    }
    statusWaiter?(message)
  }

  func abandonStatus() {
    let waiter = statusWaiter
    // The completion validates this token before releasing its suspended caller.
    waiter?(nil)
    statusWaiter = nil
    statusWaiterToken = nil
    statusTimeoutTask?.cancel(); statusTimeoutTask = nil
    statusSubmissionTask?.cancel(); statusSubmissionTask = nil
  }

  /// Receiver side of the handshake: verify the retained prefix, rebind to the sender's chosen
  /// channel and answer with the offset the sender must continue from.
  func handleResume(_ message: TransferMessage, on descriptor: ChannelDescriptor) async {
    let operation = epoch
    guard let channel = channels[descriptor.transport], channel.descriptor == descriptor else { return }
    _ = expirePausedIfNeeded()
    if currentBatch == nil, let deadline = receiptDeadline, pauseClock.now >= deadline {
      retainedFileResult = nil; retainedBatch = nil; receiptDeadline = nil
      if let store = recoveryStore {
        let previous = recoveryWrite
        recoveryWrite = Task {
          await previous?.value
          do { try await store.clear() }
          catch { NSLog("Transfer receipt cleanup failed: %@", error.localizedDescription) }
        }
      }
    }
    let batchId = message.string(0)
    let fileId = message.string(1)
    let offset = message.number(2)
    let prefix = message.bytes(3)

    let completedFile = retainedBatch.flatMap { $0.idString == batchId ? $0.files.first(where: { $0.idString == fileId }) : nil }
      ?? currentBatch.flatMap { receiving && $0.idString == batchId ? $0.files.prefix(receiverCurrentFileIndex).first(where: { $0.idString == fileId }) : nil }
    var retained = retainedFileResult
    if let proof = retained, let file = completedFile {
      retained = RetainedFileResult(batchId: batchId, fileId: fileId, fileSize: file.size,
        result: TransferMessage.fileResult(batch: batchId, file: fileId, result: 0, hash: file.sha256),
        peerId: proof.peerId, peerFingerprint: proof.peerFingerprint)
    }
    if let retained, retained.batchId == batchId, retained.fileId == fileId,
      retained.peerId == descriptor.peer.deviceId, retained.peerFingerprint == descriptor.peer.fingerprint {
      // The file was already verified before the channel died. Replaying its result lets the
      // sender skip the last-chunk wait instead of failing on a resume for a closed file.
      bindResumeChannel(channel)
      await replyStatus(channel, batch: batchId, file: fileId, bytes: retained.fileSize, state: 0)
      try? await sendWithBackpressure(retained.result.encode(), on: channel, jobBound: false)
      guard operation == epoch, channels[descriptor.transport]?.descriptor == descriptor else { return }
      continueAfterRetainedReplay()
      return
    }

    // A resume from the data receiver asks this device, the sender, to continue over the channel
    // the receiver chose. It uses the same kinds and is validated against our source.
    if !receiving {
      await handlePeerResume(batchId: batchId, fileId: fileId, offset: offset, prefix: prefix, channel: channel)
      return
    }

    guard let batch = currentBatch, batch.idString == batchId, receiving,
      isPaused || isTransferring else {
      await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: 4)
      return
    }
    guard let fileIndex = batch.files.firstIndex(where: { $0.idString == fileId }),
      fileIndex == receiverCurrentFileIndex else {
      await replyStatus(channel, batch: batchId, file: fileId, bytes: receiverWrittenBytes, state: 3)
      return
    }
    let file = batch.files[fileIndex]
    guard let storage = receiverStorage else {
      await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: finalizing ? 3 : 4)
      return
    }
    if offset > receiverWrittenBytes {
      await replyStatus(channel, batch: batchId, file: fileId, bytes: receiverWrittenBytes, state: 1)
      return
    }
    let matches: Bool
    do { matches = try await storage.matchesPrefix(offset, expected: prefix) }
    catch {
      await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: 3)
      return
    }
    guard operation == epoch, channels[descriptor.transport]?.descriptor == descriptor, receiverStorage === storage else { return }
    if !matches {
      guard await resetReceiverFile(batch, file) else {
        await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: 4)
        return
      }
      guard operation == epoch, channels[descriptor.transport]?.descriptor == descriptor else { return }
      bindResumeChannel(channel)
      await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: 2)
      return
    }
    bindResumeChannel(channel)
    pauseTimerTask?.cancel(); pauseTimerTask = nil
    acquireSleepAssertion()
    lastAckedWrittenBytes = receiverWrittenBytes
    state = .transferring(
      batch: batch,
      fileIndex: fileIndex + 1,
      fileName: file.name,
      fileBytes: receiverWrittenBytes,
      fileSize: file.size,
      totalBytes: receiverTotalTransferred,
      speedBps: 0
    )
    onEvent?(.resumed)
    await replyStatus(channel, batch: batchId, file: fileId, bytes: receiverWrittenBytes, state: 0)
    if receiverWrittenBytes == file.size { await finalizeReceiverFile(batch) }
  }

  func bindResumeChannel(_ channel: any SecuredChannel) {
    if finalizing { finalizationResumed = true }
    activeChannel = channel
    peerConnected = true
    peerCompatible = true
    peerMaxChunkBytes = 3072
    peerMaxWindow = 64
    if let capability = capabilities[channel.descriptor.transport] { applyCapability(capability) }
  }

  /// Sender side of a receiver-initiated continuation. The receiver asks over the channel it
  /// prefers; we prove our source still begins with its retained prefix and then stream the rest
  /// from its offset. A reliable LAN is not pulled down to BLE, but a stalled one yields.
  func handlePeerResume(
    batchId: String, fileId: String, offset: Int64, prefix: Data, channel: any SecuredChannel
  ) async {
    let lookup = epoch
    if resumeTask != nil || upgradeTask != nil {
      await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: 3)
      return
    }
    guard let batch = currentBatch, batch.idString == batchId else {
      await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: 4)
      return
    }
    guard let fileIndex = batch.files.firstIndex(where: { $0.idString == fileId }) else {
      await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: 3)
      return
    }
    let file = batch.files[fileIndex]
    let currentIndex: Int
    let paused: Bool
    switch state {
    case .paused: currentIndex = pausedFileIndex; paused = true
    case .transferring: currentIndex = senderFileIndex; paused = false
    default:
      await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: 4)
      return
    }
    guard fileIndex == currentIndex else {
      await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: 3)
      return
    }

    // A receiver can only ask us to leave LAN when its own LAN is gone. Give a freshly resumed
    // LAN stream a few seconds to start producing ACKs before treating it as stalled.
    if channel.descriptor.transport == "ble", !paused, activeChannel?.descriptor.transport == "lan" {
      let now = ProcessInfo.processInfo.systemUptime
      let acking = lastAckAt.map { now - $0 < 3 } ?? false
      let fresh = lastAckAt == nil && streamStartedAt.map { now - $0 < 3 } == true &&
        sentBytes > acknowledgedBytes
      if acking || fresh {
        await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: 3)
        return
      }
    }

    let sent = restoredSender ? file.size : max(0, min(sentBytes, file.size))
    guard offset >= 0, offset <= sent else {
      await replyStatus(channel, batch: batchId, file: fileId, bytes: sent, state: 1)
      return
    }
    let matches: Bool
    do { matches = try await filePrefixDigest(file, length: offset) == prefix }
    catch { await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: 4); return }
    guard lookup == epoch, channels[channel.descriptor.transport]?.descriptor == channel.descriptor, senderFileIndex == fileIndex else { return }
    if paused && isTransferring {
      await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: 3); return
    }
    if channel.descriptor.transport == "ble", activeChannel?.descriptor.transport == "lan",
      lastAckAt.map({ ProcessInfo.processInfo.systemUptime - $0 < 3 }) == true {
      await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: 3); return
    }
    guard matches else {
      await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: 2)
      return
    }

    let completedBefore = paused
      ? pausedCompletedBytes
      : batch.files.prefix(fileIndex).reduce(0) { $0 + $1.size }
    // Fence the current stream before binding the requested channel. The receiver already
    // validated its retained prefix; anything still in flight on the old transport is discarded
    // there once it rebinds.
    transferTask?.cancel(); transferTask = nil
    resumeTask?.cancel(); resumeTask = nil
    upgradeTask?.cancel(); upgradeTask = nil
    abandonStatus()
    fileResultContinuation?.resume(throwing: SessionFailure.cancelled)
    fileResultContinuation = nil
    resumeCredit()
    clearCapacityWaiters()
    pauseTimerTask?.cancel(); pauseTimerTask = nil
    epoch = UUID()
    let operation = epoch
    bindResumeChannel(channel)
    state = .transferring(
      batch: batch,
      fileIndex: fileIndex + 1,
      fileName: file.name,
      fileBytes: offset,
      fileSize: file.size,
      totalBytes: completedBefore + offset,
      speedBps: 0
    )
    onEvent?(.resumed)
    await replyStatus(channel, batch: batchId, file: fileId, bytes: offset, state: 0)
    guard operation == epoch, activeChannel?.descriptor == channel.descriptor else { return }
    transferTask = Task { [weak self] in
      guard let self, operation == self.epoch, self.activeChannel != nil else { return }
      await self.streamBatchFrom(batch, startFileIndex: fileIndex, startOffset: offset, completedBefore: completedBefore, recovered: true)
    }
  }

  /// Sender-side transport upgrade. A capable LAN channel arriving during a Bluetooth stream
  /// triggers the existing resume handshake; the receiver accepts while transferring, reports its
  /// actual written offset, and both sides switch without a visible pause.
  func maybeUpgradeToLan(_ descriptor: ChannelDescriptor) {
    guard descriptor.transport == "lan", !receiving, isTransferring else { return }
    guard let active = activeChannel, active.descriptor.transport == "ble",
      let lan = channels["lan"], lan.descriptor == descriptor, capabilities["lan"] != nil else { return }
    guard upgradeTask == nil, resumeTask == nil, statusWaiter == nil,
      let batch = currentBatch, batch.files.indices.contains(senderFileIndex) else { return }
    let fileIndex = senderFileIndex
    let file = batch.files[fileIndex]
    // At the file-result boundary the stream is idle; wait for the next file's start.
    guard fileResultContinuation == nil, sentBytes < file.size else { return }
    let completedBefore = batch.files.prefix(fileIndex).reduce(0) { $0 + $1.size }
    let offset = max(0, min(acknowledgedBytes, file.size))
    let streamEpoch = epoch
    upgradeTask = Task { [weak self] in
      guard let self else { return }
      defer { if self.epoch == streamEpoch { self.upgradeTask = nil } }
      guard let prefix = try? await self.filePrefixDigest(file, length: offset),
        self.epoch == streamEpoch, !Task.isCancelled else { return }
      let message = TransferMessage.resume(
        batch: batch.idString, file: file.idString, offset: offset, prefixHash: prefix)
      guard let request = try? message.encode(
        maximumChunkBytes: self.chunkLimit(lan.descriptor)) else { return }
      let status = await self.requestStatus(request, on: lan)
      guard self.epoch == streamEpoch, !Task.isCancelled else { return }
      guard let status else {
        // Ambiguous: the receiver may already have rebound. Pause and let the preferred-channel
        // policy resume deterministically instead of streaming into a lost stream.
        guard self.isTransferring else { return }
        self.pauseTransfer(batch: batch, transport: active.descriptor.transport)
        self.selectPreferredChannel()
        return
      }
      let code = status.number(3)
      guard code == 0 || code == 2 else { return } // The receiver kept the Bluetooth stream.
      let startOffset = code == 2 ? 0 : max(0, min(status.number(2), file.size))
      guard self.epoch == streamEpoch, self.isTransferring else { return }
      self.transferTask?.cancel(); self.transferTask = nil
      self.fileResultContinuation?.resume(throwing: SessionFailure.cancelled)
      self.fileResultContinuation = nil
      self.resumeCredit()
      self.clearCapacityWaiters()
      self.upgradeTask = nil
      self.epoch = UUID()
      let operation = self.epoch
      self.bindResumeChannel(lan)
      self.state = .transferring(
        batch: batch,
        fileIndex: fileIndex + 1,
        fileName: file.name,
        fileBytes: startOffset,
        fileSize: file.size,
        totalBytes: completedBefore + startOffset,
        speedBps: 0
      )
      self.onEvent?(.resumed)
      self.transferTask = Task { [weak self] in
        guard let self, operation == self.epoch, self.activeChannel != nil else { return }
        await self.streamBatchFrom(batch, startFileIndex: fileIndex, startOffset: startOffset, completedBefore: completedBefore, recovered: true)
      }
    }
  }

  /// When the replayed file was the one before the receiver's current file, the sender resumes the
  /// next file at zero; the receiver must already be accepting it, with no second handshake.
  func continueAfterRetainedReplay() {
    guard receiving, isPaused, let batch = currentBatch,
      receiverStorage != nil, receiverWrittenBytes == 0,
      batch.files.indices.contains(receiverCurrentFileIndex) else { return }
    let file = batch.files[receiverCurrentFileIndex]
    if retainedFileResult?.fileId == file.idString { return }
    pauseTimerTask?.cancel(); pauseTimerTask = nil
    lastAckedWrittenBytes = 0
    state = .transferring(
      batch: batch,
      fileIndex: receiverCurrentFileIndex + 1,
      fileName: file.name,
      fileBytes: 0,
      fileSize: file.size,
      totalBytes: receiverTotalTransferred,
      speedBps: 0
    )
    onEvent?(.resumed)
  }
}
