// SPDX-License-Identifier: GPL-3.0-or-later
// Presents feature-specific panels and locally saved launcher shortcuts through shared owners.
import SwiftUI

struct FeaturesView: View {
  let playback: MacPlaybackModel
  let transfer: MacTransferModel
  let clipboard: MacClipboardModel
  let findDevice: MacFindDeviceModel
  let sms: MacSmsModel
  let smsPreferences: SmsPreferences
  let findNotifier: MacFindDeviceNotifier?
  let peers: [PeerTrustRecord]
  @Bindable var navigation: ConnectionNavigation
  var favouritesOnly = false
  @AppStorage("ui.favouriteFeatures") private var favouriteFeatures = ""
  @Environment(\.colorScheme) private var colorScheme
  var body: some View {
    GeometryReader { geometry in
    if !favouritesOnly, navigation.featurePanel == .messages {
      VStack(alignment: .leading, spacing: 16) {
        Button { navigation.closeFeature() } label: { Label(navigation.featureOrigin.rawValue, systemImage: "chevron.backward") }
          .buttonStyle(.plain).foregroundStyle(AniCePalette.accent(colorScheme))
        Text(AppFeature.messages.title).font(.title2.weight(.semibold))
        SmsView(model: sms, peers: peers, preferences: smsPreferences)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if !favouritesOnly, let panel = navigation.featurePanel {
          Button { navigation.closeFeature() } label: { Label(navigation.featureOrigin.rawValue, systemImage: "chevron.backward") }
            .buttonStyle(.plain).foregroundStyle(AniCePalette.accent(colorScheme))
          Text(panel.title).font(.title2.weight(.semibold))
          switch panel {
          case .playback:
            MediaView(model: playback, visible: playback.mainVisible)
            DisclosureGroup("Playback setup") { PlaybackSetupView(playback: playback) }
          case .files: TransferView(model: transfer)
          case .clipboard: ClipboardView(model: clipboard, peers: peers)
          case .messages: SmsView(model: sms, peers: peers, preferences: smsPreferences)
          case .findDevice: FindDeviceView(model: findDevice, peers: peers, notifier: findNotifier)
          }
        } else {
          Text(favouritesOnly ? "Favourites" : "Features").font(.system(size: 20, weight: .medium))
          Text(favouritesOnly ? "Your selected shortcuts. Edit them with the stars in Features." : "Open a feature, or star it for quick access.")
            .font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
          if favouritesOnly && AppFeature.favourites(in: favouriteFeatures).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Text("No favourites yet").font(.headline)
              Text("Choose the features you want to keep close.")
                .font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
              Button("Choose favourites") { navigation.show(.features) }.buttonStyle(AniCeButtonStyle())
            }
            .padding(.top, 8)
          }
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: geometry.size.width >= 850 ? 2 : 1), alignment: .leading, spacing: 0) {
            ForEach(favouritesOnly ? AppFeature.favourites(in: favouriteFeatures) : AppFeature.allCases) { item in
              feature(item)
            }
          }
        }

      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    }
    }
  }

  private func feature(_ feature: AppFeature) -> some View {
    let selected = AppFeature.favourites(in: favouriteFeatures).contains(feature)
    return HStack(spacing: 8) {
      Button { navigation.openFeature(feature) } label: {
        HStack(spacing: 12) {
          Image(systemName: feature.symbol).font(.system(size: 17)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
            .frame(width: 20).accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(feature.title).font(.system(size: 14, weight: .medium)).foregroundStyle(AniCePalette.primaryText(colorScheme))
            Text(status(for: feature)).font(.system(size: 12)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
              .lineLimit(1).truncationMode(.tail)
          }
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      Button { favouriteFeatures = feature.toggled(in: favouriteFeatures) } label: {
        Image(systemName: selected ? "star.fill" : "star")
          .font(.system(size: 14)).frame(width: 28, height: 32)
      }
      .buttonStyle(.plain).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      .accessibilityLabel((selected ? "Remove " : "Add ") + feature.title + (selected ? " from favourites" : " to favourites"))
      Button { navigation.openFeature(feature) } label: {
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
          .foregroundStyle(AniCePalette.secondaryText(colorScheme)).frame(width: 22, height: 40)
      }
      .buttonStyle(.plain).accessibilityLabel("Open \(feature.title)")
    }
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) { AniCePalette.separator(colorScheme).frame(height: 0.5) }
  }

  private func status(for feature: AppFeature) -> String {
    switch feature {
    case .playback:
      let current = playback.playback
      guard !current.source.isEmpty else { return playback.phoneSubscribed ? "Waiting for playback" : "No active playback" }
      return (current.state == 1 ? "Playing" : "Paused") + (current.title.isEmpty ? "" : " · \(current.title)")
    case .files:
      return switch transfer.state {
      case .incomingOffer(let batch): "\(batch.files.count) incoming files"
      case .waitingForPeerApproval: "Waiting for approval"
      case .transferring(_, _, let name, _, _, _, _): "Sending · \(name)"
      case .paused: "Transfer paused"
      case .completed(_, let count, _): "\(count) files sent"
      case .rejected: "Transfer declined"
      case .failed: "Transfer failed"
      case .cancelled: "Transfer cancelled"
      case .idle: transfer.peerConnected ? "Ready to send" : "Device offline"
      }
    case .clipboard:
      guard clipboard.selected != nil else { return "Pair a device to share" }
      if clipboard.isPaused { return "Clipboard sharing paused" }
      return "\(clipboard.automatic ? "Automatic sharing" : "Manual sharing") · History \(clipboard.history.enabled ? "on" : "off")"
    case .messages:
      if peers.contains(where: { sms.connected($0.peer) }) { return "SMS connected" }
      return peers.isEmpty ? "Pair a phone to relay messages" : "Connect your phone"
    case .findDevice:
      if findDevice.busy { return "Request in progress" }
      if peers.contains(where: { findDevice.canFind($0.peer) }) { return "Ready to alert your device" }
      return peers.contains(where: { findDevice.connected($0.peer) }) ? "Not available on this device" : "Device offline"
    }
  }

}

// Keeps playback permissions beside player setup rather than exposing another feature launcher.
struct PlaybackSetupView: View {
  let playback: MacPlaybackModel
  @Environment(\.colorScheme) private var colorScheme
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle("Show on Overview and menu bar", isOn: Binding(
        get: { playback.showOnMac }, set: { playback.setShowOnMac($0) }))
        .toggleStyle(.checkbox).controlSize(.small)
      HStack {
        Label(
          playback.phoneSubscribed ? "Active on your phone" : "Open aniCe on your phone",
          systemImage: playback.phoneSubscribed ? "iphone.radiowaves.left.and.right" : "iphone"
        )
        .font(.subheadline.weight(.medium))
        .foregroundStyle(playback.phoneSubscribed ? AniCePalette.accent(colorScheme) : AniCePalette.secondaryText(colorScheme))
        Spacer()
        Button("Refresh controls") { playback.refreshCapabilities() }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(playback.busy)
      }
      Text(playback.outputVolume.level != nil
        ? "Phone volume buttons control Mac output volume (\(playback.outputVolume.level!))."
        : "Phone volume buttons control Mac output volume.")
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(colorScheme))
      if playback.volumeCandidate && playback.playerVolume == nil {
        HStack(spacing: 8) {
          Button("Allow player volume…") { playback.requestPermission() }
            .buttonStyle(.bordered)
            .controlSize(.small)
          Button("Verify player volume") { playback.verifyPlayerVolume() }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(playback.busy)
        }
      }
      if !playback.controlStatus.isEmpty || !playback.volumeStatus.isEmpty {
        HStack(spacing: 12) {
          if !playback.controlStatus.isEmpty {
            Text(playback.controlStatus)
              .font(.caption2)
              .foregroundStyle(AniCePalette.secondaryText(colorScheme))
          }
          if !playback.volumeStatus.isEmpty {
            Text(playback.volumeStatus)
              .font(.caption2)
              .foregroundStyle(AniCePalette.secondaryText(colorScheme))
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
  }
}
