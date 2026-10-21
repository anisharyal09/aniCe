// SPDX-License-Identifier: GPL-3.0-or-later
// Coordinates bidirectional file transfer batches, cumulative flow control and sleep assertions over LAN-preferred authenticated LAN/BLE channels.
import Foundation
import Darwin
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
  /// The secured channel retired mid-stream. The verified prefix and destination stay retained in
  /// memory for `pauseTimeout`, so a reconnected channel can continue instead of restarting.
  case paused(batch: TransferBatch, fileIndex: Int, fileName: String, fileBytes: Int64, fileSize: Int64, totalBytes: Int64, reason: String, canResumeOverBle: Bool)
  case completed(batchId: UUID, fileCount: Int, totalBytes: Int64)
  case rejected(batchId: UUID, reason: Int64)
  case failed(reason: String)
  case cancelled
}

enum TransferEvent: Equatable {
  case incomingOffer(TransferBatch)
  /// A paused batch, emitted for both directions so the notification can offer Cancel; the
  /// Bluetooth continuation is a sender-only action.
  case paused(batch: TransferBatch, reason: String, canResumeOverBle: Bool)
  case resumed
  case completed(fileCount: Int, totalBytes: Int64)
  case failed(reason: String)
}

@Observable @MainActor final class MacTransferModel: FeatureHandler {
  private(set) var state: TransferState = .idle { didSet { maintainProgressUpdates() } }
  private(set) var activeChannel: (any SecuredChannel)?
  private(set) var peerConnected = false
  private(set) var peerCompatible = false
  /// External event sink for native notification bridges. Emits completed and failed only when receiving.
  var onEvent: ((TransferEvent) -> Void)?
  var onLanRequired: () -> Void = {}

  /// Exposes the active incoming offer batch, or nil outside .incomingOffer.
  /// Fences background notification actions against stale or out-of-order execution without extra state.
  var pendingOffer: TransferBatch? {
    if case .incomingOffer(let b) = state { return b }
    return nil
  }
  /// URLs of files published during the active or most recently finished receive operation.
  /// Deliberately outlives cleanup so a completed panel can still resolve and reveal the files;
  /// `dismiss()` or a new accept clears it.
  private(set) var publishedURLs: [URL] = []

  /// Destination folder of the active or most recently finished receive operation.
  /// Deliberately outlives cleanup so a completed panel can report where files were saved;
  /// `dismiss()` clears it.
  private(set) var receiveFolder: URL?
  private var channels: [String: any SecuredChannel] = [:]
  private var capabilities: [String: TransferMessage] = [:]
  private var isBusy: Bool {
    if preparing || offerAssembly != nil { return true }
    switch state {
    case .incomingOffer, .waitingForPeerApproval, .transferring, .paused: return true
    default: return false
    }
  }

  @ObservationIgnored nonisolated(unsafe) private var sleepAssertionID: IOPMAssertionID = 0
  @ObservationIgnored nonisolated(unsafe) private var hasSleepAssertion = false

  private var peerMaxChunkBytes: Int64 = 3072
  private var peerMaxWindow: Int64 = 64

  private var retiredBatches: [String] = []
  private var currentBatch: TransferBatch?
  private var preparation: Task<([TransferFile], Int64), Error>?
  private(set) var preparing = false
  private var transferTask: Task<Void, Never>?

  // Sender flow-control & backpressure
  private var sentBytes: Int64 = 0
  private var acknowledgedBytes: Int64 = 0
  /// When the last cumulative ACK arrived; a receiver-initiated BLE fallback yields to a live LAN.
  private var lastAckAt: TimeInterval?
  /// When the current sender stream started, used to give a fresh LAN resume time to produce ACKs.
  private var streamStartedAt: TimeInterval?
  private var creditResume: (() -> Void)?
  private var capacityWaiters: [UUID: () -> Void] = [:]
  private var fileResultContinuation: CheckedContinuation<TransferMessage, Error>?
  private var receivedFileResult: TransferMessage?
  private var sendingFile: TransferFile?
  private var senderFileIndex = 0
  private var epoch = UUID()
  private var capacityRevision = 0

  // Pause/resume retention. Everything here lives for the current process only; a process death
  // ends the batch and may leave a stale partial, exactly as an uncaught loss did before.
  private let pauseTimeout: Duration
  private var pausedTransport: String?
  private var pausedFileIndex = 0
  private var pausedFileOffset: Int64 = 0
  private var pausedCompletedBytes: Int64 = 0
  private var pauseTimerTask: Task<Void, Never>?
  private var resumeTask: Task<Void, Never>?
  private var upgradeTask: Task<Void, Never>?
  private var statusWaiter: ((TransferMessage?) -> Void)?
  private var statusWaiterToken: UUID?
  private var statusTimeoutTask: Task<Void, Never>?
  private var allowBleResume = false
  private var transferPeerDeviceId: String?
  private var transferPeerFingerprint: String?

  private struct RetainedFileResult {
    let batchId: String
    let fileId: String
    let fileSize: Int64
    let result: TransferMessage
  }
  /// The last verified result this receiver sent, replayable when a resume lands after the file.
  private var retainedFileResult: RetainedFileResult?

  init(pauseTimeout: Duration = .seconds(900)) {
    self.pauseTimeout = pauseTimeout
  }

  /// True from the moment a received file's last chunk lands until it is hashed and published.
  private(set) var finalizing = false

  /// Direction of the active or most recently finished batch: true while this Mac receives it. It
  /// deliberately outlives cleanup so a completed panel can still report which way the files moved;
  /// `dismiss()` clears it.
  private(set) var receiving = false

  // Receiver state
  private struct OfferAssembly {
    let batch: String
    let totalSlices: Int64
    let totalFiles: Int64
    let totalBytes: Int64
    var slices: [Int64: [TransferFile]] = [:]
  }
  private var offerAssembly: OfferAssembly?
  private var offerTimeout: Task<Void, Never>?
  private var destinationFolder: URL?
  private var receiverCurrentFileIndex = 0
  private var receiverPartFileURL: URL?
  private var receiverStorage: TransferReceiveStorage?
  private var receiverWrittenBytes: Int64 = 0
  private var receiverTotalTransferred: Int64 = 0
  private var lastAckedWrittenBytes: Int64 = 0
  private var ackTask: Task<Void, Never>?
  private var ackTimerTask: Task<Void, Never>?
  private var lastReceiverUiUpdate: TimeInterval = 0

  deinit {
    progressTask?.cancel()
    if hasSleepAssertion {
      IOPMAssertionRelease(sleepAssertionID)
    }
  }

  @ObservationIgnored nonisolated(unsafe) private var progressTask: Task<Void, Never>?
  private var progressRate = TransferRate()
  private var progressEpoch: UUID?
  private var progressSampleAt: TimeInterval = 0
  private var progressSpeed: Double = 0

  private func maintainProgressUpdates() {
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

  private func sampleProgress(_ total: Int64, at now: TimeInterval) -> Double {
    if now - progressSampleAt >= 0.25 {
      progressSpeed = progressRate.add(total, at: now)
      progressSampleAt = now
    }
    return progressSpeed
  }

  private func refreshProgress() {
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

  // MARK: - FeatureHandler conformance

  private func chunkLimit(_ descriptor: ChannelDescriptor?) -> Int {
    descriptor?.transport == "lan" && (descriptor?.maximumDataBytes ?? 4000) >= 262144 ? 262016 : 3072
  }

  func available(_ channel: any SecuredChannel) {
    let transport = channel.descriptor.transport
    guard transport == "lan" || transport == "ble" else { return }
    // A paused batch has no active channel, so its peer identity must outlive the channel that
    // paused it; otherwise a different peer's channel could be rebound to the retained prefix.
    let peerId = activeChannel?.descriptor.peer.deviceId ?? transferPeerDeviceId
    let peerFingerprint = activeChannel?.descriptor.peer.fingerprint ?? transferPeerFingerprint
    if let peerId, let peerFingerprint {
      guard peerId == channel.descriptor.peer.deviceId,
            peerFingerprint == channel.descriptor.peer.fingerprint else { return }
    }
    guard channels[transport]?.descriptor != channel.descriptor else { return }
    if let old = channels[transport] { retired(old.descriptor) }
    channels[transport] = channel
    selectPreferredChannel()
    Task {
      guard self.channels[transport]?.descriptor == channel.descriptor else { return }
      let chunkSize = self.chunkLimit(channel.descriptor)
      let versions: [Int64] = chunkSize > 131072 ? [2, 3] : [chunkSize > 3072 ? 2 : 1]
      for version in versions {
        guard self.channels[transport]?.descriptor == channel.descriptor else { return }
        let chunk = version == 2 ? min(131072, chunkSize) : chunkSize
        do {
          let data = try TransferMessage.capability(version: version, maxChunkBytes: Int64(chunk),
            maxWindow: chunk > 3072 ? 8 : 64).encode(maximumChunkBytes: chunkSize)
          try await self.sendWithBackpressure(data, on: channel, jobBound: false)
        } catch { return }
      }
    }
  }

  var isPaused: Bool {
    if case .paused = state { return true }
    return false
  }

  private func selectPreferredChannel() {
    // A live batch remains bound to its channel generation. A paused batch, by contrast, must
    // adopt a newly secured channel so the retained prefix can continue there.
    let canRebind = !isBusy || isPaused
    guard activeChannel == nil || canRebind else { return }
    let preferred = channels["lan"] ?? channels["ble"]
    activeChannel = preferred
    peerConnected = preferred != nil
    peerCompatible = false
    peerMaxChunkBytes = 3072
    peerMaxWindow = 64
    clearOfferAssembly()
    if let preferred, let capability = capabilities[preferred.descriptor.transport] { applyCapability(capability) }
    refreshPausedCapability()
    if isPaused, activeChannel != nil, peerCompatible {
      // The sender drives LAN auto-resume; the receiver only asks after an explicit opt-in.
      if receiving { if allowBleResume { requestPeerContinuation() } } else { attemptResume() }
    }
  }

  private func applyCapability(_ message: TransferMessage) {
    peerCompatible = true
    let localLimit = Int64(chunkLimit(activeChannel?.descriptor))
    let negotiatedLimit: Int64 = message.number(0) == 3 ? localLimit : message.number(0) == 2 ? min(131072, localLimit) : 3072
    peerMaxChunkBytes = min(message.number(1), negotiatedLimit)
    peerMaxWindow = min(message.number(2), peerMaxChunkBytes > 3072 ? 8 : 64)
  }

  func retired(_ descriptor: ChannelDescriptor) {
    guard channels[descriptor.transport]?.descriptor == descriptor else { return }
    channels.removeValue(forKey: descriptor.transport)
    capabilities.removeValue(forKey: descriptor.transport)
    clearCapacityWaiters()
    guard descriptor == activeChannel?.descriptor else {
      refreshPausedCapability()
      return
    }
    let previous = state
    activeChannel = nil
    peerConnected = false
    peerCompatible = false
    if case .transferring(let batch, _, _, _, _, _, _) = previous, !finalizing {
      pauseTransfer(batch: batch, transport: descriptor.transport)
    } else if case .paused = previous {
      // A resume attempt lost its channel before it completed; keep the retained prefix.
      resumeTask?.cancel(); resumeTask = nil
      abandonStatus()
    } else if isBusy {
      state = .failed(reason: "Connection closed. Send the files again using the remaining connection.")
      cleanupActiveTransfer()
    } else {
      cleanupActiveTransfer()
    }
    selectPreferredChannel()
  }

  private func clearCapacityWaiters() {
    let waiters = capacityWaiters
    capacityWaiters.removeAll()
    capacityRevision += 1
    for waiter in waiters.values {
      waiter()
    }
  }

  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    guard channels[descriptor.transport]?.descriptor == descriptor else { return }
    clearCapacityWaiters()
    guard descriptor == activeChannel?.descriptor else { return }
    checkCreditAndResume()
    flushAck()
  }

  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    let message: TransferMessage
    do { guard let decoded = try TransferMessage.decode(bytes, maximumChunkBytes: chunkLimit(descriptor)) else { return .unrecognized }; message = decoded }
    catch is TransferWireError { return .discarded }
    catch { return .unrecognized }
    guard channels[descriptor.transport]?.descriptor == descriptor else { return .discarded }
    if message.kind == 1 {
      capabilities[descriptor.transport] = message
      if descriptor == activeChannel?.descriptor {
        peerCompatible = true
        if !isTransferring, transferTask == nil { applyCapability(message) }
        if isPaused {
          refreshPausedCapability()
          if receiving { if allowBleResume { requestPeerContinuation() } } else { attemptResume() }
        }
      } else if isPaused {
        refreshPausedCapability()
      } else if descriptor.transport == "lan", isTransferring {
        // LAN is preferred even after a deliberate Bluetooth continuation. The receiver answers
        // the resume while it is still transferring, so the stream can switch without a pause.
        maybeUpgradeToLan(descriptor)
      }
      return .handled
    }
    // Resume and status may name the batch a new channel is taking over, so they are routed
    // before the active-descriptor guard. A resume for an unknown batch still receives a status.
    if message.kind == 10 {
      await handleResume(message, on: descriptor)
      return .handled
    }
    if message.kind == 11 {
      if message.string(0) == currentBatch?.idString { handleStatus(message) }
      return .handled
    }
    if message.kind == 9, message.string(0) == currentBatch?.idString {
      await processMessage(message, peerName: descriptor.peer.deviceName)
      return .handled
    }
    guard descriptor == activeChannel?.descriptor else { return .discarded }
    await processMessage(message, peerName: descriptor.peer.deviceName)
    return .handled
  }

  // MARK: - Message Processing

  private func processMessage(_ message: TransferMessage, peerName: String) async {
    switch message.kind {
    case 2: // offer
      handleOffer(message, peerName: peerName)

    case 3: // accept
      handleAccept(message)

    case 4: // reject
      handleReject(message)

    case 5: // chunk
      await handleChunk(message)

    case 6: // ack
      handleAck(message)

    case 7:
      guard let batch = currentBatch, let file = sendingFile,
        message.string(0) == batch.idString, message.string(1) == file.idString,
        message.number(2) != 0 || (sentBytes == file.size && message.bytes(3) == file.sha256) else { return }
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

  // MARK: - Pause and Resume

  private var isTransferring: Bool {
    if case .transferring = state { return true }
    return false
  }

  /// Retains a mid-stream batch after its active channel retired. Nothing is published, discarded
  /// or released here: the partial, destination and sleep assertion stay alive for `pauseTimeout`,
  /// and only an explicit Cancel, a resume failure or the timer ends them.
  private func pauseTransfer(batch: TransferBatch, transport: String) {
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
    pausedFileIndex = fileIndex
    pausedFileOffset = max(0, min(receiving ? receiverWrittenBytes : acknowledgedBytes, file.size))
    pausedCompletedBytes = receiving
      ? max(receiverTotalTransferred - receiverWrittenBytes, 0)
      : batch.files.prefix(fileIndex).reduce(0) { $0 + $1.size }
    allowBleResume = false
    transferTask?.cancel(); transferTask = nil
    fileResultContinuation?.resume(throwing: SessionFailure.cancelled)
    fileResultContinuation = nil
    ackTask = nil
    ackTimerTask?.cancel(); ackTimerTask = nil
    creditResume?(); creditResume = nil
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
    // Automatic LAN policy decides whether a new window may open; an explicit Disconnect still
    // wins, so a paused batch never forces LAN back on by itself.
    onLanRequired()
    onEvent?(.paused(batch: batch, reason: reason, canResumeOverBle: false))
  }

  private func startPauseTimer() {
    pauseTimerTask?.cancel()
    let operation = epoch
    let timeout = pauseTimeout
    pauseTimerTask = Task { [weak self] in
      do { try await Task.sleep(for: timeout) } catch { return }
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
    if receiving { requestPeerContinuation() } else { attemptResume() }
  }

  private func refreshPausedCapability() {
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
  private func attemptResume() {
    guard case .paused(let batch, _, _, _, _, _, _, _) = state else { return }
    guard !receiving, resumeTask == nil, let channel = activeChannel, peerCompatible else { return }
    let transport = channel.descriptor.transport
    let allowed = transport == "lan" || pausedTransport != "lan" || allowBleResume
    guard allowed else { refreshPausedCapability(); return }
    let fileIndex = pausedFileIndex
    guard batch.files.indices.contains(fileIndex) else { return }
    let file = batch.files[fileIndex]
    let completedBefore = pausedCompletedBytes
    let operation = epoch
    let initialOffset = pausedFileOffset

    resumeTask = Task { [weak self] in
      guard let self else { return }
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
            if self.epoch == operation, !Task.isCancelled {
              self.failTransfer(reason: "The other device did not answer the resume request.")
            }
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
            self.failTransfer(reason: "The other device cannot continue this transfer. Send the files again.")
            return
          }
        }
        guard self.epoch == operation, !Task.isCancelled else { return }
        self.pauseTimerTask?.cancel(); self.pauseTimerTask = nil
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
          await self.streamBatchFrom(batch, startFileIndex: fileIndex, startOffset: offset, completedBefore: completedBefore)
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
  private func requestPeerContinuation() {
    guard case .paused(let batch, _, _, _, _, _, _, _) = state, receiving,
      allowBleResume, resumeTask == nil, activeChannel != nil, peerCompatible else { return }
    let fileIndex = receiverCurrentFileIndex
    guard batch.files.indices.contains(fileIndex) else { return }
    let file = batch.files[fileIndex]
    let operation = epoch
    resumeTask = Task { [weak self] in
      guard let self else { return }
      var restarted = false
      defer {
        self.allowBleResume = false
        if self.epoch == operation, self.isPaused { self.refreshPausedCapability() }
        self.resumeTask = nil
      }
      loop: while true {
        guard self.epoch == operation, !Task.isCancelled else { return }
        guard let channel = self.activeChannel, self.peerCompatible,
          let storage = self.receiverStorage else { break loop }
        let offset = max(0, min(self.receiverWrittenBytes, file.size))
        guard let prefix = try? await storage.prefixDigest(offset),
          self.epoch == operation, !Task.isCancelled else { break loop }
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

  private func requestStatus(_ request: Data, on channel: any SecuredChannel) async -> TransferMessage? {
    let operation = epoch
    let token = UUID()
    return await withCheckedContinuation { (continuation: CheckedContinuation<TransferMessage?, Never>) in
      let finish: (TransferMessage?) -> Void = { [weak self] message in
        guard let self, self.statusWaiterToken == token else { return }
        self.statusWaiter = nil
        self.statusWaiterToken = nil
        self.statusTimeoutTask?.cancel()
        self.statusTimeoutTask = nil
        continuation.resume(returning: message)
      }
      statusWaiter = finish
      statusWaiterToken = token
      statusTimeoutTask = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(15)) } catch { return }
        guard let self, self.epoch == operation else { return }
        finish(nil)
      }
      Task { [weak self] in
        guard let self else { return }
        do { try await self.sendWithBackpressure(request, on: channel, jobBound: false) }
        catch { finish(nil) }
      }
    }
  }

  private func handleStatus(_ message: TransferMessage) {
    guard let batch = currentBatch, message.string(0) == batch.idString else { return }
    // The waiter belongs to whichever side initiated the handshake: the sender after its own
    // resume, or the receiver after a receiver-initiated Bluetooth continuation.
    let index = receiving ? receiverCurrentFileIndex : senderFileIndex
    guard batch.files.indices.contains(index),
      message.string(1) == batch.files[index].idString else { return }
    statusWaiter?(message)
  }

  private func abandonStatus() {
    let waiter = statusWaiter
    statusWaiter = nil
    statusWaiterToken = nil
    statusTimeoutTask?.cancel(); statusTimeoutTask = nil
    waiter?(nil)
  }

  /// Receiver side of the handshake: verify the retained prefix, rebind to the sender's chosen
  /// channel and answer with the offset the sender must continue from.
  private func handleResume(_ message: TransferMessage, on descriptor: ChannelDescriptor) async {
    guard let channel = channels[descriptor.transport], channel.descriptor == descriptor else { return }
    let batchId = message.string(0)
    let fileId = message.string(1)
    let offset = message.number(2)
    let prefix = message.bytes(3)

    if let retained = retainedFileResult, retained.batchId == batchId, retained.fileId == fileId {
      // The file was already verified before the channel died. Replaying its result lets the
      // sender skip the last-chunk wait instead of failing on a resume for a closed file.
      bindResumeChannel(channel)
      await replyStatus(channel, batch: batchId, file: fileId, bytes: retained.fileSize, state: 0)
      try? await sendWithBackpressure(retained.result.encode(), on: channel, jobBound: false)
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
    var matches = false
    if offset >= 0 { matches = (try? await storage.matchesPrefix(offset, expected: prefix)) == true }
    if !matches {
      guard await resetReceiverFile(batch, file) else {
        await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: 4)
        return
      }
      bindResumeChannel(channel)
      await replyStatus(channel, batch: batchId, file: fileId, bytes: 0, state: 2)
      return
    }
    bindResumeChannel(channel)
    pauseTimerTask?.cancel(); pauseTimerTask = nil
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

  private func bindResumeChannel(_ channel: any SecuredChannel) {
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
  private func handlePeerResume(
    batchId: String, fileId: String, offset: Int64, prefix: Data, channel: any SecuredChannel
  ) async {
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

    let sent = max(0, min(sentBytes, file.size))
    guard offset >= 0, offset <= sent else {
      await replyStatus(channel, batch: batchId, file: fileId, bytes: sent, state: 1)
      return
    }
    let matches = ((try? await filePrefixDigest(file, length: offset)) ?? Data()) == prefix
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
    creditResume?(); creditResume = nil
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
    transferTask = Task { [weak self] in
      guard let self, operation == self.epoch, self.activeChannel != nil else { return }
      await self.streamBatchFrom(batch, startFileIndex: fileIndex, startOffset: offset, completedBefore: completedBefore)
    }
  }

  /// Sender-side transport upgrade. A capable LAN channel arriving during a Bluetooth stream
  /// triggers the existing resume handshake; the receiver accepts while transferring, reports its
  /// actual written offset, and both sides switch without a visible pause.
  private func maybeUpgradeToLan(_ descriptor: ChannelDescriptor) {
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
      defer { self.upgradeTask = nil }
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
      self.creditResume?(); self.creditResume = nil
      self.clearCapacityWaiters()
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
        await self.streamBatchFrom(batch, startFileIndex: fileIndex, startOffset: startOffset, completedBefore: completedBefore)
      }
    }
  }

  /// When the replayed file was the one before the receiver's current file, the sender resumes the
  /// next file at zero; the receiver must already be accepting it, with no second handshake.
  private func continueAfterRetainedReplay() {
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

  /// Recreates the current file from zero after the retained prefix failed verification.
  private func resetReceiverFile(_ batch: TransferBatch, _ file: TransferFile) async -> Bool {
    let previous = receiverStorage
    receiverStorage = nil
    receiverPartFileURL = nil
    await previous?.discard()
    receiverTotalTransferred = max(receiverTotalTransferred - receiverWrittenBytes, 0)
    receiverWrittenBytes = 0
    lastAckedWrittenBytes = 0
    let operation = epoch
    do {
      try await prepareReceiverForFile(at: receiverCurrentFileIndex, in: batch)
      return operation == epoch
    } catch {
      return false
    }
  }

  private func replyStatus(_ channel: any SecuredChannel, batch: String, file: String, bytes: Int64, state: Int64) async {
    if let encoded = try? TransferMessage.status(batch: batch, file: file, bytesTransferred: bytes, state: state).encode() {
      try? await sendWithBackpressure(encoded, on: channel, jobBound: false)
    }
  }

  private func filePrefixDigest(_ file: TransferFile, length: Int64) async throws -> Data {
    guard length >= 0, length <= file.size, let url = file.localURL else { throw CocoaError(.fileReadUnknown) }
    return try await TransferSendStorage.prefixDigest(url, length: length)
  }

  // MARK: - Sender Flow

  private func sendWithBackpressure(_ data: Data, on selectedChannel: (any SecuredChannel)? = nil, jobBound: Bool = true) async throws {
    guard let channel = selectedChannel ?? activeChannel else { throw SessionFailure.cancelled }
    let operation = epoch
    while true {
      try Task.checkCancellation()
      guard (!jobBound || operation == epoch), channels[channel.descriptor.transport]?.descriptor == channel.descriptor else { throw SessionFailure.cancelled }
      let revision = capacityRevision
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

  func sendFiles(urls: [URL]) async {
    if !isBusy, (1...128).contains(urls.count), activeChannel?.descriptor.transport != "lan" { onLanRequired() }
    selectPreferredChannel()
    guard let channel = activeChannel, peerConnected else {
      state = .failed(reason: "No secured local-network or Bluetooth connection")
      return
    }
    guard peerCompatible else { state = .failed(reason: "This peer has not advertised file transfer support"); return }
    guard (1...128).contains(urls.count) else {
      state = .failed(reason: "Transfer batch must contain 1 to 128 files")
      return
    }

    guard preparation == nil, transferTask == nil else { return }
    let operation = epoch
    preparing = true
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
    guard operation == epoch, activeChannel?.descriptor == channel.descriptor else { return }
    preparation = nil; preparing = false

    let batchId = UUID()
    let batch = TransferBatch(id: batchId, files: files, totalBytes: totalBytes, peerName: channel.descriptor.peer.deviceName)
    currentBatch = batch
    receiving = false
    transferPeerDeviceId = channel.descriptor.peer.deviceId
    transferPeerFingerprint = channel.descriptor.peer.fingerprint
    retainedFileResult = nil
    state = .waitingForPeerApproval(batch: batch)
    acquireSleepAssertion()

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

  private func handleAccept(_ message: TransferMessage) {
    guard case .waitingForPeerApproval(let batch) = state,
          message.string(0) == batch.idString else { return }

    guard transferTask == nil, let channel = activeChannel else { return }
    let operation = epoch
    transferTask = Task {
      guard operation == epoch, activeChannel?.descriptor == channel.descriptor else { return }
      await streamAcceptedBatch(batch)
    }
  }

  private func streamAcceptedBatch(_ batch: TransferBatch) async {
    await streamBatchFrom(batch, startFileIndex: 0, startOffset: 0, completedBefore: 0)
  }

  /// Streams from `startFileIndex` at `startOffset`, where the receiver already retains
  /// `startOffset` bytes of that file and `completedBefore` complete bytes precede it.
  private func streamBatchFrom(_ batch: TransferBatch, startFileIndex: Int, startOffset: Int64, completedBefore: Int64) async {
    guard activeChannel != nil, batch.files.indices.contains(startFileIndex) else { return }
    let operation = epoch
    let initialOffset = max(0, min(startOffset, batch.files[startFileIndex].size))
    var totalTransferred = completedBefore + initialOffset
    var lastUiUpdate: TimeInterval = 0

    for fileIndex in startFileIndex..<batch.files.count {
      guard operation == epoch else { return }
      let file = batch.files[fileIndex]
      let initial = fileIndex == startFileIndex ? initialOffset : 0
      guard let url = file.localURL else {
        failTransfer(reason: "Failed reading local file \(file.name)")
        return
      }

      let source: TransferSendStorage
      do { source = try await TransferSendStorage.open(url, skipping: initial) }
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
      streamStartedAt = ProcessInfo.processInfo.systemUptime
      var fileBytesSent: Int64 = initial
      // A LAN capability that arrived while the previous file was finalizing is retried here,
      // at the new file's start, where the stream is no longer waiting on a file result.
      if !receiving, let lan = channels["lan"] { maybeUpgradeToLan(lan.descriptor) }
      var upgradeChecked = false

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
        guard !Task.isCancelled, operation == epoch, self.activeChannel != nil else {
          await source.close()
          return
        }

        let chunkSize = min(Int(peerMaxChunkBytes), Int(file.size - fileBytesSent))
        let chunkData: Data
        do { chunkData = try await source.read(chunkSize) }
        catch { await source.close(); if operation == epoch { failTransfer(reason: "Source read failed") }; return }
        guard operation == epoch, !Task.isCancelled else { await source.close(); return }
        guard chunkData.count == chunkSize else {
          await source.close()
          failTransfer(reason: "I/O error reading \(file.name)")
          return
        }

        let chunkMsg = TransferMessage.chunk(
          batch: batch.idString,
          file: file.idString,
          offset: fileBytesSent,
          data: chunkData
        )
        guard let encoded = try? chunkMsg.encode(maximumChunkBytes: chunkLimit(activeChannel?.descriptor)) else {
          await source.close()
          failTransfer(reason: "Failed encoding chunk")
          return
        }

        do {
          sentBytes += Int64(chunkData.count)
          try await sendWithBackpressure(encoded)
          guard operation == epoch else { await source.close(); return }
          fileBytesSent += Int64(chunkData.count)
          totalTransferred += Int64(chunkData.count)

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

      // Wait for file-result from receiver
      let fileResult: TransferMessage
      do {
        if let pending = receivedFileResult { fileResult = pending; receivedFileResult = nil }
        else {
          let operation = epoch
          let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.epoch == operation else { return }
            self.fileResultContinuation?.resume(throwing: SessionFailure.expired)
            self.fileResultContinuation = nil
          }
          defer { deadline.cancel() }
          fileResult = try await withCheckedThrowingContinuation { self.fileResultContinuation = $0 }
        }
      } catch { if !Task.isCancelled && operation == epoch { failTransfer(reason: "File confirmation timed out") }; return }
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
    state = .completed(batchId: batch.id, fileCount: batch.files.count, totalBytes: batch.totalBytes)
    let count = batch.files.count
    let bytes = batch.totalBytes
    let wasReceiving = receiving
    cleanupActiveTransfer()
    if wasReceiving { onEvent?(.completed(fileCount: count, totalBytes: bytes)) }
  }

  private func handleAck(_ message: TransferMessage) {
    guard let batch = currentBatch, let file = sendingFile,
      message.string(0) == batch.idString, message.string(1) == file.idString else { return }
    let written = message.number(2)
    guard written >= acknowledgedBytes, written <= sentBytes, written <= file.size else { return }
    acknowledgedBytes = written
    lastAckAt = ProcessInfo.processInfo.systemUptime
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
    guard !retiredBatches.contains(batchIdStr) else { return }
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

  private func clearOfferAssembly() {
    offerTimeout?.cancel(); offerTimeout = nil
    offerAssembly = nil
  }

  func acceptIncomingOffer(destination: URL) async {
    guard case .incomingOffer(let batch) = state, let channel = activeChannel else { return }
    let operation = epoch
    do {
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

  private func prepareReceiverForFile(at index: Int, in batch: TransferBatch) async throws {
    guard batch.files.indices.contains(index), let dest = destinationFolder else { return }
    let file = batch.files[index]
    receiverCurrentFileIndex = index
    receiverWrittenBytes = 0
    lastAckedWrittenBytes = 0
    let operation = epoch
    let storage = TransferReceiveStorage()
    do {
      let url = try await storage.create(folder: dest, batch: batch.idString, file: file.idString)
      guard operation == epoch else { await storage.discard(); throw SessionFailure.cancelled }
      receiverStorage = storage
      receiverPartFileURL = url
    } catch { await storage.discard(); throw error }
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
      defer {
        if self.epoch == operation && self.receiverCurrentFileIndex == fileIndex {
          self.ackTask = nil
          let unacked = self.receiverWrittenBytes - self.lastAckedWrittenBytes
          // Flow-control ACK cadence: for LAN transfer (chunk size > 3072), ACK every 2 chunks
          // (peerMaxWindow / 4) so sender credit never stalls. Standard/BLE retains 8-chunk cadence.
          let ackCadence = self.peerMaxChunkBytes > 3072 ? max(1, self.peerMaxWindow / 4) : min(8, max(1, self.peerMaxWindow / 2))
          if unacked >= ackCadence * self.peerMaxChunkBytes || (self.receiverWrittenBytes == currentFile.size && self.receiverWrittenBytes > self.lastAckedWrittenBytes) {
            self.flushAck()
          }
        }
      }
      let ack = TransferMessage.ack(batch: batch.idString, file: currentFile.idString, written: bytesToAck)
      if let encoded = try? ack.encode() {
        do {
          try await self.sendWithBackpressure(encoded, on: channel)
          guard operation == self.epoch, self.receiverCurrentFileIndex == fileIndex else { return }
          self.lastAckedWrittenBytes = max(self.lastAckedWrittenBytes, bytesToAck)
        } catch {
          // Will be retried on next flushAck or capacityAvailable
        }
      }
    }
  }

  private func handleChunk(_ message: TransferMessage) async {
    guard case .transferring(let batch, _, _, _, _, let totalBytesTransferred, _) = state,
          let dest = destinationFolder,
          let storage = receiverStorage,
          let partURL = receiverPartFileURL else { return }

    let fileId = message.string(1)
    let offset = message.number(2)
    let data = message.bytes(3)

    guard batch.files.indices.contains(receiverCurrentFileIndex) else { return }
    let currentFile = batch.files[receiverCurrentFileIndex]
    guard currentFile.idString == fileId else { return }
    guard offset == receiverWrittenBytes else { return }

    guard message.string(0) == batch.idString, data.count <= chunkLimit(activeChannel?.descriptor), Int64(data.count) <= currentFile.size - receiverWrittenBytes else { return }
    let operation = epoch
    do { try await storage.write(data) }
    catch { if operation == epoch { failTransfer(reason: "Destination write failed: \(error.localizedDescription)") }; return }
    guard operation == epoch, receiverStorage === storage else { return }
    receiverWrittenBytes += Int64(data.count)
    receiverTotalTransferred += Int64(data.count)

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

    // Flow-control ACK cadence: for LAN transfer (chunk size > 3072), ACK every 2 chunks
    // (peerMaxWindow / 4) so sender credit never stalls. Standard/BLE retains 8-chunk cadence.
    let unacked = receiverWrittenBytes - lastAckedWrittenBytes
    let ackCadence = peerMaxChunkBytes > 3072 ? max(1, peerMaxWindow / 4) : min(8, max(1, peerMaxWindow / 2))
    if unacked >= ackCadence * peerMaxChunkBytes || receiverWrittenBytes == currentFile.size {
      flushAck()
    } else if receiverWrittenBytes > lastAckedWrittenBytes {
      scheduleAckTimer()
    }

    if receiverWrittenBytes == currentFile.size { await finalizeReceiverFile(batch) }
  }

  private func finalizeReceiverFile(_ batch: TransferBatch) async {
    guard !finalizing, batch.files.indices.contains(receiverCurrentFileIndex),
      let storage = receiverStorage, let partURL = receiverPartFileURL, let dest = destinationFolder else { return }
    finalizing = true
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
      let finished = try await storage.finish(name: file.name, expected: file.sha256)
      digest = finished.digest
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
      result: TransferMessage.fileResult(batch: batch.idString, file: file.idString, result: 0, hash: digest)
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
        try await self.sendWithBackpressure(TransferMessage.fileResult(batch: batch.idString, file: file.idString, result: 0, hash: digest).encode())
        guard operation == self.epoch else { return }
        self.finalizing = false
        if next < batch.files.count {
          if self.receiverWrittenBytes == batch.files[next].size { await self.finalizeReceiverFile(batch) }
        } else {
          try await self.sendWithBackpressure(TransferMessage.batchResult(batch: batch.idString, result: 0).encode())
          guard operation == self.epoch else { return }
          self.state = .completed(batchId: batch.id, fileCount: batch.files.count, totalBytes: batch.totalBytes)
          let count = batch.files.count
          let bytes = batch.totalBytes
          let wasReceiving = self.receiving
          self.cleanupActiveTransfer()
          if wasReceiving { self.onEvent?(.completed(fileCount: count, totalBytes: bytes)) }
        }
      } catch { if operation == self.epoch { self.failTransfer(reason: "Completion delivery failed") } }
    }
  }

  // MARK: - Cancellation and Cleanup

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

  private func failTransfer(reason: String) {
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

  private func cleanupActiveTransfer(selectChannel: Bool = true) {
    progressTask?.cancel(); progressTask = nil; progressEpoch = nil
    preparation?.cancel(); preparation = nil; preparing = false
    clearOfferAssembly()
    pauseTimerTask?.cancel(); pauseTimerTask = nil
    resumeTask?.cancel(); resumeTask = nil
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
    // Retire logical work; an already-sealed submission must finish without cancelling the shared socket.
    transferTask = nil
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
    finalizing = false
    ackTask = nil
    ackTimerTask?.cancel()
    ackTimerTask = nil
    let storage = receiverStorage
    receiverStorage = nil
    receiverPartFileURL = nil
    Task { await storage?.discard() }
    creditResume?()
    creditResume = nil
    clearCapacityWaiters()
    receiverTotalTransferred = 0
    releaseSleepAssertion()
    if selectChannel { selectPreferredChannel() }
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

  init(samples: Int = 8) {
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

/// Publishes a verified partial into its destination folder without overwriting anything.
///
/// The link is what decides the name, so a collision is resolved by the filesystem refusing the
/// link rather than by a check-then-act on an existence probe. A hard link is an implementation
/// detail of publication, not a requirement of the transfer, so a destination that cannot hold one
/// (iCloud Drive, an external or network volume) publishes by copying. The digest is verified
/// before this runs, so neither mode can publish unverified bytes.
enum TransferPublisher {
  /// Suffix attempts before publication is reported as impossible.
  static let maximumSuffix = 10000

  /// `name` for suffix `0`, otherwise `base (suffix).ext`.
  static func suffixed(_ name: String, _ suffix: Int) -> String {
    guard suffix > 0 else { return name }
    let ns = name as NSString
    let ext = ns.pathExtension
    let base = ns.deletingPathExtension
    return ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
  }

  /// The real POSIX reason, so a failure is diagnosable instead of reported as an unknown save error.
  private static func failure(_ code: Int32, _ url: URL) -> Error {
    let reason = String(cString: strerror(code))
    return NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(code),
      userInfo: [NSLocalizedDescriptionKey: "\(reason) (\(url.lastPathComponent))"]
    )
  }

  /// The link primitive, so a volume that cannot hold hard links is verifiable without one.
  @discardableResult
  static func publish(
    _ partial: URL,
    as name: String,
    in folder: URL,
    hardLink: (String, String) -> Int32 = { Darwin.link($0, $1) }
  ) throws -> URL {
    var suffix = 0
    var linking = true
    while suffix <= maximumSuffix {
      let target = folder.appendingPathComponent(suffixed(name, suffix))
      if linking {
        if hardLink(partial.path, target.path) == 0 {
          guard unlink(partial.path) == 0 else { throw failure(errno, partial) }
          return target
        }
        let code = errno
        if code == EEXIST {
          suffix += 1
          continue
        }
        // Only a volume that cannot express a link switches modes; any other error is real.
        guard code == EXDEV || code == ENOTSUP || code == EPERM || code == EMLINK else {
          // The destination is what could not be published, so it is what the failure names — the
          // staging partial is a random name the user never chose and cannot act on.
          throw failure(code, target)
        }
        linking = false
        suffix = 0
        continue
      }
      // O_EXCL makes the destination decision atomic and non-overwriting.
      let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
      if descriptor < 0 {
        let code = errno
        // A name already in use advances the suffix rather than discarding an already verified
        // transfer. An existing symlink is one: the system reports it as EEXIST or, under
        // O_NOFOLLOW, as ELOOP.
        if code == EEXIST || code == ELOOP {
          suffix += 1
          continue
        }
        throw failure(code, target)
      }
      do {
        // The destination handle owns the descriptor, so creating it before anything that can throw
        // means an unwind still closes the descriptor instead of leaking it.
        let destination = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let source = try FileHandle(forReadingFrom: partial)
        while let block = try source.read(upToCount: 1 << 20), !block.isEmpty {
          try destination.write(contentsOf: block)
        }
        try source.close()
        try destination.synchronize()
        try destination.close()
      } catch {
        // A half-written copy is not a published file; the verified partial survives for recovery.
        try? FileManager.default.removeItem(at: target)
        throw error
      }
      try FileManager.default.removeItem(at: partial)
      return target
    }
    throw failure(EEXIST, folder.appendingPathComponent(name))
  }
}

// Each received file has one storage actor; transport delivery awaits checked writes before ACK credit.
private actor TransferReceiveStorage {
  private var handle: FileHandle?
  private var partial: URL?
  private var folder: URL?
  private var hasher = SHA256()
  private var preservePartial = false

  static func checkCapacity(_ folder: URL, bytes: Int64) async throws {
    try await Task.detached {
      let available = try folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
      if let available, Double(bytes) + 64 * 1048576 > Double(available) { throw CocoaError(.fileWriteOutOfSpace) }
    }.value
  }

  func create(folder: URL, batch: String, file: String) throws -> URL {
    assert(!Thread.isMainThread)
    let url = folder.appendingPathComponent(".anice-\(batch)-\(file)-\(UUID().uuidString).part")
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    self.folder = folder
    partial = url
    handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    return url
  }

  func write(_ data: Data) throws {
    assert(!Thread.isMainThread)
    guard let handle else { throw CocoaError(.fileWriteUnknown) }
    try handle.write(contentsOf: data)
    hasher.update(data: data)
  }

  /// Flushes and hashes exactly `length` bytes of the retained partial. The receiver sends this
  /// digest so the sender can prove its own source prefix before switching transports.
  func prefixDigest(_ length: Int64) throws -> Data {
    assert(!Thread.isMainThread)
    guard length >= 0, let handle, let partial else { throw CocoaError(.fileReadUnknown) }
    try handle.synchronize()
    let reader = try FileHandle(forReadingFrom: partial)
    defer { try? reader.close() }
    var digest = SHA256()
    var remaining = length
    while remaining > 0 {
      guard let block = try reader.read(upToCount: Int(min(remaining, 1 << 20))), !block.isEmpty else {
        throw CocoaError(.fileReadUnknown)
      }
      digest.update(data: block)
      remaining -= Int64(block.count)
    }
    return Data(digest.finalize())
  }

  /// Flushes the retained prefix and verifies that exactly `length` bytes on disk match
  /// `expected`. The sender's resume hash proves its source and this receiver's partial agree.
  func matchesPrefix(_ length: Int64, expected: Data) throws -> Bool {
    try prefixDigest(length) == expected
  }

  func finish(name: String, expected: Data) throws -> (digest: Data, url: URL) {
    assert(!Thread.isMainThread)
    guard let handle, let partial, let folder else { throw CocoaError(.fileWriteUnknown) }
    let digest = Data(hasher.finalize())
    guard digest == expected else { throw SessionFailure.authentication }
    preservePartial = true
    try handle.synchronize()
    try handle.close()
    self.handle = nil
    let publishedURL = try TransferPublisher.publish(partial, as: name, in: folder)
    self.partial = nil
    return (digest: digest, url: publishedURL)
  }

  func discard() {
    assert(!Thread.isMainThread)
    do {
      try handle?.close(); handle = nil
      if !preservePartial, let partial, FileManager.default.fileExists(atPath: partial.path) {
        try FileManager.default.removeItem(at: partial)
      }
    } catch { NSLog("Transfer partial cleanup failed: %@", error.localizedDescription) }
  }
}

private actor TransferSendStorage {
  private let handle: FileHandle
  private init(_ url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
  static func open(_ url: URL, skipping offset: Int64 = 0) async throws -> TransferSendStorage {
    let storage = try await Task.detached { try TransferSendStorage(url) }.value
    if offset > 0 { try await storage.skip(offset) }
    return storage
  }
  private func skip(_ offset: Int64) throws {
    assert(!Thread.isMainThread)
    var remaining = offset
    while remaining > 0 {
      guard let block = try handle.read(upToCount: Int(min(remaining, 1 << 20))), !block.isEmpty else {
        throw CocoaError(.fileReadCorruptFile)
      }
      remaining -= Int64(block.count)
    }
  }
  /// SHA-256 over exactly the first `length` source bytes, used to prove a resume prefix.
  static func prefixDigest(_ url: URL, length: Int64) async throws -> Data {
    try await Task.detached(priority: .utility) {
      guard length >= 0 else { throw CocoaError(.fileReadUnknown) }
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var digest = SHA256()
      var remaining = length
      while remaining > 0 {
        guard let block = try handle.read(upToCount: Int(min(remaining, 1 << 20))), !block.isEmpty else {
          throw CocoaError(.fileReadCorruptFile)
        }
        digest.update(data: block)
        remaining -= Int64(block.count)
      }
      return Data(digest.finalize())
    }.value
  }
  func read(_ count: Int) throws -> Data {
    assert(!Thread.isMainThread)
    var bytes = Data()
    while bytes.count < count {
      guard let next = try handle.read(upToCount: count - bytes.count), !next.isEmpty else { break }
      bytes.append(next)
    }
    return bytes
  }
  func close() {
    assert(!Thread.isMainThread)
    do { try handle.close() } catch { NSLog("Transfer source close failed: %@", error.localizedDescription) }
  }
}
