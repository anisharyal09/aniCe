// SPDX-License-Identifier: GPL-3.0-or-later
// Presents local file transfer controls, incoming batch approval and progress in the feature workspace and companion.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
      Text("Notifies when incoming files arrive while aniCe is in the background.")
        .font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
    }
    .toggleStyle(.checkbox).controlSize(.small).tint(AniCePalette.accent(scheme))
  }
}

struct TransferAutoReceiveSettings: View {
  let preferences: TransferAutoReceivePreferences
  let peers: [PeerTrustRecord]
  var compact = false
  @Environment(\.colorScheme) private var scheme

  private var senders: [PeerTrustRecord] { peers.filter { $0.peer.platform == "android" } }

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 2 : 8) {
      Text("Automatically receive files")
        .font(compact ? .caption.weight(.medium) : .callout.weight(.medium))
      if senders.isEmpty {
        Text("Pair an Android phone first.")
          .font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
      } else {
        ForEach(senders) { record in
          Toggle("Android · \(label(for: record))", isOn: Binding(
            get: { preferences.enabled(for: record.peer) },
            set: { preferences.setEnabled($0, for: record.peer) }))
            .aniCeControlFeedback(feedbackPadding: 3)
        }
        Text("Accepts incoming files without a prompt.")
          .font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
      }
    }
    .toggleStyle(.checkbox).controlSize(.small).tint(AniCePalette.accent(scheme))
  }

  private func label(for record: PeerTrustRecord) -> String {
    let name = record.peer.deviceName
    let duplicates = senders.filter { $0.peer.deviceName == name }
    return duplicates.count > 1 ? "\(name) · \(record.peer.fingerprint.suffix(8))" : name
  }
}

struct TransferReceiveDestinationControls: View {
  let model: MacTransferModel
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Save received files to").font(.caption.weight(.medium))
          Text(model.receiveDestinationPreferences.summary)
            .font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme)).lineLimit(1).truncationMode(.middle)
        }
        Spacer(minLength: 8)
        Button("Choose…", action: chooseFolder)
          .buttonStyle(.bordered).aniCeControlFeedback().controlSize(.small)
        if model.receiveDestinationPreferences.hasCustomFolder {
          Button("Reset", action: resetFolder)
            .buttonStyle(.bordered).aniCeControlFeedback().controlSize(.small)
        }
      }
      if let error = model.receiveDestinationError {
        Text(error).font(.caption).foregroundStyle(AniCePalette.error(scheme))
      }
    }
  }

  @MainActor private func chooseFolder() {
    CompanionHost.currentHost?.isPickingFile = true
    defer {
      CompanionHost.currentHost?.isPickingFile = false
      CompanionHost.currentHost?.refocus()
    }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Use Folder"
    if panel.runModal() == .OK, let url = panel.url {
      do {
        try model.receiveDestinationPreferences.save(folder: url)
        model.receiveDestinationError = nil
      } catch {
        model.receiveDestinationError = error.localizedDescription
      }
    }
  }

  private func resetFolder() {
    model.receiveDestinationPreferences.reset()
    model.receiveDestinationError = nil
  }
}

// Hoisted file picker helper shared between TransferView and CompanionView.
// Modal presentation is isolated to @MainActor; sends files only when selection is non-empty.
@MainActor func promptAndSendTransferFiles(model: MacTransferModel) {
  guard let reviewedPeer = model.activeChannel?.descriptor.peer else { return }
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
  panel.level = .floating
  panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
  if let screen = NSScreen.main {
    let screenFrame = screen.visibleFrame
    let panelSize = panel.frame.size
    panel.setFrameOrigin(NSPoint(
      x: screenFrame.midX - panelSize.width / 2,
      y: screenFrame.midY - panelSize.height / 2
    ))
  }
  panel.orderFrontRegardless()
  if panel.runModal() == .OK && !panel.urls.isEmpty {
    let urls = panel.urls
    let names = urls.prefix(8).map(\.lastPathComponent).joined(separator: "\n")
    let additional = urls.count > 8 ? "\n… and \(urls.count - 8) more" : ""
    let review = NSAlert()
    review.messageText = "Send \(urls.count) file\(urls.count == 1 ? "" : "s") to \(reviewedPeer.deviceName)?"
    review.informativeText = names + additional
    review.addButton(withTitle: "Send files")
    review.addButton(withTitle: "Cancel")
    review.window.level = .floating
    review.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    review.window.orderFrontRegardless()
    guard review.runModal() == .alertFirstButtonReturn else { return }
    guard let currentPeer = model.activeChannel?.descriptor.peer,
      currentPeer.deviceId == reviewedPeer.deviceId, currentPeer.fingerprint == reviewedPeer.fingerprint else {
      let changed = NSAlert()
      changed.messageText = "Connection changed"
      changed.informativeText = "No files were sent. Choose the files again to review them for the current device."
      changed.addButton(withTitle: "OK")
      changed.window.level = .floating
      changed.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      changed.window.orderFrontRegardless()
      changed.runModal()
      return
    }
    Task {
      await model.sendFiles(urls: urls, reviewedPeer: reviewedPeer,
        fileAccess: TransferFileAccessLease(urls: urls))
    }
  }
}

private enum TransferDropFailure: LocalizedError {
  case fileCount
  case promisedFile
  case unavailableFile

  var errorDescription: String? {
    switch self {
    case .fileCount: "Choose 1 to 128 files. No files were sent."
    case .promisedFile: "Drop files already saved on this Mac. Promised files aren’t supported."
    case .unavailableFile: "Drop regular local files that are available now. No files were sent."
    }
  }
}

enum TransferDropValidation {
  static func containsPromisedFile(_ identifiers: [String]) -> Bool {
    !Set(identifiers).isDisjoint(with: NSFilePromiseReceiver.readableDraggedTypes)
  }

  static func validate(_ urls: [URL]) throws {
    guard (1...128).contains(urls.count) else { throw TransferDropFailure.fileCount }
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
    ]
    for url in urls {
      guard url.isFileURL else { throw TransferDropFailure.unavailableFile }
      let values = try url.resourceValues(forKeys: keys)
      guard values.isSymbolicLink != true, values.isDirectory != true, values.isRegularFile == true else {
        throw TransferDropFailure.unavailableFile
      }
      if values.isUbiquitousItem == true {
        guard let status = values.ubiquitousItemDownloadingStatus,
          status == .current || status == .downloaded else { throw TransferDropFailure.unavailableFile }
      }
    }
  }
}

@MainActor enum TransferDropSubmission {
  static func receive(_ providers: [NSItemProvider], model: MacTransferModel) -> Bool {
    guard !providers.isEmpty else { return false }
    guard let recipient = model.connectedAndroidRecipient else {
      model.dropStatus = model.peerConnected
        ? "File transfer is unavailable on this phone."
        : "Connect your Android phone to send files."
      return false
    }
    guard (1...128).contains(providers.count) else {
      model.dropStatus = TransferDropFailure.fileCount.localizedDescription
      return true
    }
    guard providers.allSatisfy({
      $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) &&
        !TransferDropValidation.containsPromisedFile($0.registeredTypeIdentifiers)
    }) else {
      model.dropStatus = TransferDropFailure.promisedFile.localizedDescription
      return true
    }
    guard let reservation = model.reserveDrop(for: recipient) else { return true }

    Task { @MainActor in
      do {
        var urls: [URL] = []
        for provider in providers { urls.append(try await loadURL(from: provider)) }
        await submit(urls, recipient: recipient, reservation: reservation, model: model)
      } catch {
        model.failDrop(reservation: reservation,
          message: (error as? LocalizedError)?.errorDescription ?? "Could not access one of the dropped files. No files were sent.")
      }
    }
    return true
  }

  static func receive(urls: [URL], model: MacTransferModel) -> Bool {
    guard !urls.isEmpty else { return false }
    guard let recipient = model.connectedAndroidRecipient else {
      model.dropStatus = model.peerConnected
        ? "File transfer is unavailable on this phone."
        : "Connect your Android phone to send files."
      return false
    }
    guard (1...128).contains(urls.count) else {
      model.dropStatus = TransferDropFailure.fileCount.localizedDescription
      return true
    }
    guard let reservation = model.reserveDrop(for: recipient) else { return true }
    Task { await submit(urls, recipient: recipient, reservation: reservation, model: model) }
    return true
  }

  private static func submit(
    _ urls: [URL], recipient: TransferRecipient, reservation: UUID, model: MacTransferModel
  ) async {
    let access = TransferFileAccessLease(urls: urls)
    do {
      try await Task.detached(priority: .utility) { try TransferDropValidation.validate(urls) }.value
      await model.sendFiles(urls: urls, recipient: recipient, transportPolicy: .preferLanWithChoice,
        dropReservation: reservation, fileAccess: access)
    } catch {
      model.failDrop(reservation: reservation,
        message: (error as? LocalizedError)?.errorDescription ?? "Could not access one of the dropped files. No files were sent.")
    }
  }

  private static func loadURL(from provider: NSItemProvider) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadObject(ofClass: NSURL.self) { object, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let url = object as? NSURL, url.isFileURL {
          continuation.resume(returning: url as URL)
        } else {
          continuation.resume(throwing: TransferDropFailure.unavailableFile)
        }
      }
    }
  }

}

private struct TransferFileDropTarget: ViewModifier {
  let model: MacTransferModel
  let cornerRadius: CGFloat
  @Environment(\.colorScheme) private var colorScheme
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    content
      .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
        TransferDropSubmission.receive(providers, model: model)
      }
      .overlay {
        if isTargeted, model.connectedAndroidRecipient != nil, !model.isBusy {
          RoundedRectangle(cornerRadius: cornerRadius)
            .fill(AniCePalette.accent(colorScheme).opacity(0.06))
            .overlay {
              RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(AniCePalette.accent(colorScheme), lineWidth: 2)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
  }
}

extension View {
  func transferFileDropTarget(model: MacTransferModel, cornerRadius: CGFloat) -> some View {
    modifier(TransferFileDropTarget(model: model, cornerRadius: cornerRadius))
  }
}

struct TransferView: View {
  let model: MacTransferModel
  var peers: [PeerTrustRecord] = []
  var edgeDrop: MacEdgeDropController? = nil
  var compact: Bool = false
  var open: (() -> Void)? = nil
  @Environment(\.colorScheme) private var colorScheme
  @State private var controlsOpen = false

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 8 : 12) {
      if let open {
        HStack {
          Spacer()
          Button(action: open) { Label("Open file transfer", systemImage: "chevron.forward") }
            .labelStyle(.iconOnly).buttonStyle(AniCeHoverButtonStyle())
            .accessibilityLabel("Open file transfer")
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
      if model.pendingRouteSelection == nil, let dropStatus = model.dropStatus {
        Text(dropStatus).font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      }
      if let error = model.receiveDestinationError {
        Text(error).font(.caption).foregroundStyle(AniCePalette.error(colorScheme))
      }
      if let selection = model.pendingRouteSelection {
        pendingRouteContent(selection)
      } else {
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
      if !compact {
        DisclosureGroup("More settings", isExpanded: $controlsOpen) {
          VStack(alignment: .leading, spacing: 8) {
            TransferNotificationControls(preferences: model.notificationPreferences)
            TransferAutoReceiveSettings(preferences: model.autoReceivePreferences, peers: peers, compact: true)
            TransferReceiveDestinationControls(model: model)
          }
          .padding(.top, 4)
        }
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
      VStack(alignment: .leading, spacing: 8) {
        if let channel = model.activeChannel {
          Text(channel.descriptor.transport == "lan" ? "Using local network" : "Using Bluetooth")
            .font(.caption)
            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        }
        if let edgeDrop {
          VStack(alignment: .leading, spacing: 12) {
            sendFilesTarget
            Divider().overlay(AniCePalette.separator(colorScheme))
            EdgeDropSettingsView(controller: edgeDrop, showsPlacementPreview: true)
          }
        } else {
          sendFilesTarget
        }
      }
    }
  }

  private var sendFilesTarget: some View {
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
      Button(action: promptAndSendFiles) {
        Text("Choose files")
      }
      .buttonStyle(.bordered).aniCeControlFeedback()
      .controlSize(.regular)
      .disabled(!model.peerConnected || !model.peerCompatible || model.preparing)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 20)
    .frame(minHeight: 84)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(AniCePalette.separator(colorScheme), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        .accessibilityHidden(true)
    }
    .transferFileDropTarget(model: model, cornerRadius: 9)
  }

  private func pendingRouteContent(_ selection: PendingTransferRouteSelection) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Choose how to send", systemImage: "wifi.exclamationmark")
        .font(.callout.weight(.medium))
        .foregroundStyle(AniCePalette.primaryText(colorScheme))
      Text("\(selection.urls.count) file\(selection.urls.count == 1 ? "" : "s") selected for \(selection.recipient.deviceName). \(model.pendingRouteStatus)")
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { retryRouteButton; bluetoothRouteButton; cancelRouteButton }
        VStack(alignment: .leading, spacing: 8) { retryRouteButton; bluetoothRouteButton; cancelRouteButton }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10).stroke(AniCePalette.separator(colorScheme), lineWidth: 1)
    }
  }

  private var retryRouteButton: some View {
    Button("Retry") { Task { await model.retryPendingRouteSelection() } }
      .buttonStyle(.borderedProminent).aniCeControlFeedback(prominent: true).controlSize(.small)
  }

  private var bluetoothRouteButton: some View {
    Button("Send over Bluetooth") { Task { await model.sendPendingRouteOverBluetooth() } }
      .buttonStyle(.bordered).aniCeControlFeedback().controlSize(.small)
      .disabled(!model.canSendPendingOverBluetooth)
  }

  private var cancelRouteButton: some View {
    Button("Cancel", role: .cancel) { model.cancelPendingRouteSelection() }
      .buttonStyle(.bordered).aniCeControlFeedback().controlSize(.small)
  }

  private var transferTargetDescription: String {
    guard model.peerConnected else { return "Connect your phone to send files." }
    guard model.peerCompatible else { return "File transfer is unavailable on this device." }
    return "Drop files here, drag to your screen edge (Edge Drop), or pick from the menu bar."
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
      Text("Review the file list and save location before accepting.")
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(colorScheme))
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

      if !controlsOpen || compact {
        TransferReceiveDestinationControls(model: model)
      } else {
        Text("Save to: \(model.receiveDestinationPreferences.summary)")
          .font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      }
      if model.autoReceivePreparing {
        Text("Checking the saved folder…")
          .font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      }

      HStack(spacing: 8) {
        Button(model.autoReceivePreparing ? "Preparing…" : "Accept") {
          Task { await model.acceptIncomingOffer() }
        }
        .buttonStyle(.borderedProminent).aniCeControlFeedback(prominent: true)
        .controlSize(.small).disabled(model.autoReceivePreparing)

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
    let destName = model.receiveFolder?.lastPathComponent ?? model.receiveDestinationPreferences.summary
    VStack(alignment: .leading, spacing: compact ? 8 : 12) {
      HStack(spacing: 8) {
        Image(systemName: "checkmark.circle.fill")
          .font(.subheadline)
          .foregroundStyle(AniCePalette.success(colorScheme))
        Text(model.receiving ? "Files received" : "Files sent").font(.subheadline.weight(.medium))
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
          .buttonStyle(.bordered).aniCeControlFeedback()
          .controlSize(compact ? .small : .regular)
        }
        if model.peerConnected && model.peerCompatible {
          Button {
            promptAndSendFiles()
          } label: { Label("Send files…", systemImage: "arrow.up.circle") }
          .buttonStyle(.borderedProminent).aniCeControlFeedback(prominent: true)
          .controlSize(compact ? .small : .regular)
          .disabled(model.preparing || model.isBusy)
        }

        Button("Done") {
          model.dismiss()
        }
        .buttonStyle(.bordered).aniCeControlFeedback()
        .controlSize(compact ? .small : .regular)
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
          .buttonStyle(.bordered).aniCeControlFeedback()
          .controlSize(compact ? .small : .regular)
        }
        if model.peerConnected && model.peerCompatible {
          Button("Send files…") {
            promptAndSendFiles()
          }
          .buttonStyle(.borderedProminent).aniCeControlFeedback(prominent: true)
          .controlSize(compact ? .small : .regular)
          .disabled(model.preparing || model.isBusy)
        }

        Button("Dismiss") {
          model.dismiss()
        }
        .buttonStyle(.bordered).aniCeControlFeedback()
        .controlSize(compact ? .small : .regular)
      }
    }
  }

  private func promptAndSendFiles() {
    promptAndSendTransferFiles(model: model)
  }
}
