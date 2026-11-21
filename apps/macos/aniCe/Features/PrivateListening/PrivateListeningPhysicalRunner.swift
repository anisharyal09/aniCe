// SPDX-License-Identifier: GPL-3.0-or-later
// Coordinates opt-in local physical-preview tests through existing feature owners, without recording audio or changing trust.
#if DEBUG && ANICE_TRANSFER_PREVIEW
import AppKit
import Foundation

@MainActor final class PrivateListeningPhysicalRunner {
  private let listening: MacPrivateListeningModel
  private let transfer: MacTransferModel
  private let connectionState: () -> String
  private let connect: () -> Bool
  private let directory: URL
  private var task: Task<Void, Never>?

  init?(listening: MacPrivateListeningModel, transfer: MacTransferModel,
    connectionState: @escaping () -> String, connect: @escaping () -> Bool) {
    guard Bundle.main.bundleIdentifier == MacAppStorage.transferPreviewBundleIdentifier,
      let run = ProcessInfo.processInfo.environment["ANICE_PRIVATE_LISTENING_PHYSICAL"],
      let uuid = UUID(uuidString: run), uuid.uuidString.lowercased() == run else { return nil }
    self.listening = listening
    self.transfer = transfer
    self.connectionState = connectionState
    self.connect = connect
    directory = MacAppStorage.applicationSupport.appendingPathComponent("PhysicalListening/\(run)", isDirectory: true)
  }

  func start() {
    guard task == nil else { return }
    task = Task { [weak self] in
      guard let self else { return }
      do {
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw SessionFailure.state }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try publish("ready.json", ["ready": true])
        var step = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 75 * 60
        while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
          let url = directory.appendingPathComponent("command-\(step).json")
          if !FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(for: .milliseconds(100))
            continue
          }
          let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
          guard values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size <= 4096,
            let command = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
            let action = command["action"] as? String else { throw SessionFailure.malformed }
          var result: [String: Any] = ["step": step, "action": action, "completed": false]
          do {
            switch action {
            case "connect":
              guard connect() else { throw SessionFailure.untrustedPeer }
              result["connectionRequested"] = true
            case "prepare":
              guard listening.canPrepare else { throw SessionFailure.state }
              listening.prepareCapture()
              try await wait(seconds: 10) { !self.listening.busy }
              guard listening.capturePrepared else { throw SessionFailure.state }
              result["capturePrepared"] = true
            case "start":
              guard listening.canStart else { throw SessionFailure.state }
              listening.start()
              try await wait(seconds: 8) { self.listening.active && self.listening.state != 1 }
              guard listening.active else { throw SessionFailure.state }
              result["listeningActive"] = true
            case "stop":
              listening.stop()
              try await wait(seconds: 10) { !self.listening.busy }
              result["nativeCleanupComplete"] = true
            case "snapshot":
              result["listeningActive"] = listening.active
              result["listeningState"] = listening.state
              result["canStart"] = listening.canStart
              result["connectionState"] = connectionState()
              result["fileCreditBytes"] = transfer.sendCreditBytes
              result["fileChunkBytes"] = transfer.senderChunkBytes
              result["fileAcknowledgedBytes"] = transfer.acknowledgedBytes
              result["fileWrittenBytes"] = transfer.receiverWrittenBytes
            case "send-file":
              guard !transfer.isBusy, let peer = transfer.connectedAndroidRecipient else { throw SessionFailure.state }
              let file = directory.appendingPathComponent("source.bin")
              let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
              guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                let count = attributes.fileSize, count > 0, count <= 256 * 1048576 else { throw SessionFailure.malformed }
              let started = ProcessInfo.processInfo.systemUptime
              await transfer.sendFiles(urls: [file], recipient: peer,
                transportPolicy: .preferLanWithChoice)
              try await wait(seconds: 180) {
                if case .completed = self.transfer.state { return true }
                if case .failed = self.transfer.state { return true }
                return false
              }
              guard case .completed(_, let files, let bytes) = transfer.state, files == 1, bytes == count else {
                throw SessionFailure.state
              }
              let elapsed = ProcessInfo.processInfo.systemUptime - started
              result["bytes"] = bytes
              result["elapsedSeconds"] = elapsed
              result["averageMBpsIncludingPreparation"] = Double(bytes) / elapsed / 1_000_000
              result["verifiedTransferResult"] = true
              transfer.dismiss()
            case "finish":
              listening.stop()
              try await wait(seconds: 10) { !self.listening.busy }
              result["completed"] = true
              try publish("reply-\(step).json", result)
              return
            default: throw SessionFailure.malformed
            }
            result["completed"] = true
          } catch {
            result["failed"] = true
            result["failureType"] = String(describing: type(of: error))
            result["nativeState"] = listening.state
          }
          try publish("reply-\(step).json", result)
          step += 1
        }
        listening.stop()
      } catch {
        listening.stop()
      }
    }
  }

  private func wait(seconds: TimeInterval, until predicate: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !predicate() {
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw SessionFailure.expired }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func publish(_ name: String, _ value: [String: Any]) throws {
    let url = directory.appendingPathComponent(name)
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  func stop() {
    task?.cancel()
    task = nil
    listening.stop()
  }
}
#endif
