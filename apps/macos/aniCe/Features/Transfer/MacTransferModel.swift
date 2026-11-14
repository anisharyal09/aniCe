// SPDX-License-Identifier: GPL-3.0-or-later
// Coordinates transfer state, channel routing, user actions and lifecycle.

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

struct TransferRecipient: Equatable, Sendable {
  let deviceId: String
  let fingerprint: String
  let deviceName: String

  init(peer: DeviceIdentity) {
    deviceId = peer.deviceId
    fingerprint = peer.fingerprint
    deviceName = peer.deviceName
  }

  func matches(_ peer: DeviceIdentity) -> Bool {
    deviceId == peer.deviceId && fingerprint == peer.fingerprint
  }
}

enum TransferTransportPolicy: Equatable, Sendable {
  case preferAvailable
  case preferLanWithChoice
  case bluetooth
}

@MainActor struct PendingTransferRouteSelection {
  // Keep the original destination and file grant together while the user chooses a route.
  let urls: [URL]
  let recipient: TransferRecipient
  let fileAccess: TransferFileAccessLease?
  var message: String
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

struct MacPendingAutomaticReceive {
  // Keep offer-time consent and destination stable across preparation and reconnects.
  let batchId: UUID
  let peerId: String
  let peerFingerprint: String
  let destination: TransferReceiveDestinationSelection
}

enum TransferEvent: Equatable {
  case incomingOffer(TransferBatch)
  /// A paused batch, emitted for both directions so the notification can offer Cancel; the
  /// Bluetooth continuation is a sender-only action.
  case paused(batch: TransferBatch, reason: String, canResumeOverBle: Bool)
  case resumed
  case completed(fileCount: Int, totalBytes: Int64)
  /// A verified send that started from Edge Drop, scoped to its reservation for shelf feedback.
  case sentFromDrop(reservation: UUID, batch: TransferBatch)
  case failed(reason: String)
}

@Observable @MainActor final class MacTransferModel: FeatureHandler {
  let notificationPreferences: TransferNotificationPreferences
  let autoReceivePreferences: TransferAutoReceivePreferences
  let receiveDestinationPreferences: TransferReceiveDestinationPreferences
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
  var dropStatus: String?
  var receiveDestinationError: String?
  var autoReceivePreparing = false
  var automaticReceiveTask: Task<Void, Never>?
  var pendingAutomaticReceive: MacPendingAutomaticReceive?
  var dropReservation: UUID?
  var dropSourceID: UUID?
  var dropFileAccess: TransferFileAccessLease?
  var pendingRouteSelection: PendingTransferRouteSelection?
  var preferBluetoothForCurrentTransfer = false
  /// External event sink for native notification and Edge Drop bridges. Completed and failed are
  /// emitted only when receiving; a verified send emits sentFromDrop instead.
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
    if preparing || offerAssembly != nil || pendingRouteSelection != nil { return true }
    switch state {
    case .incomingOffer, .waitingForPeerApproval, .transferring, .paused: return true
    default: return false
    }
  }

  var connectedAndroidRecipient: TransferRecipient? {
    guard peerConnected, peerCompatible, let peer = activeChannel?.descriptor.peer,
      peer.platform == "android" else { return nil }
    return TransferRecipient(peer: peer)
  }

  func reserveDrop(for recipient: TransferRecipient) -> UUID? {
    guard !isBusy, preparation == nil, transferTask == nil else {
      dropStatus = "A transfer is already in progress. Try again when it finishes."
      return nil
    }
    guard let current = activeChannel?.descriptor.peer, peerConnected, peerCompatible,
      recipient.matches(current), current.platform == "android" else {
      dropStatus = "The connected phone changed. Drop the files again."
      return nil
    }
    let reservation = UUID()
    dropReservation = reservation
    dropSourceID = reservation
    preparing = true
    dropStatus = nil
    return reservation
  }

  func failDrop(reservation: UUID, message: String) {
    guard dropReservation == reservation else { return }
    dropReservation = nil
    dropSourceID = nil
    preparing = false
    dropStatus = message
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
       autoReceivePreferences: TransferAutoReceivePreferences = TransferAutoReceivePreferences(),
       receiveDestinationPreferences: TransferReceiveDestinationPreferences = TransferReceiveDestinationPreferences(),
       closeSource: @escaping @Sendable (FileHandle) throws -> Void = { try $0.close() }) {
    self.notificationPreferences = notificationPreferences
    self.autoReceivePreferences = autoReceivePreferences
    self.receiveDestinationPreferences = receiveDestinationPreferences
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
    let peerId: String
    let peerFingerprint: String
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
    } else if pendingRouteSelection != nil {
      dropStatus = "Connection to the selected phone was lost. Retry when it reconnects, or cancel."
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

// MARK: - Channel routing

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

  func selectPreferredChannel(preparingRoute: Bool = false, preferredTransport: String? = nil) {
    // A live batch remains bound to its channel generation. A paused batch, by contrast, must
    // adopt a newly secured channel so the retained prefix can continue there.
    // A pending route keeps the recipient pinned but may adopt a replacement channel for that peer.
    let canRebind = !isBusy || isPaused || preparingRoute || pendingRouteSelection != nil
    guard activeChannel == nil || canRebind else { return }
    let preferred: (any SecuredChannel)?
    if let preferredTransport {
      preferred = channels[preferredTransport]
    } else {
      preferred = ["lan", "ble"].first(where: { channels[$0] != nil && capabilities[$0] != nil })
        .flatMap { channels[$0] } ?? channels["lan"] ?? channels["ble"]
    }
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

// MARK: - Lifecycle and cleanup

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
    automaticReceiveTask?.cancel(); automaticReceiveTask = nil
    autoReceivePreparing = false
    pendingAutomaticReceive = nil
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
    dropReservation = nil
    dropSourceID = nil
    pendingRouteSelection?.fileAccess?.release(); pendingRouteSelection = nil
    preferBluetoothForCurrentTransfer = false
    dropFileAccess?.release(); dropFileAccess = nil
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
