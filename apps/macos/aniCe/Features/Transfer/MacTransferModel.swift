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
  case completed(batchId: UUID, fileCount: Int, totalBytes: Int64)
  case rejected(batchId: UUID, reason: Int64)
  case failed(reason: String)
  case cancelled
}

@Observable @MainActor final class MacTransferModel: FeatureHandler {
  private(set) var state: TransferState = .idle
  private(set) var activeChannel: (any SecuredChannel)?
  private(set) var peerConnected = false
  private(set) var peerCompatible = false
  private var channels: [String: any SecuredChannel] = [:]
  private var capabilities: [String: TransferMessage] = [:]
  private var isBusy: Bool {
    if preparing || offerAssembly != nil { return true }
    switch state {
    case .incomingOffer, .waitingForPeerApproval, .transferring: return true
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
  private var creditResume: (() -> Void)?
  private var capacityWaiters: [UUID: () -> Void] = [:]
  private var fileResultContinuation: CheckedContinuation<TransferMessage, Error>?
  private var receivedFileResult: TransferMessage?
  private var sendingFile: TransferFile?
  private var epoch = UUID()
  private var capacityRevision = 0

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
  private var receiverRate = TransferRate()
  private var lastReceiverUiUpdate: TimeInterval = 0

  deinit {
    if hasSleepAssertion {
      IOPMAssertionRelease(sleepAssertionID)
    }
  }

  // MARK: - FeatureHandler conformance

  private func chunkLimit(_ descriptor: ChannelDescriptor?) -> Int {
    descriptor?.transport == "lan" && (descriptor?.maximumDataBytes ?? 4000) >= 262144 ? 131072 : 3072
  }

  func available(_ channel: any SecuredChannel) {
    let transport = channel.descriptor.transport
    guard transport == "lan" || transport == "ble" else { return }
    if let peer = activeChannel?.descriptor.peer {
      guard peer.deviceId == channel.descriptor.peer.deviceId,
            peer.fingerprint == channel.descriptor.peer.fingerprint else { return }
    }
    guard channels[transport]?.descriptor != channel.descriptor else { return }
    if let old = channels[transport] { retired(old.descriptor) }
    channels[transport] = channel
    selectPreferredChannel()
    Task {
      guard self.channels[transport]?.descriptor == channel.descriptor else { return }
      if let data = try? TransferMessage.capability(version: self.chunkLimit(channel.descriptor) > 3072 ? 2 : 1,
        maxChunkBytes: Int64(self.chunkLimit(channel.descriptor)), maxWindow: self.chunkLimit(channel.descriptor) > 3072 ? 8 : 64).encode(maximumChunkBytes: self.chunkLimit(channel.descriptor)) { try? await self.sendWithBackpressure(data, on: channel, jobBound: false) }
    }
  }

  private func selectPreferredChannel() {
    // A live batch remains bound to its channel generation until cleanup.
    guard activeChannel == nil || !isBusy else { return }
    let preferred = channels["lan"] ?? channels["ble"]
    activeChannel = preferred
    peerConnected = preferred != nil
    peerCompatible = false
    peerMaxChunkBytes = 3072
    peerMaxWindow = 64
    clearOfferAssembly()
    if let preferred, let capability = capabilities[preferred.descriptor.transport] { applyCapability(capability) }
  }

  private func applyCapability(_ message: TransferMessage) {
    peerCompatible = true
    peerMaxChunkBytes = min(message.number(1), message.number(0) == 2 ? Int64(chunkLimit(activeChannel?.descriptor)) : 3072)
    peerMaxWindow = min(message.number(2), peerMaxChunkBytes > 3072 ? 8 : 64)
  }

  func retired(_ descriptor: ChannelDescriptor) {
    guard channels[descriptor.transport]?.descriptor == descriptor else { return }
    channels.removeValue(forKey: descriptor.transport)
    capabilities.removeValue(forKey: descriptor.transport)
    clearCapacityWaiters()
    guard descriptor == activeChannel?.descriptor else { return }
    activeChannel = nil
    peerConnected = false
    peerCompatible = false
    if isBusy { state = .failed(reason: "Connection closed. Send the files again using the remaining connection.") }
    cleanupActiveTransfer()
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
        if case .transferring = state { return .handled }
        if transferTask == nil { applyCapability(message) }
      }
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
      // Recovery is not advertised by this implementation; do not silently accept a resume.
      if message.kind == 10 {
        guard let channel = activeChannel else { return }
        Task { try? await self.sendWithBackpressure(TransferMessage.status(batch: message.string(0), file: message.string(1), bytesTransferred: 0, state: 4).encode(), on: channel, jobBound: false) }
      }
    case 9:
      guard let batch = currentBatch, message.string(0) == batch.idString,
        message.string(1).isEmpty || message.string(1) == sendingFile?.idString ||
        batch.files.indices.contains(receiverCurrentFileIndex) && message.string(1) == batch.files[receiverCurrentFileIndex].idString else { return }
      cancelTransfer(local: false)

    default:
      break
    }
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
          let chunk = try handle.read(upToCount: 65536) ?? Data()
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
    guard activeChannel != nil else { return }
    let operation = epoch
    var totalTransferred: Int64 = 0
    var rate = TransferRate()
    var lastUiUpdate: TimeInterval = 0

    for (fileIndex, file) in batch.files.enumerated() {
      guard operation == epoch else { return }
      guard let url = file.localURL else {
        failTransfer(reason: "Failed reading local file \(file.name)")
        return
      }

      let source: TransferSendStorage
      do { source = try await TransferSendStorage.open(url) }
      catch { if operation == epoch { failTransfer(reason: "Cannot open source file") }; return }
      guard operation == epoch else { await source.close(); return }

      sendingFile = file
      receivedFileResult = nil
      sentBytes = 0
      acknowledgedBytes = 0
      var fileBytesSent: Int64 = 0

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
            let speed = rate.add(totalTransferred, at: now)

            self.state = .transferring(
              batch: batch,
              fileIndex: fileIndex + 1,
              fileName: file.name,
              fileBytes: fileBytesSent,
              fileSize: file.size,
              totalBytes: totalTransferred,
              speedBps: speed
            )
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
    cleanupActiveTransfer()
  }

  private func handleAck(_ message: TransferMessage) {
    guard let batch = currentBatch, let file = sendingFile,
      message.string(0) == batch.idString, message.string(1) == file.idString else { return }
    let written = message.number(2)
    guard written >= acknowledgedBytes, written <= sentBytes, written <= file.size else { return }
    acknowledgedBytes = written
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
      case .waitingForPeerApproval, .incomingOffer, .transferring:
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
    receiving = true
    receiverCurrentFileIndex = 0
    receiverWrittenBytes = 0
    receiverTotalTransferred = 0
    lastAckedWrittenBytes = 0
    receiverRate = TransferRate()
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
          if unacked >= min(8, max(1, self.peerMaxWindow / 2)) * self.peerMaxChunkBytes || (self.receiverWrittenBytes == currentFile.size && self.receiverWrittenBytes > self.lastAckedWrittenBytes) {
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
      let speed = receiverRate.add(receiverTotalTransferred, at: now)

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

    // Ack every 8 chunks or at end of file
    let unacked = receiverWrittenBytes - lastAckedWrittenBytes
    if unacked >= min(8, max(1, peerMaxWindow / 2)) * peerMaxChunkBytes || receiverWrittenBytes == currentFile.size {
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
      digest = try await storage.finish(name: file.name, expected: file.sha256)
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
          self.cleanupActiveTransfer()
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
    state = .cancelled
    cleanupActiveTransfer()
  }

  func dismiss() {
    receiving = false
    state = .idle
    cleanupActiveTransfer()
  }

  private func failTransfer(reason: String) {
    if let batch = currentBatch, receiverPartFileURL != nil, batch.files.indices.contains(receiverCurrentFileIndex), let channel = activeChannel {
      let file = batch.files[receiverCurrentFileIndex]
      let result = TransferMessage.fileResult(batch: batch.idString, file: file.idString, result: 2, hash: Data(repeating: 0, count: 32))
      Task { [weak self] in
        guard let self, self.channels[channel.descriptor.transport]?.descriptor == channel.descriptor else { return }
        try? await self.sendWithBackpressure(result.encode(), on: channel, jobBound: false)
      }
    }
    state = .failed(reason: reason)
    cleanupActiveTransfer()
  }

  private func cleanupActiveTransfer(selectChannel: Bool = true) {
    preparation?.cancel(); preparation = nil; preparing = false
    clearOfferAssembly()
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
  static func publish(
    _ partial: URL,
    as name: String,
    in folder: URL,
    hardLink: (String, String) -> Int32 = { Darwin.link($0, $1) }
  ) throws {
    var suffix = 0
    var linking = true
    while suffix <= maximumSuffix {
      let target = folder.appendingPathComponent(suffixed(name, suffix))
      if linking {
        if hardLink(partial.path, target.path) == 0 {
          guard unlink(partial.path) == 0 else { throw failure(errno, partial) }
          return
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
      return
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

  func finish(name: String, expected: Data) throws -> Data {
    assert(!Thread.isMainThread)
    guard let handle, let partial, let folder else { throw CocoaError(.fileWriteUnknown) }
    let digest = Data(hasher.finalize())
    guard digest == expected else { throw SessionFailure.authentication }
    preservePartial = true
    try handle.synchronize()
    try handle.close()
    self.handle = nil
    try TransferPublisher.publish(partial, as: name, in: folder)
    self.partial = nil
    return digest
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
  static func open(_ url: URL) async throws -> TransferSendStorage {
    try await Task.detached { try TransferSendStorage(url) }.value
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
