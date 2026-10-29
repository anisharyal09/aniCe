// SPDX-License-Identifier: GPL-3.0-or-later
// Presents local file transfer controls, incoming batch approval and progress in the feature workspace and companion.
import AppKit
import SwiftUI

struct TransferNotificationControls: View {
  let preferences: TransferNotificationPreferences
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle("Background offer notifications", isOn: Binding(get: { preferences.enabled }, set: { preferences.enabled = $0 }))
        .aniCeControlFeedback(feedbackPadding: 3)
      Toggle("Play sound", isOn: Binding(get: { preferences.sound }, set: { preferences.sound = $0 }))
        .aniCeControlFeedback(feedbackPadding: 3)
        .disabled(!preferences.enabled)
    }
    .toggleStyle(.checkbox).controlSize(.small).tint(AniCePalette.accent(scheme))
  }
}

// Hoisted file picker helper shared between TransferView and CompanionView.
// Modal presentation is isolated to @MainActor; sends files only when selection is non-empty.
@MainActor func promptAndSendTransferFiles(model: MacTransferModel) {
  guard let reviewedPeer = model.activeChannel?.descriptor.peer else { return }
  _ = model.onLanRequired()
  CompanionHost.currentHost?.isPickingFile = true
  defer {
    CompanionHost.currentHost?.isPickingFile = false
    CompanionHost.currentHost?.refocus()
  }
  let panel = NSOpenPanel()
  panel.allowsMultipleSelection = true
  panel.canChooseFiles = true
  panel.canChooseDirectories = false
  panel.prompt = "Send"
  if panel.runModal() == .OK && !panel.urls.isEmpty {
    let urls = panel.urls
    let names = urls.prefix(8).map(\.lastPathComponent).joined(separator: "\n")
    let additional = urls.count > 8 ? "\n… and \(urls.count - 8) more" : ""
    let review = NSAlert()
    review.messageText = "Send \(urls.count) file\(urls.count == 1 ? "" : "s") to \(reviewedPeer.deviceName)?"
    review.informativeText = names + additional
    review.addButton(withTitle: "Send files")
    review.addButton(withTitle: "Cancel")
    guard review.runModal() == .alertFirstButtonReturn else { return }
    guard let currentPeer = model.activeChannel?.descriptor.peer,
      currentPeer.deviceId == reviewedPeer.deviceId, currentPeer.fingerprint == reviewedPeer.fingerprint else {
      let changed = NSAlert()
      changed.messageText = "Connection changed"
      changed.informativeText = "No files were sent. Choose the files again to review them for the current device."
      changed.addButton(withTitle: "OK")
      changed.runModal()
      return
    }
    Task {
      await model.sendFiles(urls: urls, reviewedPeer: reviewedPeer)
    }
  }
}

struct TransferView: View {
  let model: MacTransferModel
  var compact: Bool = false
  var open: (() -> Void)? = nil
  @Environment(\.colorScheme) private var colorScheme
  @State private var controlsOpen = false
  @State private var selectedFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 8 : 12) {
      if !compact {
        HStack {
          Spacer()
          if let open {
            Button(action: open) { Image(systemName: "chevron.forward") }
              .buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("Open file transfer")
          }
          Button { controlsOpen.toggle() } label: { Label("Notification settings", systemImage: "gearshape") }
            .labelStyle(.iconOnly).frame(width: 24, height: 24)
            .buttonStyle(.borderless).aniCeControlFeedback()
            .help("File transfer notification settings")
        }
        if controlsOpen {
          TransferNotificationControls(preferences: model.notificationPreferences)
          Text("Optional incoming offers when aniCe is in the background. Progress and results stay here.")
            .font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
        }
      }

      if model.preparing {
        HStack {
          ProgressView().controlSize(.small)
          Text("Preparing files…").font(.caption)
          Spacer()
          Button("Cancel") { model.cancelTransfer() }
            .buttonStyle(.bordered).aniCeControlFeedback()
            .controlSize(.small)
        }
      }
      switch model.state {
      case .idle:
        idleContent
      case .waitingForPeerApproval(let batch):
        waitingContent(batch: batch)
      case .incomingOffer(let batch):
        incomingOfferContent(batch: batch)
      case .transferring(let batch, let fileIndex, let fileName, let fileBytes, let fileSize, let totalBytes, let speedBps):
        transferringContent(batch: batch, fileIndex: fileIndex, fileName: fileName, fileBytes: fileBytes, fileSize: fileSize, totalBytes: totalBytes, speedBps: speedBps)
      case .paused(let batch, let fileIndex, let fileName, let fileBytes, let fileSize, let totalBytes, let reason, let canResumeOverBle):
        pausedContent(batch: batch, fileIndex: fileIndex, fileName: fileName, fileBytes: fileBytes, fileSize: fileSize, totalBytes: totalBytes, reason: reason, canResumeOverBle: canResumeOverBle)
      case .completed(let batchId, let fileCount, let totalBytes):
        completedContent(batchId: batchId, fileCount: fileCount, totalBytes: totalBytes)
      case .rejected:
        statusNotice(icon: "xmark.circle", message: "Transfer declined by your Android device.")
      case .failed(let reason):
        statusNotice(icon: "exclamationmark.triangle", message: "Transfer failed: \(reason)", isError: true)
      case .cancelled:
        statusNotice(icon: "slash.circle", message: "Transfer cancelled.")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(compact ? 0 : 8)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(Color.clear)
  }

  @ViewBuilder
  private var idleContent: some View {
    if compact {
      HStack {
        Text("File transfer")
          .font(.subheadline.weight(.medium))
        Spacer()
        Button {
          promptAndSendFiles()
        } label: {
          Label("Send…", systemImage: "arrow.up.circle")
        }
        .buttonStyle(.bordered).aniCeControlFeedback()
        .controlSize(.small)
        .disabled(!model.peerConnected || !model.peerCompatible || model.preparing)
      }
      if !model.peerConnected {
        Text("Connect your phone to send files.").font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      } else if !model.peerCompatible {
        Text("File transfer is unavailable on this device.").font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      }
    } else {
      if let channel = model.activeChannel {
        Text(channel.descriptor.transport == "lan" ? "Using local network" : "Using Bluetooth")
          .font(.caption)
          .foregroundStyle(AniCePalette.secondaryText(colorScheme))
      }

      HStack(spacing: 14) {
        Image(systemName: "arrow.up.to.line")
          .font(.title3)
          .foregroundStyle(AniCePalette.secondaryText(colorScheme))
          .frame(width: 24)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text("Send files").font(.callout.weight(.medium))
          Text(transferTargetDescription)
            .font(.caption)
            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
            .lineLimit(2)
        }
        Spacer(minLength: 12)
        Button {
          promptAndSendFiles()
        } label: {
          Text("Choose files")
        }
        .buttonStyle(.bordered).aniCeControlFeedback()
        .controlSize(.small)
        .disabled(!model.peerConnected || !model.peerCompatible || model.preparing)
      }
      .padding(16)
      .overlay {
        RoundedRectangle(cornerRadius: 9)
          .stroke(AniCePalette.separator(colorScheme), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
          .accessibilityHidden(true)
      }
    }
  }

  private var transferTargetDescription: String {
    guard model.peerConnected else { return "Connect your phone to send files." }
    guard model.peerCompatible else { return "File transfer is unavailable on this device." }
    return "To \(model.activeChannel?.descriptor.peer.deviceName ?? "your phone")"
  }

  @ViewBuilder
  private func waitingContent(batch: TransferBatch) -> some View {
    VStack(alignment: .leading, spacing: compact ? 8 : 10) {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Waiting for \(batch.peerName) to accept…").font(.callout.weight(.medium))
      }
      Text("\(batch.files.count) file\(batch.files.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: batch.totalBytes, countStyle: .file))")
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(colorScheme))

      Button("Cancel", role: .cancel) {
        model.cancelTransfer(local: true)
      }
      .buttonStyle(.bordered).aniCeControlFeedback()
      .controlSize(.small)
    }
  }

  @ViewBuilder
  private func incomingOfferContent(batch: TransferBatch) -> some View {
    VStack(alignment: .leading, spacing: compact ? 8 : 10) {
      HStack {
        Text("Incoming files from \(batch.peerName)").font(.callout.weight(.medium))
        Spacer()
      }
      Text("\(batch.files.count) file\(batch.files.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: batch.totalBytes, countStyle: .file))")
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(colorScheme))

      VStack(alignment: .leading, spacing: 3) {
        let maxFiles = compact ? 2 : 4
        ForEach(batch.files.prefix(maxFiles)) { f in
          Text(f.name)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        if batch.files.count > maxFiles {
          Text("+ \(batch.files.count - maxFiles) more…")
            .font(.caption2)
            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        }
      }
      .padding(6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(AniCePalette.background(colorScheme), in: RoundedRectangle(cornerRadius: 6))

      HStack {
        Text("Save to: \(selectedFolder.lastPathComponent)")
          .font(.caption)
          .foregroundStyle(AniCePalette.secondaryText(colorScheme))
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        Button("Choose…") {
          CompanionHost.currentHost?.isPickingFile = true
          defer {
            CompanionHost.currentHost?.isPickingFile = false
            CompanionHost.currentHost?.refocus()
          }
          let panel = NSOpenPanel()
          panel.canChooseFiles = false
          panel.canChooseDirectories = true
          panel.allowsMultipleSelection = false
          if panel.runModal() == .OK, let url = panel.url {
            selectedFolder = url
          }
        }
        .buttonStyle(.bordered).aniCeControlFeedback()
        .controlSize(.small)
      }

      HStack(spacing: 8) {
        Button("Accept") {
          Task { await model.acceptIncomingOffer(destination: selectedFolder) }
        }
        .buttonStyle(.borderedProminent).aniCeControlFeedback(prominent: true)
        .controlSize(.small)

        Button("Decline", role: .cancel) {
          Task { await model.rejectIncomingOffer(reason: 0) }
        }
        .buttonStyle(.bordered).aniCeControlFeedback()
        .controlSize(.small)
      }
    }
  }

  @ViewBuilder
  private func transferringContent(batch: TransferBatch, fileIndex: Int, fileName: String, fileBytes: Int64, fileSize: Int64, totalBytes: Int64, speedBps: Double) -> some View {
    let activity = model.receiving ? "Receiving" : "Sending"
    let target = model.receiving ? "from" : "to"
    let saving = model.finalizing && fileBytes >= fileSize
    let hasTotal = batch.totalBytes > 0
    VStack(alignment: .leading, spacing: compact ? 6 : 8) {
      HStack {
        Text("\(activity) \(fileName) \(target) \(batch.peerName)").font(.callout.weight(.medium))
          .lineLimit(1).truncationMode(.middle)
        Spacer()
        Text("\(fileIndex) of \(batch.files.count)").font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      }
      if let channel = model.activeChannel {
        Text(channel.descriptor.transport == "lan" ? "Using local network" : "Using Bluetooth")
          .font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      }

      if saving {
        ProgressView().progressViewStyle(.linear)
          .accessibilityLabel("Verifying and saving \(fileName)")
        Text("Verifying and saving…")
          .font(.caption)
          .foregroundStyle(AniCePalette.secondaryText(colorScheme))
      } else if hasTotal {
        ProgressView(value: Double(totalBytes), total: Double(batch.totalBytes))
          .accessibilityLabel("\(activity) \(fileName), \(Int(Double(totalBytes) / Double(batch.totalBytes) * 100)) percent")
      } else {
        ProgressView().progressViewStyle(.linear)
          .accessibilityLabel("\(activity) \(fileName)")
      }

      HStack {
        Text(hasTotal
          ? "\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: batch.totalBytes, countStyle: .file))"
          : "\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) transferred")
          .font(.caption)
          .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        Spacer()
        Text(speedBps > 0 ? "\(ByteCountFormatter.string(fromByteCount: Int64(speedBps), countStyle: .file))/s" : "—")
          .font(.caption)
          .foregroundStyle(AniCePalette.secondaryText(colorScheme))
      }

      Button("Cancel", role: .cancel) {
        model.cancelTransfer(local: true)
      }
      .buttonStyle(.bordered).aniCeControlFeedback()
      .controlSize(.small)
    }
  }

  @ViewBuilder
  private func pausedContent(batch: TransferBatch, fileIndex: Int, fileName: String, fileBytes: Int64, fileSize: Int64, totalBytes: Int64, reason: String, canResumeOverBle: Bool) -> some View {
    let activity = model.receiving ? "Receiving" : "Sending"
    let hasTotal = batch.totalBytes > 0
    VStack(alignment: .leading, spacing: compact ? 6 : 8) {
      HStack {
        Image(systemName: "pause.circle.fill")
          .font(.subheadline)
          .foregroundStyle(AniCePalette.secondaryText(colorScheme))
          .accessibilityHidden(true)
        Text("\(activity) paused").font(.callout.weight(.medium))
        Spacer()
        Text("\(fileIndex) of \(batch.files.count)").font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      }

      Text(reason)
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(colorScheme))

      // Progress is frozen at the last verified offset until a channel resumes the batch.
      if hasTotal {
        ProgressView(value: Double(min(totalBytes, batch.totalBytes)), total: Double(batch.totalBytes))
          .accessibilityLabel("\(activity) paused at \(Int(Double(totalBytes) / Double(batch.totalBytes) * 100)) percent")
      } else {
        ProgressView(value: fileSize > 0 ? Double(fileBytes) / Double(fileSize) : 0)
          .accessibilityLabel("\(activity) paused")
      }

      Text(hasTotal
        ? "\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: batch.totalBytes, countStyle: .file))"
        : "\(fileName) · \(ByteCountFormatter.string(fromByteCount: fileBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        .lineLimit(1)
        .truncationMode(.middle)

      Text(canResumeOverBle
        ? "Waiting for a connection, or continue over Bluetooth."
        : model.receiving
          ? "Waiting for the local network to reconnect. Receiving continues automatically."
          : "Waiting for \(batch.peerName) to reconnect.")
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(colorScheme))

      HStack(spacing: 8) {
        if canResumeOverBle {
          Button("Continue over Bluetooth") {
            model.resumeOverBluetooth()
          }
          .buttonStyle(.borderedProminent).aniCeControlFeedback(prominent: true)
          .controlSize(.small)
        }
        Button("Cancel", role: .cancel) {
          model.cancelTransfer(local: true)
        }
        .buttonStyle(.bordered).aniCeControlFeedback()
        .controlSize(.small)
      }
    }
  }

  @ViewBuilder
  private func completedContent(batchId: UUID, fileCount: Int, totalBytes: Int64) -> some View {
    // Reads model.receiveFolder rather than tentative selectedFolder to report where files actually landed on disk.
    let destName = model.receiveFolder?.lastPathComponent ?? selectedFolder.lastPathComponent
    VStack(alignment: .leading, spacing: compact ? 8 : 12) {
      HStack(spacing: 8) {
        Image(systemName: "checkmark.circle.fill")
          .font(.subheadline)
          .foregroundStyle(AniCePalette.success(colorScheme))
        Text("Transfer completed").font(.subheadline.weight(.medium))
      }
      Text(model.receiving
        ? "\(fileCount) file\(fileCount == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))) saved to \(destName)."
        : "\(fileCount) file\(fileCount == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))) sent to your Android device.")
        .font(.caption)
        .lineSpacing(2)
        .foregroundStyle(AniCePalette.secondaryText(colorScheme))

      HStack(spacing: 8) {
        if model.receiving && !model.publishedURLs.isEmpty {
          Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(model.publishedURLs)
          }
          .buttonStyle(.borderedProminent).aniCeControlFeedback(prominent: true)
          .controlSize(.small)
        } else if !model.receiving {
          Button {
            model.dismiss()
            promptAndSendFiles()
          } label: { Label("Send more…", systemImage: "arrow.up.circle") }
          .buttonStyle(.bordered).aniCeControlFeedback()
          .controlSize(.small)
          .disabled(!model.peerConnected || !model.peerCompatible || model.preparing)
        }

        Button("Done") {
          model.dismiss()
        }
        .buttonStyle(.bordered).aniCeControlFeedback()
        .controlSize(.small)
      }
    }
  }

  @ViewBuilder
  private func statusNotice(icon: String, message: String, isError: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: compact ? 8 : 12) {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .font(.subheadline)
          .foregroundStyle(isError ? AniCePalette.error(colorScheme) : AniCePalette.secondaryText(colorScheme))
        Text(message)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(isError ? AniCePalette.error(colorScheme) : AniCePalette.primaryText(colorScheme))
      }
      HStack(spacing: 8) {
        if !model.publishedURLs.isEmpty {
          Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(model.publishedURLs)
          }
          .buttonStyle(.borderedProminent).aniCeControlFeedback(prominent: true)
          .controlSize(.small)
        } else if isError {
          Button("Try again") {
            model.dismiss()
            promptAndSendFiles()
          }
          .buttonStyle(.borderedProminent).aniCeControlFeedback(prominent: true)
          .controlSize(.small)
          .disabled(!model.peerConnected || !model.peerCompatible || model.preparing)
        }

        Button("Dismiss") {
          model.dismiss()
        }
        .buttonStyle(.bordered).aniCeControlFeedback()
        .controlSize(.small)
      }
    }
  }

  private func promptAndSendFiles() {
    promptAndSendTransferFiles(model: model)
  }
}
