// SPDX-License-Identifier: GPL-3.0-or-later
// Presents phone playback capability and explicit local permission actions.
import SwiftUI

struct FeaturesView: View {
  let playback: MacPlaybackModel
  let transfer: MacTransferModel
  let findDevice: MacFindDeviceModel
  let findNotifier: MacFindDeviceNotifier
  let peers: [PeerTrustRecord]
  @Environment(\.colorScheme) private var colorScheme
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        FindDeviceView(model: findDevice, peers: peers, notifier: findNotifier)
        TransferView(model: transfer)
        Text("Phone controls").font(.title2.weight(.semibold))
        MediaView(model: playback, compact: false, visible: true)
        phoneControlsCard
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var phoneControlsCard: some View {
    VStack(alignment: .leading, spacing: 10) {
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
