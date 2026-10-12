// SPDX-License-Identifier: GPL-3.0-or-later
// Presents local file transfer controls, incoming batch approval and progress in the feature workspace.
import SwiftUI
import AppKit

struct TransferView: View {
  let model: MacTransferModel
  @Environment(\.colorScheme) private var colorScheme
  @State private var selectedFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Local file transfer").font(.headline)

      switch model.state {
      case .idle:
        idleContent
      case .waitingForPeerApproval(let batch):
        waitingContent(batch: batch)
      case .incomingOffer(let batch):
        incomingOfferContent(batch: batch)
      case .transferring(let batch, let fileIndex, let fileName, _, _, let totalBytes, let speedBps):
        transferringContent(batch: batch, fileIndex: fileIndex, fileName: fileName, totalBytes: totalBytes, speedBps: speedBps)
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
    .padding(16)
    .background(AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(AniCePalette.separator(colorScheme), lineWidth: 0.5)
    )
  }

  @ViewBuilder
  private var idleContent: some View {
    Text("Send and receive files directly over authenticated local network.")
      .font(.callout)
      .foregroundStyle(AniCePalette.secondaryText(colorScheme))

    if !model.peerConnected {
      Text("Connect your trusted Android device over local network to transfer files.")
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(colorScheme))
    }

    Button {
      promptAndSendFiles()
    } label: {
      Label("Send files…", systemImage: "arrow.up.circle")
    }
    .buttonStyle(.borderedProminent)
    .disabled(!model.peerConnected)
  }

  @ViewBuilder
  private func waitingContent(batch: TransferBatch) -> some View {
    VStack(alignment: .leading, spacing: 8) {
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
      .buttonStyle(.bordered)
    }
  }

  @ViewBuilder
  private func incomingOfferContent(batch: TransferBatch) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Incoming files from \(batch.peerName)").font(.callout.weight(.medium))
      Text("\(batch.files.count) file\(batch.files.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: batch.totalBytes, countStyle: .file))")
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(colorScheme))

      VStack(alignment: .leading, spacing: 4) {
        ForEach(batch.files.prefix(4)) { f in
          Text(f.name)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        if batch.files.count > 4 {
          Text("+ \(batch.files.count - 4) more…")
            .font(.caption2)
            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(AniCePalette.background(colorScheme), in: RoundedRectangle(cornerRadius: 6))

      HStack {
        Text("Save to: \(selectedFolder.lastPathComponent)")
          .font(.caption)
          .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        Spacer()
        Button("Choose…") {
          let panel = NSOpenPanel()
          panel.canChooseFiles = false
          panel.canChooseDirectories = true
          panel.allowsMultipleSelection = false
          if panel.runModal() == .OK, let url = panel.url {
            selectedFolder = url
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      HStack(spacing: 12) {
        Button("Accept") {
          Task { await model.acceptIncomingOffer(destination: selectedFolder) }
        }
        .buttonStyle(.borderedProminent)

        Button("Decline", role: .cancel) {
          Task { await model.rejectIncomingOffer(reason: 0) }
        }
        .buttonStyle(.bordered)
      }
    }
  }

  @ViewBuilder
  private func transferringContent(batch: TransferBatch, fileIndex: Int, fileName: String, totalBytes: Int64, speedBps: Double) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Transferring \(fileName)").font(.callout.weight(.medium))
          .lineLimit(1).truncationMode(.middle)
        Spacer()
        Text("\(fileIndex) of \(batch.files.count)").font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      }

      ProgressView(value: Double(totalBytes), total: Double(max(1, batch.totalBytes)))

      HStack {
        Text("\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: batch.totalBytes, countStyle: .file))")
          .font(.caption)
          .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        Spacer()
        if speedBps > 0 {
          Text("\(ByteCountFormatter.string(fromByteCount: Int64(speedBps), countStyle: .file))/s")
            .font(.caption)
            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        }
      }

      Button("Cancel", role: .cancel) {
        model.cancelTransfer(local: true)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  @ViewBuilder
  private func completedContent(batchId: UUID, fileCount: Int, totalBytes: Int64) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(AniCePalette.success(colorScheme))
        Text("Transfer completed").font(.callout.weight(.medium))
      }
      Text("\(fileCount) file\(fileCount == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))) transferred successfully.")
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(colorScheme))

      HStack(spacing: 8) {
        Button("Send more…") {
          model.dismiss()
          promptAndSendFiles()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!model.peerConnected)

        Button("Done") {
          model.dismiss()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
  }

  @ViewBuilder
  private func statusNotice(icon: String, message: String, isError: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .foregroundStyle(isError ? AniCePalette.error(colorScheme) : AniCePalette.secondaryText(colorScheme))
        Text(message)
          .font(.callout)
          .foregroundStyle(isError ? AniCePalette.error(colorScheme) : AniCePalette.primaryText(colorScheme))
      }
      HStack(spacing: 8) {
        Button("Send files…") {
          model.dismiss()
          promptAndSendFiles()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!model.peerConnected)

        Button("Dismiss") {
          model.dismiss()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
  }

  private func promptAndSendFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.prompt = "Send"
    if panel.runModal() == .OK && !panel.urls.isEmpty {
      Task {
        await model.sendFiles(urls: panel.urls)
      }
    }
  }
}
