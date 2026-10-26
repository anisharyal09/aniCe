// SPDX-License-Identifier: GPL-3.0-or-later
// Coordinates bidirectional file transfer batches, cumulative flow control and sleep assertions over LAN-preferred authenticated LAN/BLE channels.
import Foundation
import Darwin
import Observation
import CryptoKit
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
  private(set) var state: TransferState = .idle {
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
  private(set) var activeChannel: (any SecuredChannel)?
  private(set) var peerConnected = false
  private(set) var peerCompatible = false
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
  private(set) var publishedURLs: [URL] = []

  /// Destination folder of the active or most recently finished receive operation.
  /// Deliberately outlives cleanup so a completed panel can report where files were saved;
  /// `dismiss()` clears it.
  private(set) var receiveFolder: URL?
  private var channels: [String: any SecuredChannel] = [:]
  private var capabilities: [String: TransferMessage] = [:]
  private var rendezvousWait: (() -> Void)?
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
  private var sendWindow: TransferSendWindow?
  private var senderChunkBytes: Int64 { sendWindow?.chunkBytes ?? peerMaxChunkBytes }
  private var sendCreditBytes: Int64 { sendWindow?.creditBytes ?? (peerMaxChunkBytes * peerMaxWindow) }
  // Cumulative ACKs may end within a chunk; credit must fit the entire next chunk.
  private var hasSendCredit: Bool {
    let next = min(senderChunkBytes, max(0, (sendingFile?.size ?? sentBytes) - sentBytes))
    return sentBytes - acknowledgedBytes <= sendCreditBytes - next
  }


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
  @ObservationIgnored private lazy var ingress = TransferIngress { [weak self] descriptor, operation, bytes in
    guard let self, self.epoch == operation, let channel = self.channels[descriptor.transport], channel.descriptor == descriptor else { return }
    if await self.handle(bytes, on: descriptor) == .handled, self.epoch == operation { channel.received(bytes) }
  }
  private var epoch = UUID() { didSet { ingress.invalidate() } }
  private var capacityRevision = 0

  // Logical checkpoints survive process death; channel generations and sealed work remain process-local.
  private let pauseTimeout: Duration
  private let resumeTimeout: Duration
  private let confirmationTimeout: Duration
  private let closeSource: @Sendable (FileHandle) throws -> Void
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
  private var statusSubmissionTask: Task<Void, Never>?
  private var allowBleResume = false
  private var transferPeerDeviceId: String?
  private var transferPeerFingerprint: String?

  private struct RetainedFileResult {
    let batchId: String
    let fileId: String
    let fileSize: Int64
    let result: TransferMessage
    let peerId: String
    let peerFingerprint: String
  }
  /// The last verified result this receiver sent, replayable when a resume lands after the file.
  private var retainedBatch: TransferBatch?
  private var offerReplayed = false
  private var restoredSender = false
  private var retainedFileResult: RetainedFileResult?

  private let recoveryStore: TransferRecoveryStore?
  private let recoveryIdentity: IdentityService?
  private var recoveryTask: Task<Void, Never>?
  private var recoveryWrite: Task<Void, Never>?
  private var recoveryLocal: String?
  private var recoveryPeer: ChannelDescriptor?
  private var recoveryReady: Bool
  private var pendingChannels: [String: any SecuredChannel] = [:]
  private var checkpointAt: TimeInterval = 0
  private var checkpointPosition: String?
  private var pauseExpiresAt: Date?
  private var pauseDeadline: ContinuousClock.Instant?
  private let pauseClock = ContinuousClock()
  private var resumeAttemptChannel: ChannelDescriptor?
  private var nextResumeAttemptAt: TimeInterval = 0
  private var interruptedOffer: TransferState?
  private var finalizationRetired: ChannelDescriptor?
  private var finalizationResumed = false
  private var receiptExpiry: Task<Void, Never>?
  private var receiptDeadline: ContinuousClock.Instant?
  private var failedRecovery: TransferCheckpoint?

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

  private func checkpoint(force: Bool = false, publishingIdentity: String? = nil) {
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

  private func restoreRecovery(_ snapshot: TransferCheckpoint, local: String) async throws {
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
      let versions: [Int64] = chunkSize > 131072 ? [2, 3] : [chunkSize > 3072 ? 2 : 1]
      for version in versions {
        guard self.channels[transport]?.descriptor == channel.descriptor else { return }
        let chunk = version == 2 ? min(131072, chunkSize) : chunkSize
        do {
          let data = try TransferMessage.capability(version: version, maxChunkBytes: Int64(chunk),
            maxWindow: transport == "ble" ? 4 : chunk > 3072 ? 8 : 64).encode(maximumChunkBytes: chunkSize)
          try await self.sendWithBackpressure(data, on: channel, jobBound: false)
        } catch { return }
      }
    }
  }

  var isPaused: Bool {
    if case .paused = state { return true }
    return false
  }

  private func selectPreferredChannel(preparingRoute: Bool = false) {
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

  private func applyCapability(_ message: TransferMessage) {
    peerCompatible = true
    let localLimit = Int64(chunkLimit(activeChannel?.descriptor))
    let negotiatedLimit: Int64 = message.number(0) == 3 ? localLimit : message.number(0) == 2 ? min(131072, localLimit) : 3072
    peerMaxChunkBytes = min(message.number(1), negotiatedLimit)
    peerMaxWindow = min(message.number(2), activeChannel?.descriptor.transport == "ble" ? 4 : peerMaxChunkBytes > 3072 ? 8 : 64)
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

  // MARK: - Message Processing

  private func processMessage(_ message: TransferMessage, peerName: String, on descriptor: ChannelDescriptor) async {
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

  // MARK: - Pause and Resume

  private func expirePausedIfNeeded() -> Bool {
    guard isPaused, let deadline = pauseDeadline, pauseClock.now >= deadline else { return false }
    failTransfer(reason: "Transfer paused for too long without a connection. Send the files again.")
    return true
  }

  private func claimResumeAttempt(_ descriptor: ChannelDescriptor) -> Bool {
    let now = ProcessInfo.processInfo.systemUptime
    if resumeAttemptChannel == descriptor, now < nextResumeAttemptAt { return false }
    resumeAttemptChannel = descriptor; nextResumeAttemptAt = now + 2
    return true
  }

  private func pauseOnConfirmationTimeout() {
    guard case .transferring(let batch, _, _, _, _, _, _) = state, let channel = activeChannel else { return }
    pauseTransfer(batch: batch, transport: channel.descriptor.transport)
    selectPreferredChannel()
  }

  private func pauseOffer(_ previous: TransferState, descriptor: ChannelDescriptor) {
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

  private func resumeInterruptedOffer() -> Bool {
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

  private var isTransferring: Bool {
    if case .transferring = state { return true }
    return false
  }

  /// Retains a mid-stream batch after its active channel retired. Nothing is published, discarded
  /// or released here: the partial, destination and sleep assertion stay alive for `pauseTimeout`,
  /// and only Cancel, a permanent recovery failure or the timer ends them.
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

  private func startPauseTimer() {
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
  private func requestPeerContinuation() {
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

  private func handleStatus(_ message: TransferMessage) {
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

  private func abandonStatus() {
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
  private func handleResume(_ message: TransferMessage, on descriptor: ChannelDescriptor) async {
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

  private func bindResumeChannel(_ channel: any SecuredChannel) {
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
  private func handlePeerResume(
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

  private func awaitLan(operation: UUID) async {
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

  func sendFiles(urls: [URL]) async {
    guard !isBusy, !Task.isCancelled, preparation == nil, transferTask == nil else { return }
    guard (1...128).contains(urls.count) else {
      state = .failed(reason: "Transfer batch must contain 1 to 128 files")
      return
    }
    selectPreferredChannel()
    let operation = epoch
    // Reserve the job and its peer before rendezvous or identity reads can suspend.
    preparing = true
    transferPeerDeviceId = activeChannel?.descriptor.peer.deviceId
    transferPeerFingerprint = activeChannel?.descriptor.peer.fingerprint
    defer { if operation == epoch { preparing = false } }
    let requestedLan = activeChannel?.descriptor.transport != "lan" && onLanRequired()
    if requestedLan { await awaitLan(operation: operation) }
    guard operation == epoch else { return }
    guard !Task.isCancelled else { cancelTransfer(); return }
    selectPreferredChannel(preparingRoute: true)
    guard let initialChannel = activeChannel, peerConnected else {
      failTransfer(reason: "No secured local-network or Bluetooth connection")
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

    // Hashing can outlast the rendezvous wait; adopt a LAN channel that became capable meanwhile.
    selectPreferredChannel(preparingRoute: true)
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

  private func sendOfferBatch(_ batch: TransferBatch, channel: any SecuredChannel) async {
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

  private func handleAccept(_ message: TransferMessage) {
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

  private func streamAcceptedBatch(_ batch: TransferBatch) async {
    await streamBatchFrom(batch, startFileIndex: 0, startOffset: 0, completedBefore: 0)
  }

  /// Streams from `startFileIndex` at `startOffset`, where the receiver already retains
  /// `startOffset` bytes of that file and `completedBefore` complete bytes precede it.
  private func streamBatchFrom(_ batch: TransferBatch, startFileIndex: Int, startOffset: Int64, completedBefore: Int64, recovered: Bool = false) async {
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
          sendWindow?.beginSubmission(ProcessInfo.processInfo.systemUptime, windowEmpty: sentBytes == acknowledgedBytes)
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

  private func handleAck(_ message: TransferMessage) {
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

  private func resumeCredit() {
    // Detach before waking so cleanup cannot clear a successor's credit wait.
    let waiting = creditResume
    creditResume = nil
    waiting?()
  }

  private func checkCreditAndResume() {
    if hasSendCredit { resumeCredit() }
  }

  private func handleReject(_ message: TransferMessage) {
    guard case .waitingForPeerApproval(let batch) = state,
          message.string(0) == batch.idString else { return }
    state = .rejected(batchId: batch.id, reason: message.number(1))
    cleanupActiveTransfer()
  }

  // MARK: - Receiver Flow

  private func handleOffer(_ message: TransferMessage, peerName: String, on descriptor: ChannelDescriptor) {
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

  private func clearOfferAssembly() {
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
      var submitted = false
      defer {
        if self.epoch == operation && self.receiverCurrentFileIndex == fileIndex {
          self.ackTask = nil
          let unacked = self.receiverWrittenBytes - self.lastAckedWrittenBytes
          // ACK before the credit window fills: a quarter-window on large LAN chunks, half on BLE.
          let ackCadence = self.peerMaxChunkBytes > 3072 ? max(1, self.peerMaxWindow / 4) : min(8, max(1, self.peerMaxWindow / 2))
          // Failure waits for an external event; only success may drain newer credit.
          if submitted && (unacked >= ackCadence * self.peerMaxChunkBytes || (self.receiverWrittenBytes == currentFile.size && self.receiverWrittenBytes > self.lastAckedWrittenBytes)) {
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

  private func handleChunk(_ message: TransferMessage) async -> DataHandling {
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

    // ACK before the credit window fills: a quarter-window on large LAN chunks, half on BLE.
    let unacked = receiverWrittenBytes - lastAckedWrittenBytes
    let ackCadence = peerMaxChunkBytes > 3072 ? max(1, peerMaxWindow / 4) : min(8, max(1, peerMaxWindow / 2))
    if unacked >= ackCadence * peerMaxChunkBytes || receiverWrittenBytes == currentFile.size {
      flushAck()
    } else if receiverWrittenBytes > lastAckedWrittenBytes {
      scheduleAckTimer()
    }

    if receiverWrittenBytes == currentFile.size { await finalizeReceiverFile(batch) }
    return .handled
  }

  private func finalizeReceiverFile(_ batch: TransferBatch) async {
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

  private func completeReceiver(_ batch: TransferBatch) {
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

  private func expireReceipt(_ batchId: String, after remaining: TimeInterval) {
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

// Each received file has one storage actor; checked writes precede ACK credit.
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
    let started = SessionTiming.start()
    defer { SessionTiming.end(self, "storage_create", started, direction: "receive") }
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
    let started = SessionTiming.start()
    defer { SessionTiming.end(self, "storage_write", started, bytes: data.count, direction: "receive") }
    assert(!Thread.isMainThread)
    try Task.checkCancellation()
    guard let handle else { throw CocoaError(.fileWriteUnknown) }
    try handle.write(contentsOf: data)
    hasher.update(data: data)
  }

  func flush() throws {
    let started = SessionTiming.start()
    defer { SessionTiming.end(self, "storage_flush", started, direction: "receive") }
    try handle?.synchronize()
  }

  func fileIdentity() throws -> String {
    let started = SessionTiming.start()
    defer { SessionTiming.end(self, "storage_fileIdentity", started, direction: "receive") }
    guard let partial else { throw CocoaError(.fileReadUnknown) }
    return try Self.identity(partial)
  }

  private static func identity(_ url: URL) throws -> String {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let device = attributes[.systemNumber] as? NSNumber,
      let inode = attributes[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
    return "\(device):\(inode)"
  }

  static func discardOwned(folder: URL, partial: URL, batch: String, file: String) throws {
    guard FileManager.default.fileExists(atPath: partial.path) else { return }
    guard partial.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path,
      partial.lastPathComponent.hasPrefix(".anice-\(batch)-\(file)-"), partial.pathExtension == "part",
      try partial.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { throw CocoaError(.fileReadCorruptFile) }
    try FileManager.default.removeItem(at: partial)
  }

  static func published(folder: URL, file: TransferFile, identity expected: String) throws -> URL? {
    var ambiguous = false, checked = 0
    for suffix in 0..<TransferPublisher.maximumSuffix {
      let target = folder.appendingPathComponent(TransferPublisher.suffixed(file.name, suffix))
      guard FileManager.default.fileExists(atPath: target.path),
        try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { continue }
      let owned = try !expected.isEmpty && identity(target) == expected
      guard try target.resourceValues(forKeys: [.fileSizeKey]).fileSize.map({ Int64($0) }) == file.size else {
        if owned { throw CocoaError(.fileReadCorruptFile) }
        continue
      }
      if !owned { checked += 1; if checked > 32 { ambiguous = true; continue } }
      let reader = try FileHandle(forReadingFrom: target)
      defer { try? reader.close() }
      var digest = SHA256(), size: Int64 = 0
      while let bytes = try reader.read(upToCount: 131072), !bytes.isEmpty {
        digest.update(data: bytes); size += Int64(bytes.count)
      }
      guard size == file.size, Data(digest.finalize()) == file.sha256 else {
        if owned { throw CocoaError(.fileReadCorruptFile) }
        continue
      }
      if owned { return target }
      ambiguous = true
    }
    if ambiguous { throw NSError(domain: "aniCe.TransferRecovery", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "The file may already be saved. Check the destination before sending it again."]) }
    return nil
  }

  func restore(folder: URL, partial: URL, batch: String, file: String, length: Int64) throws {
    let started = SessionTiming.start()
    defer { SessionTiming.end(self, "storage_restore", started, direction: "receive") }
    guard length >= 0,
      partial.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path,
      partial.lastPathComponent.hasPrefix(".anice-\(batch)-\(file)-"), partial.pathExtension == "part",
      try partial.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { throw CocoaError(.fileReadCorruptFile) }
    let descriptor = open(partial.path, O_RDWR | O_NOFOLLOW)
    guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
    let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      var remaining = length
      while remaining > 0 {
        guard let bytes = try writer.read(upToCount: Int(min(remaining, 1 << 20))), !bytes.isEmpty else {
          throw CocoaError(.fileReadCorruptFile)
        }
        hasher.update(data: bytes); remaining -= Int64(bytes.count)
      }
      try writer.truncate(atOffset: UInt64(length))
      try writer.seek(toOffset: UInt64(length))
    } catch { try? writer.close(); throw error }
    self.folder = folder; self.partial = partial; handle = writer
  }

  /// Flushes and hashes exactly `length` bytes of the retained partial. The receiver sends this
  /// digest so the sender can prove its own source prefix before switching transports.
  func prefixDigest(_ length: Int64) throws -> Data {
    let started = SessionTiming.start()
    defer { SessionTiming.end(self, "storage_prefixDigest", started, direction: "receive") }
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
    let started = SessionTiming.start()
    defer { SessionTiming.end(self, "storage_finish", started, direction: "receive") }
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
    let started = SessionTiming.start()
    defer { SessionTiming.end(self, "storage_discard", started, direction: "receive") }
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
  private let closeHandle: @Sendable (FileHandle) throws -> Void
  private init(_ url: URL, close: @escaping @Sendable (FileHandle) throws -> Void) throws {
    handle = try FileHandle(forReadingFrom: url); closeHandle = close
  }
  static func open(_ url: URL, skipping offset: Int64 = 0,
    close: @escaping @Sendable (FileHandle) throws -> Void) async throws -> TransferSendStorage {
    let storage = try await Task.detached { try TransferSendStorage(url, close: close) }.value
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
    do { try closeHandle(handle) } catch { NSLog("Transfer source close failed: %@", error.localizedDescription) }
  }
}

// Checkpoints contain logical work and file references; fresh channels always authenticate independently.
struct TransferCheckpoint: Codable, Sendable {
  var version = 1
  let localFingerprint: String
  let peerId: String
  let peerFingerprint: String
  let batch: TransferBatch
  let receiving: Bool
  var index: Int
  var offset: Int64
  let folder: URL?
  var partial: URL?
  let transport: String
  let expiresAt: Date
  var stage = 0
  var fileIdentity = ""

  func validate() throws {
    let hex = Set("0123456789abcdef")
    guard version == 1, localFingerprint.count == 64, peerFingerprint.count == 64,
      localFingerprint.allSatisfy({ hex.contains($0) }), peerFingerprint.allSatisfy({ hex.contains($0) }),
      UUID(uuidString: peerId) != nil, (1...128).contains(batch.files.count),
      batch.files.indices.contains(index), Set(batch.files.map(\.id)).count == batch.files.count,
      offset >= 0, offset <= batch.files[index].size, ["lan", "ble"].contains(transport),
      expiresAt.timeIntervalSince1970.isFinite, (0...4).contains(stage) else { throw CocoaError(.fileReadCorruptFile) }
    var total: Int64 = 0
    for file in batch.files {
      guard file.size >= 0, file.sha256.count == 32, (1...255).contains(file.name.utf8.count),
        file.name != ".", file.name != "..", !file.name.contains("/"), !file.name.contains("\\"),
        !file.name.unicodeScalars.contains(where: { $0.value < 32 }),
        file.localURL == nil || file.localURL?.isFileURL == true else { throw CocoaError(.fileReadCorruptFile) }
      let next = total.addingReportingOverflow(file.size)
      guard !next.overflow else { throw CocoaError(.fileReadCorruptFile) }
      total = next.partialValue
    }
    guard total == batch.totalBytes else { throw CocoaError(.fileReadCorruptFile) }
    guard stage != 1 || !receiving, stage != 2 || receiving,
      stage != 3 || (receiving && index == batch.files.count - 1 && offset == batch.files[index].size),
      stage != 4 || (receiving && offset == batch.files[index].size) else { throw CocoaError(.fileReadCorruptFile) }
  }
}

actor TransferRecoveryStore {
  private let url: URL
  init(_ url: URL) { self.url = url }

  func load() throws -> TransferCheckpoint? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard (1...1048576).contains(size) else { throw CocoaError(.fileReadCorruptFile) }
    let saved = try JSONDecoder().decode(TransferCheckpoint.self, from: Data(contentsOf: url))
    try saved.validate()
    return saved
  }

  func save(_ snapshot: TransferCheckpoint) throws {
    try snapshot.validate()
    let bytes = try JSONEncoder().encode(snapshot)
    guard bytes.count <= 1048576 else { throw CocoaError(.fileWriteUnknown) }
    let folder = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = folder.appendingPathComponent("checkpoint-\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close()
      guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    } catch {
      try? handle.close()
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  func clear() throws {
    if unlink(url.path) != 0, errno != ENOENT { throw CocoaError(.fileWriteUnknown) }
  }
}

// MainActor owns admission and accounting; one FIFO consumer orders chunks, receiver resumes and storage awaits.
@MainActor final class TransferIngress {
  private struct Entry { let descriptor: ChannelDescriptor; let epoch: UUID; let bytes: Data }
  private let consume: @MainActor (ChannelDescriptor, UUID, Data) async -> Void
  private var pending: [Entry] = []
  private var worker: Task<Void, Never>?
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private var active: ChannelDescriptor?
  private var count = 0
  private var bytes = 0
  init(consume: @escaping @MainActor (ChannelDescriptor, UUID, Data) async -> Void) { self.consume = consume }
  // Capacity includes the active write until it completes, not merely entries still in FIFO.
  func enqueue(_ data: Data, on descriptor: ChannelDescriptor, epoch: UUID,
    byteLimit: Int, recordLimit: Int, live: () -> Bool) async -> Bool {
    guard data.count <= byteLimit else { return false }
    let started = SessionTiming.start()
    while live(), !Task.isCancelled {
      if count < recordLimit, bytes <= byteLimit - data.count {
        SessionTiming.end(self, "transfer_ingress_admission", started, bytes: data.count,
          profile: descriptor.maximumDataBytes > 4000 ? 3 : 1, direction: "receive")
        pending.append(Entry(descriptor: descriptor, epoch: epoch, bytes: data))
        count += 1; bytes += data.count
        startWorker()
        return true
      }
      await changed()
    }
    return false
  }
  private func startWorker() {
    guard worker == nil, !pending.isEmpty else { return }
    // A successor epoch must not inherit the cancelled consumer's task context.
    worker = Task { @MainActor in await self.run() }
  }
  private func run() async {
    defer { worker = nil; startWorker(); wake() }
    while !Task.isCancelled, !pending.isEmpty {
      let next = pending.removeFirst()
      active = next.descriptor
      let started = SessionTiming.start()
      await consume(next.descriptor, next.epoch, next.bytes)
      SessionTiming.end(self, "transfer_ingress_delivery", started, bytes: next.bytes.count,
        profile: next.descriptor.maximumDataBytes > 4000 ? 3 : 1, direction: "receive")
      active = nil; count -= 1; bytes -= next.bytes.count; wake()
    }
  }
  func invalidate(_ descriptor: ChannelDescriptor? = nil) {
    pending.removeAll { next in
      guard descriptor == nil || next.descriptor == descriptor else { return false }
      count -= 1; bytes -= next.bytes.count; return true
    }
    // Actor entry checks cancellation before writing; a synchronous write already running may finish.
    if active != nil, descriptor == nil || active == descriptor { worker?.cancel() }
    wake()
  }
  func drain(_ descriptor: ChannelDescriptor? = nil, timeout: Duration = .seconds(10)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    let timer = Task { [weak self] in
      do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
      self?.wake()
    }
    defer { timer.cancel() }
    func hasWork() -> Bool {
      guard let descriptor else { return count > 0 }
      return active == descriptor || pending.contains { $0.descriptor == descriptor }
    }
    while hasWork(), !Task.isCancelled, ContinuousClock.now < deadline { await changed() }
    return !hasWork()
  }
  private func changed() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled { continuation.resume() } else { waiters[id] = continuation }
      }
    } onCancel: { Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume() } }
  }
  private func wake() {
    let current = waiters.values; waiters.removeAll()
    for waiter in current { waiter.resume() }
  }
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
      lastAcknowledgedAt = now
    }
  }
  // Only advancing, correlated ACKs reach this method; duplicates cannot qualify a fast path.
  mutating func acknowledged(_ now: TimeInterval, fullyConfirmed: Bool) {
    if probing && !fullyConfirmed { return }
    let elapsed = now - lastAcknowledgedAt
    // Compare at nanosecond precision rather than floating-point subtraction noise at 100 ms.
    if probing { if decision == nil { decision = (elapsed * 1_000_000_000).rounded() > 100_000_000 } }
    else if constrained {
      if now - probeStartedAt >= 5 {
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
