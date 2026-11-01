// SPDX-License-Identifier: GPL-3.0-or-later
// Routes authenticated channels and transfer messages while keeping channel lifecycle with the feature owner.
import Foundation

extension MacTransferModel {
  func maintainProgressUpdates() {
    guard case .transferring(_, _, _, _, _, let total, _) = state else {
      progressTask?.cancel(); progressTask = nil; progressEpoch = nil
      return
    }
    guard progressTask == nil || progressEpoch != epoch else { return }
    progressTask?.cancel()
    progressEpoch = epoch
    progressRate = TransferRate()
    progressSampleAt = ProcessInfo.processInfo.systemUptime
    progressSpeed = 0
    _ = progressRate.add(total, at: progressSampleAt)
    let operation = epoch
    progressTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        guard let self, self.epoch == operation else { return }
        self.refreshProgress()
      }
    }
  }

  func sampleProgress(_ total: Int64, at now: TimeInterval) -> Double {
    if now - progressSampleAt >= 0.25 {
      progressSpeed = progressRate.add(total, at: now)
      progressSampleAt = now
    }
    return progressSpeed
  }

  func refreshProgress() {
    guard case .transferring(let batch, _, _, _, _, _, _) = state else { return }
    let index = receiving ? receiverCurrentFileIndex : senderFileIndex
    guard batch.files.indices.contains(index) else { return }
    let file = batch.files[index]
    let written = receiving ? receiverWrittenBytes : acknowledgedBytes
    let total = batch.files.prefix(index).reduce(Int64(0)) { $0 + $1.size } + written
    let speed = sampleProgress(total, at: ProcessInfo.processInfo.systemUptime)
    state = .transferring(batch: batch, fileIndex: index + 1, fileName: file.name,
      fileBytes: written, fileSize: file.size, totalBytes: total, speedBps: speed)
  }

  func chunkLimit(_ descriptor: ChannelDescriptor?) -> Int {
    descriptor?.transport == "lan" && (descriptor?.maximumDataBytes ?? 4000) >= 524416 ? 524288 : descriptor?.transport == "lan" && (descriptor?.maximumDataBytes ?? 4000) >= 262144 ? 262016 : 3072
  }

  var isPaused: Bool {
    if case .paused = state { return true }
    return false
  }

  func selectPreferredChannel(preparingRoute: Bool = false) {
    // A live batch remains bound to its channel generation. A paused batch, by contrast, must
    // adopt a newly secured channel so the retained prefix can continue there.
    let canRebind = !isBusy || isPaused || preparingRoute
    guard activeChannel == nil || canRebind else { return }
    let preferred = ["lan", "ble"].first(where: { channels[$0] != nil && capabilities[$0] != nil })
      .flatMap { channels[$0] } ?? channels["lan"] ?? channels["ble"]
    activeChannel = preferred
    peerConnected = preferred != nil
    peerCompatible = false
    peerMaxChunkBytes = 3072
    peerMaxWindow = 64
    clearOfferAssembly()
    if let preferred, let capability = capabilities[preferred.descriptor.transport] { applyCapability(capability) }
    refreshPausedCapability()
    if resumeInterruptedOffer() { return }
    if isPaused, activeChannel != nil, peerCompatible {
      // The sender drives LAN auto-resume; the receiver only asks after an explicit opt-in.
      if receiving { if allowBleResume { requestPeerContinuation() } } else { attemptResume() }
    }
  }

  func applyCapability(_ message: TransferMessage) {
    peerCompatible = true
    let localLimit = Int64(chunkLimit(activeChannel?.descriptor))
    let negotiatedLimit: Int64 = message.number(0) == 4 ? localLimit : message.number(0) == 3 ? min(262016, localLimit) : message.number(0) == 2 ? min(131072, localLimit) : 3072
    peerMaxChunkBytes = min(message.number(1), negotiatedLimit)
    peerMaxWindow = min(message.number(2), activeChannel?.descriptor.transport == "ble" ? 4 : peerMaxChunkBytes > 3072 ? 8 : 64)
  }

  func clearCapacityWaiters() {
    let waiters = capacityWaiters
    capacityWaiters.removeAll()
    capacityRevision += 1
    for waiter in waiters.values {
      waiter()
    }
  }

  func processMessage(_ message: TransferMessage, peerName: String, on descriptor: ChannelDescriptor) async {
    switch message.kind {
    case 2: // offer
      handleOffer(message, peerName: peerName, on: descriptor)

    case 3: // accept
      handleAccept(message)

    case 4: // reject
      handleReject(message)

    case 6: // ack
      handleAck(message)

    case 7:
      guard let batch = currentBatch, let file = sendingFile,
        message.string(0) == batch.idString, message.string(1) == file.idString,
        message.number(2) != 0 || (sentBytes == file.size && message.bytes(3) == file.sha256) else { return }
      if message.number(2) == 0 { pauseExpiresAt = nil; pauseDeadline = nil }
      if let waiter = fileResultContinuation { fileResultContinuation = nil; waiter.resume(returning: message) }
      else { receivedFileResult = message }
    case 8:
      // File results are authoritative; a batch result cannot bypass storage verification.
      break
    case 10, 11:
      // Routed before the active-channel guard so a new channel can take over a paused batch.
      break
    case 9:
      guard let batch = currentBatch, message.string(0) == batch.idString,
        message.string(1).isEmpty || message.string(1) == sendingFile?.idString ||
        batch.files.indices.contains(receiverCurrentFileIndex) && message.string(1) == batch.files[receiverCurrentFileIndex].idString else { return }
      cancelTransfer(local: false)

    default:
      break
    }
  }

  func sendWithBackpressure(_ data: Data, on selectedChannel: (any SecuredChannel)? = nil, jobBound: Bool = true) async throws {
    guard let channel = selectedChannel ?? activeChannel else { throw SessionFailure.cancelled }
    let operation = epoch
    while true {
      try Task.checkCancellation()
      guard (!jobBound || operation == epoch), channels[channel.descriptor.transport]?.descriptor == channel.descriptor else { throw SessionFailure.cancelled }
      let revision = capacityRevision
      // Admission stays cancellable; the session protects records only after nonce ownership.
      do { try await channel.sendData(data); return }
      catch is SessionBackpressure {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          if revision != capacityRevision { continuation.resume(); return }
          let id = UUID()
          var resumed = false
          var timeout: Task<Void, Never>?
          let resumeOnce = {
            guard !resumed else { return }; resumed = true; timeout?.cancel(); continuation.resume()
          }
          capacityWaiters[id] = resumeOnce
          timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard !resumed else { return }
            resumed = true
            // Remove only this suspended submission; no periodic capacity polling.
            self?.capacityWaiters[id] = nil
            continuation.resume(throwing: SessionFailure.expired)
            self?.clearCapacityWaiters()
          }
        }
      }
    }
  }

  func awaitLan(operation: UUID) async {
    guard channels["lan"] == nil || capabilities["lan"] == nil else { return }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled, operation == epoch else { continuation.resume(); return }
        var timeout: Task<Void, Never>?
        rendezvousWait = { [weak self] in
          guard let self, self.rendezvousWait != nil else { return }
          self.rendezvousWait = nil
          timeout?.cancel()
          continuation.resume()
        }
        timeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(3)) } catch { return }
          if self?.epoch == operation { self?.rendezvousWait?() }
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        if self?.epoch == operation { self?.rendezvousWait?() }
      }
    }
  }
}
