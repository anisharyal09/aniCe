// SPDX-License-Identifier: GPL-3.0-or-later
// Coordinates bidirectional file transfer batches, cumulative flow control and sleep assertions over LAN-preferred authenticated LAN/BLE channels.
import Foundation
import Observation
import IOKit.pwr_mgt

struct TransferFile: Identifiable, Equatable, Hashable, Codable, Sendable {
  let id: UUID
  let name: String
  let size: Int64
  let sha256: Data
  let localURL: URL?

  var idString: String { id.uuidString.lowercased() }
}

struct TransferBatch: Identifiable, Equatable, Codable, Sendable {
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
  /// checkpoints for `pauseTimeout`, so a reconnected channel can continue instead of restarting.
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
  let notificationPreferences: TransferNotificationPreferences
  var state: TransferState = .idle {
    didSet {
      if case .transferring(_, _, _, let bytes, _, _, _) = state,
        case .paused(_, _, _, let previous, _, _, _, _) = oldValue, bytes > previous { pauseExpiresAt = nil; pauseDeadline = nil }
      maintainProgressUpdates()
      let force: Bool
      switch (state, oldValue) {
      case (.transferring(_, let index, _, _, _, _, _), .transferring(_, let previous, _, _, _, _, _)): force = index != previous
      case (.transferring, _), (.incomingOffer, _), (.waitingForPeerApproval, _): force = true
      default: force = false
      }
      checkpoint(force: force)
    }
  }
  var activeChannel: (any SecuredChannel)?
  var peerConnected = false
  var peerCompatible = false
  /// External event sink for native notification bridges. Emits completed and failed only when receiving.
  var onEvent: ((TransferEvent) -> Void)?
  /// Returns whether a bounded automatic LAN attempt was accepted by the connection owner.
  var onLanRequired: () -> Bool = { false }

  /// Exposes the active incoming offer batch, or nil outside .incomingOffer.
  /// Fences background notification actions against stale or out-of-order execution without extra state.
  var pendingOffer: TransferBatch? {
    if case .incomingOffer(let b) = state { return b }
    return nil
  }
  /// URLs of files published during the active or most recently finished receive operation.
  /// Deliberately outlives cleanup so a completed panel can still resolve and reveal the files;
  /// `dismiss()` or a new accept clears it.
  var publishedURLs: [URL] = []

  /// Destination folder of the active or most recently finished receive operation.
  /// Deliberately outlives cleanup so a completed panel can report where files were saved;
  /// `dismiss()` clears it.
  var receiveFolder: URL?
  var channels: [String: any SecuredChannel] = [:]
  var capabilities: [String: TransferMessage] = [:]
  var rendezvousWait: (() -> Void)?
  var isBusy: Bool {
    if preparing || offerAssembly != nil { return true }
    switch state {
    case .incomingOffer, .waitingForPeerApproval, .transferring, .paused: return true
    default: return false
    }
  }

  @ObservationIgnored nonisolated(unsafe) var sleepAssertionID: IOPMAssertionID = 0
  @ObservationIgnored nonisolated(unsafe) var hasSleepAssertion = false

  var peerMaxChunkBytes: Int64 = 3072
  var peerMaxWindow: Int64 = 64
  var sendWindow: TransferSendWindow?
  var senderChunkBytes: Int64 { sendWindow?.chunkBytes ?? peerMaxChunkBytes }
  var sendCreditBytes: Int64 { sendWindow?.creditBytes ?? (peerMaxChunkBytes * peerMaxWindow) }
  // Cumulative ACKs may end within a chunk; credit must fit the entire next chunk.
  var hasSendCredit: Bool {
    let next = min(senderChunkBytes, max(0, (sendingFile?.size ?? sentBytes) - sentBytes))
    return sentBytes - acknowledgedBytes <= sendCreditBytes - next
  }

  var retiredBatches: [String] = []
  var currentBatch: TransferBatch?
  var preparation: Task<([TransferFile], Int64), Error>?
  var preparing = false
  var transferTask: Task<Void, Never>?

  // Sender flow-control & backpressure
  var sentBytes: Int64 = 0
  var acknowledgedBytes: Int64 = 0
  /// When the last cumulative ACK arrived; a receiver-initiated BLE fallback yields to a live LAN.
  var lastAckAt: TimeInterval?
  /// When the current sender stream started, used to give a fresh LAN resume time to produce ACKs.
  var streamStartedAt: TimeInterval?
  var creditResume: (() -> Void)?
  var capacityWaiters: [UUID: () -> Void] = [:]
  var fileResultContinuation: CheckedContinuation<TransferMessage, Error>?
  var receivedFileResult: TransferMessage?
  var sendingFile: TransferFile?
  var senderFileIndex = 0
  @ObservationIgnored lazy var ingress = TransferIngress { [weak self] descriptor, operation, bytes in
    guard let self, self.epoch == operation, let channel = self.channels[descriptor.transport], channel.descriptor == descriptor else { return }
    if await self.handle(bytes, on: descriptor) == .handled, self.epoch == operation { channel.received(bytes) }
  }
  var epoch = UUID() { didSet { ingress.invalidate() } }
  var capacityRevision = 0

  // Logical checkpoints survive process death; channel generations and sealed work remain process-local.
  let pauseTimeout: Duration
  let resumeTimeout: Duration
  let confirmationTimeout: Duration
  let closeSource: @Sendable (FileHandle) throws -> Void
  var pausedTransport: String?
  var pausedFileIndex = 0
  var pausedFileOffset: Int64 = 0
  var pausedCompletedBytes: Int64 = 0
  var pauseTimerTask: Task<Void, Never>?
  var resumeTask: Task<Void, Never>?
  var upgradeTask: Task<Void, Never>?
  var statusWaiter: ((TransferMessage?) -> Void)?
  var statusWaiterToken: UUID?
  var statusTimeoutTask: Task<Void, Never>?
  var statusSubmissionTask: Task<Void, Never>?
  var allowBleResume = false
  var transferPeerDeviceId: String?
  var transferPeerFingerprint: String?

  struct RetainedFileResult {
    let batchId: String
    let fileId: String
    let fileSize: Int64
    let result: TransferMessage
    let peerId: String
    let peerFingerprint: String
  }
  /// The last verified result this receiver sent, replayable when a resume lands after the file.
  var retainedBatch: TransferBatch?
  var offerReplayed = false
  var restoredSender = false
  var retainedFileResult: RetainedFileResult?

  let recoveryStore: TransferRecoveryStore?
  let recoveryIdentity: IdentityService?
  var recoveryTask: Task<Void, Never>?
  var recoveryWrite: Task<Void, Never>?
  var recoveryLocal: String?
  var recoveryPeer: ChannelDescriptor?
  var recoveryReady: Bool
  var pendingChannels: [String: any SecuredChannel] = [:]
  var checkpointAt: TimeInterval = 0
  var checkpointPosition: String?
  var pauseExpiresAt: Date?
  var pauseDeadline: ContinuousClock.Instant?
  let pauseClock = ContinuousClock()
  var resumeAttemptChannel: ChannelDescriptor?
  var nextResumeAttemptAt: TimeInterval = 0
  var interruptedOffer: TransferState?
  var finalizationRetired: ChannelDescriptor?
  var finalizationResumed = false
  var receiptExpiry: Task<Void, Never>?
  var receiptDeadline: ContinuousClock.Instant?
  var failedRecovery: TransferCheckpoint?

  init(pauseTimeout: Duration = .seconds(900), recoveryURL: URL? = nil, identity: IdentityService? = nil,
       resumeTimeout: Duration = .seconds(15), confirmationTimeout: Duration = .seconds(30),
       notificationPreferences: TransferNotificationPreferences = TransferNotificationPreferences(),
       closeSource: @escaping @Sendable (FileHandle) throws -> Void = { try $0.close() }) {
    self.notificationPreferences = notificationPreferences
    precondition(recoveryURL == nil || identity != nil)
    self.pauseTimeout = pauseTimeout
    self.resumeTimeout = resumeTimeout
    self.confirmationTimeout = confirmationTimeout
    self.closeSource = closeSource
    recoveryIdentity = identity
    recoveryStore = recoveryURL.map(TransferRecoveryStore.init)
    recoveryReady = recoveryURL == nil
    if let recoveryStore, let identity {
      recoveryTask = Task { [weak self] in
        guard let self else { return }
        let operation = self.epoch
        do {
          let local = try await identity.publicIdentity().fingerprint
          self.recoveryLocal = local
          if let saved = try await recoveryStore.load(), operation == self.epoch {
            self.failedRecovery = saved
            try await self.restoreRecovery(saved, local: local)
            self.failedRecovery = nil
          }
        } catch { self.state = .failed(reason: "Cannot recover the pending transfer: \(error.localizedDescription)") }
        self.recoveryReady = true
        let pending = self.pendingChannels
        self.pendingChannels.removeAll()
        for channel in pending.values { self.available(channel) }
      }
    }
  }

  /// True from the moment a received file's last chunk lands until it is hashed and published.
  var finalizing = false

  /// Direction of the active or most recently finished batch: true while this Mac receives it. It
  /// deliberately outlives cleanup so a completed panel can still report which way the files moved;
  /// `dismiss()` clears it.
  var receiving = false

  // Receiver state
  struct OfferAssembly {
    let batch: String
    let totalSlices: Int64
    let totalFiles: Int64
    let totalBytes: Int64
    var slices: [Int64: [TransferFile]] = [:]
  }
  var offerAssembly: OfferAssembly?
  var offerTimeout: Task<Void, Never>?
  var destinationFolder: URL?
  var receiverCurrentFileIndex = 0
  var receiverPartFileURL: URL?
  var receiverStorage: TransferReceiveStorage?
  var receiverWrittenBytes: Int64 = 0
  var receiverTotalTransferred: Int64 = 0
  var lastAckedWrittenBytes: Int64 = 0
  var receiverAckChunkBytes: Int64 = 3072
  var ackTask: Task<Void, Never>?
  var ackTimerTask: Task<Void, Never>?
  var lastReceiverUiUpdate: TimeInterval = 0

  deinit {
    progressTask?.cancel()
    if hasSleepAssertion {
      IOPMAssertionRelease(sleepAssertionID)
    }
  }

  @ObservationIgnored nonisolated(unsafe) var progressTask: Task<Void, Never>?
  var progressRate = TransferRate()
  var progressEpoch: UUID?
  var progressSampleAt: TimeInterval = 0
  var progressSpeed: Double = 0

  // MARK: - FeatureHandler conformance

  func available(_ channel: any SecuredChannel) {
    let transport = channel.descriptor.transport
    guard transport == "lan" || transport == "ble" else { return }
    guard recoveryReady else { pendingChannels[transport] = channel; return }
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
      let versions: [Int64] = chunkSize > 262016 ? [2, 3, 4] : chunkSize > 131072 ? [2, 3] : [chunkSize > 3072 ? 2 : 1]
      for version in versions {
        guard self.channels[transport]?.descriptor == channel.descriptor else { return }
        let chunk = version == 2 ? min(131072, chunkSize) : version == 3 ? min(262016, chunkSize) : chunkSize
        do {
          let data = try TransferMessage.capability(version: version, maxChunkBytes: Int64(chunk),
            maxWindow: transport == "ble" ? 4 : chunk > 3072 ? 8 : 64).encode(maximumChunkBytes: chunkSize)
          try await self.sendWithBackpressure(data, on: channel, jobBound: false)
        } catch { return }
      }
    }
  }

  func retired(_ descriptor: ChannelDescriptor) {
    if pendingChannels[descriptor.transport]?.descriptor == descriptor { pendingChannels[descriptor.transport] = nil }
    guard channels[descriptor.transport]?.descriptor == descriptor else { return }
    ingress.invalidate(descriptor)
    channels.removeValue(forKey: descriptor.transport)
    capabilities.removeValue(forKey: descriptor.transport)
    rendezvousWait?()
    clearCapacityWaiters()
    guard descriptor == activeChannel?.descriptor else {
      refreshPausedCapability()
      return
    }
    let previous = state
    recoveryPeer = descriptor
    activeChannel = nil
    peerConnected = false
    peerCompatible = false
    if case .transferring = previous, finalizing {
      finalizationRetired = descriptor
    } else if case .transferring(let batch, _, _, _, _, _, _) = previous {
      pauseTransfer(batch: batch, transport: descriptor.transport)
    } else if case .incomingOffer = previous {
      pauseOffer(previous, descriptor: descriptor)
    } else if case .waitingForPeerApproval = previous {
      pauseOffer(previous, descriptor: descriptor)
    } else if preparing {
      // Source hashing belongs to the pending send, not the channel that started it.
    } else if case .paused = previous {
      // A resume attempt lost its channel before it completed; keep the retained prefix.
      epoch = UUID()
      resumeTask?.cancel(); resumeTask = nil
      abandonStatus()
      startPauseTimer()
    } else if isBusy {
      state = .failed(reason: "Connection closed. Send the files again using the remaining connection.")
      cleanupActiveTransfer()
    } else {
      cleanupActiveTransfer()
    }
    selectPreferredChannel()
  }

  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    guard channels[descriptor.transport]?.descriptor == descriptor else { return }
    clearCapacityWaiters()
    guard descriptor == activeChannel?.descriptor else { return }
    checkCreditAndResume()
    flushAck()
    if isPaused, !resumeInterruptedOffer() {
      if receiving { if allowBleResume { requestPeerContinuation() } } else { attemptResume() }
    }
  }

  func ingest(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    let kind = TransferMessage.peekKind(bytes)
    if kind == 10, !(await ingress.drain()) { retired(descriptor); return .discarded }
    // Receiver takeover shares the chunk consumer so later old-channel writes cannot cross it.
    guard kind == 5 || (kind == 10 && receiving) else { return await handle(bytes, on: descriptor) }
    let operation = epoch
    // Peer limits describe its receiver; this FIFO must cover our advertised receive credit.
    let chunk = chunkLimit(descriptor)
    let window = descriptor.transport == "ble" ? 4 : chunk > 3072 ? 8 : 64
    let accepted = await ingress.enqueue(bytes, on: descriptor, epoch: operation,
      byteLimit: min(chunk * window + 65536, 2 * 1024 * 1024), recordLimit: min(64, window * 8)) { [weak self] in
        self?.epoch == operation && self?.channels[descriptor.transport]?.descriptor == descriptor
      }
    return accepted ? .queued : .discarded
  }

  func drain(_ descriptor: ChannelDescriptor) async {
    guard channels[descriptor.transport]?.descriptor == descriptor else { return }
    if !(await ingress.drain(descriptor)) { retired(descriptor) }
  }

  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    if !recoveryReady { await recoveryTask?.value }
    let operation = epoch
    let limit = chunkLimit(descriptor)
    let message: TransferMessage
    // Only the FIFO worker decodes chunks; mutable transfer state stays on MainActor.
    let decode = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let decoded = try TransferMessage.decode(bytes, maximumChunkBytes: limit)
      try Task.checkCancellation()
      return decoded
    }
    do {
      guard let decoded = try await withTaskCancellationHandler(operation: { try await decode.value }, onCancel: { decode.cancel() }) else { return .unrecognized }
      message = decoded
    }
    catch is CancellationError { return .discarded }
    catch is TransferWireError { return .discarded }
    catch { return .unrecognized }
    guard !Task.isCancelled, operation == epoch, channels[descriptor.transport]?.descriptor == descriptor else { return .discarded }
    if message.kind == 1 {
      capabilities[descriptor.transport] = message
      if descriptor.transport == "lan" { rendezvousWait?() }
      if !isBusy || isPaused { selectPreferredChannel() }
      if descriptor == activeChannel?.descriptor {
        peerCompatible = true
        if !isTransferring, transferTask == nil { applyCapability(message) }
        if isPaused {
          if resumeInterruptedOffer() { return .handled }
          refreshPausedCapability()
          if receiving { if allowBleResume { requestPeerContinuation() } } else { attemptResume() }
        }
      } else if isPaused {
        refreshPausedCapability()
        if activeChannel?.descriptor.transport == "lan", peerCompatible {
          if receiving { if allowBleResume { requestPeerContinuation() } } else { attemptResume() }
        }
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
      await processMessage(message, peerName: descriptor.peer.deviceName, on: descriptor)
      return .handled
    }
    if message.kind == 2, message.string(0) == currentBatch?.idString || message.string(0) == retainedBatch?.idString {
      await processMessage(message, peerName: descriptor.peer.deviceName, on: descriptor)
      return .handled
    }
    guard descriptor == activeChannel?.descriptor else { return .discarded }
    if message.kind == 5 { return await handleChunk(message) }
    await processMessage(message, peerName: descriptor.peer.deviceName, on: descriptor)
    return .handled
  }

}
