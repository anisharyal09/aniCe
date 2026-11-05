// SPDX-License-Identifier: GPL-3.0-or-later
// Prepares and streams outgoing file batches under peer credit and result correlation.

import Foundation
import CryptoKit

final class TransferFileAccessLease {
  private var scopedURLs: [URL] = []

  init(urls: [URL]) {
    for url in urls where url.startAccessingSecurityScopedResource() {
      scopedURLs.append(url)
    }
  }

  func release() {
    let urls = scopedURLs
    scopedURLs.removeAll()
    for url in urls { url.stopAccessingSecurityScopedResource() }
  }

  deinit { release() }
}

extension MacTransferModel {
  func sendFiles(
    urls: [URL], reviewedPeer: DeviceIdentity? = nil, fileAccess: TransferFileAccessLease? = nil
  ) async {
    let policy: TransferTransportPolicy = reviewedPeer == nil ? .preferAvailable : .preferLanWithChoice
    await sendFiles(urls: urls, recipient: reviewedPeer.map { TransferRecipient(peer: $0) },
      transportPolicy: policy, fileAccess: fileAccess)
  }

  func sendFiles(
    urls: [URL], recipient: TransferRecipient?, transportPolicy: TransferTransportPolicy,
    dropReservation: UUID? = nil, fileAccess: TransferFileAccessLease? = nil
  ) async {
    if let dropReservation {
      guard self.dropReservation == dropReservation else { return }
    } else {
      guard !isBusy else { return }
    }
    guard !Task.isCancelled, preparation == nil, transferTask == nil else {
      if let dropReservation {
        failDrop(reservation: dropReservation, message: "File drop was cancelled. Drop the files again to retry.")
      }
      return
    }
    guard (1...128).contains(urls.count) else {
      if let dropReservation {
        failDrop(reservation: dropReservation, message: "Choose 1 to 128 files. No files were sent.")
      } else {
        state = .failed(reason: "Transfer batch must contain 1 to 128 files")
      }
      return
    }
    selectPreferredChannel()
    let activePeer = activeChannel?.descriptor.peer
    let pinnedRecipient = recipient ?? activePeer.map(TransferRecipient.init)
    if let recipient, activePeer.map({ recipient.matches($0) }) != true {
      if transportPolicy != .preferAvailable {
        retainPendingRouteSelection(urls: urls, recipient: recipient, fileAccess: fileAccess,
          message: "Reconnect to \(recipient.deviceName) before sending. No files were sent.")
      } else {
        failTransfer(reason: "The connected device changed. No files were sent. Choose the files again for the current device.")
      }
      return
    }
    if transportPolicy != .preferAvailable, pinnedRecipient == nil {
      failTransfer(reason: "Connect the selected phone before sending files.")
      return
    }
    let operation = epoch
    // Reserve the job and its peer before rendezvous or identity reads can suspend.
    preparing = true
    if dropReservation != nil { self.dropReservation = nil }
    dropFileAccess = fileAccess
    transferPeerDeviceId = pinnedRecipient?.deviceId
    transferPeerFingerprint = pinnedRecipient?.fingerprint
    defer { if operation == epoch { preparing = false } }
    let requiredTransport: String?
    switch transportPolicy {
    case .preferAvailable: requiredTransport = nil
    case .preferLanWithChoice: requiredTransport = "lan"
    case .bluetooth: requiredTransport = "ble"
    }
    switch transportPolicy {
    case .preferAvailable:
      if activeChannel?.descriptor.transport != "lan", onLanRequired() {
        await awaitLan(operation: operation)
      }
    case .preferLanWithChoice:
      guard let pinnedRecipient else {
        failTransfer(reason: "Connect the selected phone before sending files.")
        return
      }
      if !hasReadyChannel("lan", for: pinnedRecipient) {
        if onLanRequired() { await awaitLan(operation: operation) }
        guard operation == epoch else { return }
        guard !Task.isCancelled else { cancelTransfer(); return }
        guard hasReadyChannel("lan", for: pinnedRecipient) else {
          retainPendingRouteSelection(urls: urls, recipient: pinnedRecipient,
            fileAccess: fileAccess,
            message: "The local network isn’t ready. Choose Retry, send over Bluetooth, or cancel.")
          return
        }
      }
      preferBluetoothForCurrentTransfer = false
      selectPreferredChannel(preparingRoute: true, preferredTransport: "lan")
    case .bluetooth:
      guard let pinnedRecipient else {
        failTransfer(reason: "Connect the selected phone before sending files.")
        return
      }
      guard hasReadyChannel("ble", for: pinnedRecipient) else {
        retainPendingRouteSelection(urls: urls, recipient: pinnedRecipient,
          fileAccess: fileAccess,
          message: "Bluetooth is unavailable. Retry the local network or cancel.")
        return
      }
      preferBluetoothForCurrentTransfer = true
      selectPreferredChannel(preparingRoute: true, preferredTransport: "ble")
    }
    guard operation == epoch else { return }
    guard !Task.isCancelled else { cancelTransfer(); return }
    // Keep the user's route choice fixed while hashing; a late LAN channel must not auto-fallback.
    selectPreferredChannel(preparingRoute: true, preferredTransport: requiredTransport)
    guard let initialChannel = activeChannel, peerConnected else {
      failTransfer(reason: "No secured local-network or Bluetooth connection")
      return
    }
    // Rendezvous can replace the active channel while this operation is suspended.
    if let pinnedRecipient, !pinnedRecipient.matches(initialChannel.descriptor.peer) {
      failTransfer(reason: "The connected device changed. No files were sent. Choose the files again for the current device.")
      return
    }
    guard peerCompatible else { failTransfer(reason: "This peer has not advertised file transfer support"); return }
    if let identity = recoveryIdentity, recoveryStore != nil {
      do {
        let local = try await identity.publicIdentity().fingerprint
        guard operation == epoch else { return }
        recoveryLocal = local
      } catch { if operation == epoch { preparing = false; failTransfer(reason: "Cannot access transfer recovery identity") }; return }
    }
    transferPeerDeviceId = initialChannel.descriptor.peer.deviceId
    transferPeerFingerprint = initialChannel.descriptor.peer.fingerprint
    recoveryPeer = initialChannel.descriptor
    let work = Task.detached(priority: .utility) { () throws -> ([TransferFile], Int64) in
      var files: [TransferFile] = []
      var total: Int64 = 0
      for url in urls {
        try Task.checkCancellation()
        let name = url.lastPathComponent
        guard (1...255).contains(name.utf8.count), name == name.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.contains("/"), !name.contains("\\"), !name.contains("\0"), name != ".", name != "..",
          name.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { throw TransferWireError.malformed }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
          let size = attributes[.size] as? Int64 else { throw CocoaError(.fileReadUnknown) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256(), read: Int64 = 0
        while true {
          try Task.checkCancellation()
          let chunk = try handle.read(upToCount: 262144) ?? Data()
          if chunk.isEmpty { break }
          hasher.update(data: chunk); read += Int64(chunk.count)
        }
        guard read == size else { throw CocoaError(.fileReadCorruptFile) }
        let next = total.addingReportingOverflow(size)
        guard !next.overflow else { throw TransferWireError.malformed }
        total = next.partialValue
        files.append(TransferFile(id: UUID(), name: name, size: size, sha256: Data(hasher.finalize()), localURL: url))
      }
      return (files, total)
    }
    preparation = work
    let files: [TransferFile], totalBytes: Int64
    do {
      (files, totalBytes) = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    } catch {
      if operation == epoch { preparing = false; preparation = nil; failTransfer(reason: "File preparation failed: \(error.localizedDescription)") }
      return
    }
    guard operation == epoch else { return }
    guard !Task.isCancelled else { cancelTransfer(); return }
    preparation = nil; preparing = false

    // Recheck the chosen route after hashing, which may take longer than the LAN rendezvous.
    if let requiredTransport, !hasReadyChannel(requiredTransport, for: pinnedRecipient) {
      let message = requiredTransport == "lan"
        ? "The local network disconnected before sending. Choose Retry, send over Bluetooth, or cancel."
        : "Bluetooth disconnected before sending. No files were sent. Retry or cancel."
      guard let pinnedRecipient else {
        failTransfer(reason: "Connect the selected phone before sending files.")
        return
      }
      retainPendingRouteSelection(urls: urls, recipient: pinnedRecipient,
        fileAccess: fileAccess, message: message)
      return
    }
    selectPreferredChannel(preparingRoute: true, preferredTransport: requiredTransport)
    guard let channel = activeChannel, peerConnected,
      channel.descriptor.peer.deviceId == initialChannel.descriptor.peer.deviceId,
      channel.descriptor.peer.fingerprint == initialChannel.descriptor.peer.fingerprint else {
      failTransfer(reason: "No secured local-network or Bluetooth connection")
      return
    }
    guard peerCompatible else { failTransfer(reason: "This peer has not advertised file transfer support"); return }

    let batchId = UUID()
    let batch = TransferBatch(id: batchId, files: files, totalBytes: totalBytes, peerName: channel.descriptor.peer.deviceName)
    currentBatch = batch
    receiving = false
    transferPeerDeviceId = channel.descriptor.peer.deviceId
    transferPeerFingerprint = channel.descriptor.peer.fingerprint
    retainedFileResult = nil
    state = .waitingForPeerApproval(batch: batch)
    acquireSleepAssertion()

    if activeChannel?.descriptor != channel.descriptor {
      pauseOffer(.waitingForPeerApproval(batch: batch), descriptor: channel.descriptor)
      selectPreferredChannel()
    } else { await sendOfferBatch(batch, channel: channel) }
  }

  func hasReadyChannel(_ transport: String, for recipient: TransferRecipient?) -> Bool {
    guard let channel = channels[transport], capabilities[transport] != nil else { return false }
    return recipient.map { $0.matches(channel.descriptor.peer) } ?? true
  }

  func retainPendingRouteSelection(
    urls: [URL], recipient: TransferRecipient, fileAccess: TransferFileAccessLease?, message: String
  ) {
    // A pending selection pins both the destination and its security-scoped file access.
    pendingRouteSelection = PendingTransferRouteSelection(
      urls: urls, recipient: recipient, fileAccess: fileAccess, message: message)
    dropReservation = nil
    preparing = false
    dropFileAccess = fileAccess
    transferPeerDeviceId = recipient.deviceId
    transferPeerFingerprint = recipient.fingerprint
    dropStatus = message
  }

  var canSendPendingOverBluetooth: Bool {
    guard let pendingRouteSelection else { return false }
    return hasReadyChannel("ble", for: pendingRouteSelection.recipient)
  }

  var pendingRouteStatus: String {
    guard let selection = pendingRouteSelection else { return "" }
    if hasReadyChannel("lan", for: selection.recipient) {
      return "The local network is ready. Retry to send these files."
    }
    if !canSendPendingOverBluetooth {
      return "Waiting for \(selection.recipient.deviceName) to reconnect. Retry or cancel."
    }
    return selection.message
  }

  func retryPendingRouteSelection() async {
    guard let selection = pendingRouteSelection else { return }
    pendingRouteSelection = nil
    dropStatus = nil
    await sendFiles(urls: selection.urls, recipient: selection.recipient,
      transportPolicy: .preferLanWithChoice, fileAccess: selection.fileAccess)
  }

  func sendPendingRouteOverBluetooth() async {
    guard canSendPendingOverBluetooth, let selection = pendingRouteSelection else { return }
    pendingRouteSelection = nil
    dropStatus = nil
    await sendFiles(urls: selection.urls, recipient: selection.recipient,
      transportPolicy: .bluetooth, fileAccess: selection.fileAccess)
  }

  func cancelPendingRouteSelection() {
    guard let selection = pendingRouteSelection else { return }
    pendingRouteSelection = nil
    selection.fileAccess?.release()
    dropFileAccess?.release()
    dropFileAccess = nil
    dropReservation = nil
    transferPeerDeviceId = nil
    transferPeerFingerprint = nil
    preferBluetoothForCurrentTransfer = false
    dropStatus = nil
    state = .cancelled
  }

  func sendOfferBatch(_ batch: TransferBatch, channel: any SecuredChannel) async {
    let operation = epoch
    let files = batch.files, totalBytes = batch.totalBytes

    // Send offer slices
    let totalFiles = Int64(files.count)
    let totalSlices = Int64((files.count + 7) / 8)
    for sliceIdx in 0..<Int(totalSlices) {
      guard operation == epoch, activeChannel?.descriptor == channel.descriptor else { return }
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
          if operation == epoch { failTransfer(reason: "Failed sending offer: \(error.localizedDescription)") }
          return
        }
      }
    }
  }

  func handleAccept(_ message: TransferMessage) {
    guard case .waitingForPeerApproval(let batch) = state,
          message.string(0) == batch.idString else { return }

    guard transferTask == nil, let channel = activeChannel else { return }
    let operation = epoch
    if offerReplayed {
      offerReplayed = false
      senderFileIndex = 0; acknowledgedBytes = 0; sendingFile = batch.files[0]
      pauseTransfer(batch: batch, transport: channel.descriptor.transport)
      selectPreferredChannel()
      return
    }
    transferTask = Task {
      guard operation == epoch, activeChannel?.descriptor == channel.descriptor else { return }
      await streamAcceptedBatch(batch)
    }
  }

  func streamAcceptedBatch(_ batch: TransferBatch) async {
    await streamBatchFrom(batch, startFileIndex: 0, startOffset: 0, completedBefore: 0)
  }

  /// Streams from `startFileIndex` at `startOffset`, where the receiver already retains
  /// `startOffset` bytes of that file and `completedBefore` complete bytes precede it.
  func streamBatchFrom(_ batch: TransferBatch, startFileIndex: Int, startOffset: Int64, completedBefore: Int64, recovered: Bool = false) async {
    guard activeChannel != nil, batch.files.indices.contains(startFileIndex) else { return }
    let operation = epoch
    let initialOffset = max(0, min(startOffset, batch.files[startFileIndex].size))
    var totalTransferred = completedBefore + initialOffset
    var lastUiUpdate: TimeInterval = 0

    for fileIndex in startFileIndex..<batch.files.count {
      guard operation == epoch else { return }
      restoredSender = false
      let file = batch.files[fileIndex]
      var initial = fileIndex == startFileIndex ? initialOffset : 0
      senderFileIndex = fileIndex
      sendingFile = file; sentBytes = initial
      acknowledgedBytes = initial
      state = .transferring(batch: batch, fileIndex: fileIndex + 1, fileName: file.name,
        fileBytes: initial, fileSize: file.size, totalBytes: totalTransferred, speedBps: 0)
      if recovered || file.size == 0, fileIndex > startFileIndex, let channel = activeChannel {
        let request = TransferMessage.resume(batch: batch.idString, file: file.idString, offset: 0,
          prefixHash: Data(SHA256.hash(data: Data())))
        guard let encoded = try? request.encode() else { failTransfer(reason: "Cannot encode transfer recovery request"); return }
        let status = await requestStatus(encoded, on: channel)
        guard operation == epoch else { return }
        guard let status, status.number(3) == 0, (0...file.size).contains(status.number(2)) else {
          pauseTransfer(batch: batch, transport: channel.descriptor.transport); return
        }
        initial = status.number(2); acknowledgedBytes = initial; sentBytes = initial
        totalTransferred = batch.files.prefix(fileIndex).reduce(0) { $0 + $1.size } + initial
        state = .transferring(batch: batch, fileIndex: fileIndex + 1, fileName: file.name,
          fileBytes: initial, fileSize: file.size, totalBytes: totalTransferred, speedBps: 0)
      }
      checkpoint(force: true)
      await recoveryWrite?.value
      guard operation == epoch else { return }
      guard let url = file.localURL else {
        failTransfer(reason: "Failed reading local file \(file.name)")
        return
      }

      let source: TransferSendStorage
      do { source = try await TransferSendStorage.open(url, skipping: initial, close: closeSource) }
      catch { if operation == epoch { failTransfer(reason: "Cannot open source file") }; return }
      guard operation == epoch else { await source.close(); return }

      sendingFile = file
      senderFileIndex = fileIndex
      // A result that arrived just before this file was re-entered belongs to this file.
      if let pending = receivedFileResult, pending.string(0) != batch.idString || pending.string(1) != file.idString {
        receivedFileResult = nil
      }
      sentBytes = initial
      acknowledgedBytes = initial
      lastAckAt = nil
      let startedAt = ProcessInfo.processInfo.systemUptime
      streamStartedAt = startedAt
      sendWindow = TransferSendWindow(maximumChunk: peerMaxChunkBytes, maximumWindow: peerMaxWindow,
        lan: activeChannel?.descriptor.transport == "lan", started: startedAt)
      NSLog("aniCe transfer source: transport=%@ chunk=%lld credit=%lld maxChunk=%lld window=%lld",
        activeChannel?.descriptor.transport ?? "none", senderChunkBytes, sendCreditBytes, peerMaxChunkBytes, peerMaxWindow)
      var fileBytesSent: Int64 = initial
      // A LAN capability that arrived while the previous file was finalizing is retried here,
      // at the new file's start, where the stream is no longer waiting on a file result.
      if !receiving, let lan = channels["lan"] { maybeUpgradeToLan(lan.descriptor) }
      var upgradeChecked = false

      while fileBytesSent < file.size {
        while true {
          let previousChunk = senderChunkBytes
          let previousCredit = sendCreditBytes
          sendWindow?.advance()
          if previousChunk != senderChunkBytes || previousCredit != sendCreditBytes {
            NSLog("aniCe transfer send window: chunk=%lld credit=%lld", senderChunkBytes, sendCreditBytes)
          }
          if hasSendCredit { break }
          await withCheckedContinuation { cont in
            if self.hasSendCredit {
              cont.resume()
            } else {
              self.creditResume = { cont.resume() }
            }
          }
        }
        guard !Task.isCancelled, operation == epoch, self.activeChannel != nil else {
          await source.close()
          return
        }

        let chunkSize = min(Int(senderChunkBytes), Int(file.size - fileBytesSent))
        let encoded: Data
        do {
          encoded = try await source.readChunk(chunkSize, batch: batch.idString, file: file.idString,
            offset: fileBytesSent, maximumChunk: chunkLimit(activeChannel?.descriptor))
        }
        catch { await source.close(); if operation == epoch { failTransfer(reason: "Source read failed") }; return }
        guard operation == epoch, !Task.isCancelled else { await source.close(); return }

        do {
          sendWindow?.beginSubmission(ProcessInfo.processInfo.systemUptime, windowEmpty: sentBytes == acknowledgedBytes)
          sentBytes += Int64(chunkSize)
          try await sendWithBackpressure(encoded)
          guard operation == epoch else { await source.close(); return }
          fileBytesSent += Int64(chunkSize)
          totalTransferred += Int64(chunkSize)

          let now = ProcessInfo.processInfo.systemUptime
          if now - lastUiUpdate >= 0.1 || fileBytesSent == file.size {
            lastUiUpdate = now
            let confirmed = totalTransferred - fileBytesSent + acknowledgedBytes
            let speed = sampleProgress(confirmed, at: now)

            self.state = .transferring(
              batch: batch,
              fileIndex: fileIndex + 1,
              fileName: file.name,
              fileBytes: acknowledgedBytes,
              fileSize: file.size,
              totalBytes: confirmed,
              speedBps: speed
            )
          }
          if !upgradeChecked {
            upgradeChecked = true
            if !receiving, let lan = channels["lan"] { maybeUpgradeToLan(lan.descriptor) }
          }
        } catch {
          await source.close()
          if !Task.isCancelled && operation == epoch { failTransfer(reason: "Failed sending chunk: \(error.localizedDescription)") }
          return
        }
      }

      await source.close()
      guard operation == epoch, !Task.isCancelled else { return }

      // Wait for file-result from receiver
      let fileResult: TransferMessage
      do {
        if let pending = receivedFileResult { fileResult = pending; receivedFileResult = nil }
        else {
          let operation = epoch
          let deadline = Task { [weak self] in
            do { try await Task.sleep(for: self?.confirmationTimeout ?? .seconds(30)) } catch { return }
            guard let self, self.epoch == operation else { return }
            self.fileResultContinuation?.resume(throwing: SessionFailure.expired)
            self.fileResultContinuation = nil
          }
          defer { deadline.cancel() }
          fileResult = try await withCheckedThrowingContinuation { self.fileResultContinuation = $0 }
        }
      } catch { if !Task.isCancelled && operation == epoch { pauseOnConfirmationTimeout() }; return }
      guard operation == epoch else { return }
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
    // Final submission can suspend while a replacement batch acquires this owner.
    guard operation == epoch else { return }
    state = .completed(batchId: batch.id, fileCount: batch.files.count, totalBytes: batch.totalBytes)
    let count = batch.files.count
    let bytes = batch.totalBytes
    let wasReceiving = receiving
    cleanupActiveTransfer()
    if wasReceiving { onEvent?(.completed(fileCount: count, totalBytes: bytes)) }
  }

  func handleAck(_ message: TransferMessage) {
    guard let batch = currentBatch, let file = sendingFile,
      message.string(0) == batch.idString, message.string(1) == file.idString else { return }
    let written = message.number(2)
    guard written >= acknowledgedBytes, written <= sentBytes, written <= file.size else { return }
    if written > acknowledgedBytes {
      pauseExpiresAt = nil; pauseDeadline = nil
      sendWindow?.acknowledged(ProcessInfo.processInfo.systemUptime, fullyConfirmed: written == sentBytes)
    }
    acknowledgedBytes = written
    lastAckAt = ProcessInfo.processInfo.systemUptime
    checkCreditAndResume()
  }

  func resumeCredit() {
    // Detach before waking so cleanup cannot clear a successor's credit wait.
    let waiting = creditResume
    creditResume = nil
    waiting?()
  }

  func checkCreditAndResume() {
    if hasSendCredit { resumeCredit() }
  }

  func handleReject(_ message: TransferMessage) {
    guard case .waitingForPeerApproval(let batch) = state,
          message.string(0) == batch.idString else { return }
    state = .rejected(batchId: batch.id, reason: message.number(1))
    cleanupActiveTransfer()
  }
}

// MARK: - Credit window

// Reduced LAN chunks need immediate credit to keep the sender's smaller pipeline supplied.
func transferAckThreshold(maximumChunk: Int64, maximumWindow: Int64, chunkBytes: Int64) -> Int64 {
  if maximumChunk <= 3072 { return maximumChunk * min(8, max(1, maximumWindow / 2)) }
  let chunk = min(maximumChunk, chunkBytes)
  return chunk * (maximumChunk > 4096 && chunk < maximumChunk ? 1 : max(1, maximumWindow / 4))
}

// Bounds unacknowledged LAN bytes before allowing the negotiated high-throughput window.
struct TransferSendWindow {
  let maximumChunk: Int64
  let maximumWindow: Int64
  let lan: Bool
  private var probing: Bool
  private var probeSubmitted = false
  private var constrained = false
  private var lastAcknowledgedAt: TimeInterval
  private var probeStartedAt: TimeInterval
  private var reprobe = false
  private var drainRequested = false
  private var draining = false
  private var decision: Bool?
  init(maximumChunk: Int64, maximumWindow: Int64, lan: Bool, started: TimeInterval) {
    self.maximumChunk = maximumChunk; self.maximumWindow = maximumWindow; self.lan = lan
    probing = lan && maximumChunk > 4096
    lastAcknowledgedAt = started
    probeStartedAt = started
  }
  // Sustained fallback amortizes live per-record validation under a 128-KiB fallback backlog cap.
  var chunkBytes: Int64 {
    if probing { return min(4096, maximumChunk) }
    return constrained ? min(65536, maximumChunk) : maximumChunk
  }
  var creditBytes: Int64 { chunkBytes * (probing || draining ? 1 : constrained ? min(2, maximumWindow) : maximumWindow) }
  // Source IO and encoding precede submission and cannot measure the path's acknowledgement delay.
  mutating func beginSubmission(_ now: TimeInterval, windowEmpty: Bool = false) {
    if probing && !probeSubmitted {
      lastAcknowledgedAt = now
      probeStartedAt = now
      probeSubmitted = true
    } else if !probing && windowEmpty {
      if constrained && ((now - lastAcknowledgedAt) * 1_000_000_000).rounded() > 100_000_000 {
        // Source idle time must not consume the constrained path's recovery interval.
        probeStartedAt = now
      }
      lastAcknowledgedAt = now
    }
  }
  // Only advancing, correlated ACKs reach this method; duplicates cannot qualify a fast path.
  mutating func acknowledged(_ now: TimeInterval, fullyConfirmed: Bool) {
    if probing && !fullyConfirmed { return }
    let elapsed = now - lastAcknowledgedAt
    // Compare at nanosecond precision rather than floating-point subtraction noise at 100 ms.
    let timely = (elapsed * 1_000_000_000).rounded() <= 100_000_000
    if probing { if decision == nil { decision = !timely } }
    else if constrained {
      // Retry on a fixed cadence: 64-KiB fallback ACK gaps can exceed 100 ms because of
      // the fallback itself, so requiring timely gaps here can permanently lock the sender.
      if (draining && fullyConfirmed) || now - probeStartedAt >= 5 {
        if fullyConfirmed { reprobe = true } else { drainRequested = true }
      }
    }
    else if lan && maximumChunk > 4096 && elapsed > 1 { decision = true }
    lastAcknowledgedAt = now
  }
  // Apply shrinkage between records, never while a previously admitted source read is suspended.
  mutating func advance() {
    if let decision { constrained = decision; probing = false }
    decision = nil
    // A one-chunk budget drains a continuously replenished two-chunk pipeline before probing.
    if drainRequested { draining = true; drainRequested = false }
    if reprobe { probing = true; probeSubmitted = false; draining = false; probeStartedAt = lastAcknowledgedAt; reprobe = false }
  }
}

// MARK: - Throughput measurement

/// Reports the rate across the most recent `samples` observations rather than across the whole
/// transfer.
///
/// A lifetime average (`total / elapsed`) cannot answer "how fast is it going now": it hides a ramp
/// up, keeps reporting a healthy number while the link has stalled, and drags a genuinely fast
/// second file down behind a slow first one. A bounded window decays toward zero when the link stops
/// delivering and reflects the current link again as soon as bytes resume.
struct TransferRate {
  private let samples: Int
  private var counts: [Int64]
  private var times: [TimeInterval]
  private var size = 0
  private var next = 0

  // Twenty intervals at the 250-ms publication cadence span five seconds, including bursty LAN ACKs.
  init(samples: Int = 21) {
    precondition(samples >= 2, "A rate needs two observations.")
    self.samples = samples
    counts = Array(repeating: 0, count: samples)
    times = Array(repeating: 0, count: samples)
  }

  /// Records `totalBytes` observed at `at` and returns the rate in bytes per second.
  /// Returns `0` until two observations exist and whenever the window covers no progress, which
  /// callers present as "no rate available" rather than as a measured zero.
  mutating func add(_ totalBytes: Int64, at: TimeInterval) -> Double {
    counts[next] = totalBytes
    times[next] = at
    next = (next + 1) % samples
    if size < samples { size += 1 }
    guard size >= 2 else { return 0 }
    let oldest = size < samples ? 0 : next
    let newest = (next - 1 + samples) % samples
    let span = times[newest] - times[oldest]
    let delta = counts[newest] - counts[oldest]
    guard span > 0, delta > 0 else { return 0 }
    return Double(delta) / span
  }
}
