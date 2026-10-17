// SPDX-License-Identifier: GPL-3.0-or-later
// Presents feature-specific panels and locally saved launcher shortcuts through shared owners.
import SwiftUI

struct FeaturesView: View {
  let playback: MacPlaybackModel
  let transfer: MacTransferModel
  let findDevice: MacFindDeviceModel
  let findNotifier: MacFindDeviceNotifier?
  let peers: [PeerTrustRecord]
  @Bindable var navigation: ConnectionNavigation
  var favouritesOnly = false
  @AppStorage("ui.favouriteFeatures") private var favouriteFeatures = ""
  @Environment(\.colorScheme) private var colorScheme
  var body: some View {
    GeometryReader { geometry in
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
          case .findDevice: FindDeviceView(model: findDevice, peers: peers, notifier: findNotifier)
          }
        } else {
          Text(favouritesOnly ? "Favourites" : "Features").font(.title2.weight(.semibold))
          Text(favouritesOnly ? "Your selected shortcuts. Edit them with the stars in Features." : "Choose a feature, or star it to keep it in Favourites.")
            .font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
          if favouritesOnly && AppFeature.favourites(in: favouriteFeatures).isEmpty {
            Button("Choose favourites") { navigation.show(.features) }.buttonStyle(.bordered)
          }
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: geometry.size.width >= 700 ? 2 : 1), alignment: .leading, spacing: 16) {
            ForEach(favouritesOnly ? AppFeature.favourites(in: favouriteFeatures) : AppFeature.allCases) { item in
              feature(item, detail: item == .playback ? "Playback on this Mac" : item == .files ? "Send to your connected device" : "Alert a connected device")
            }
          }
        }

      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    }
  }

  private func feature(_ feature: AppFeature, detail: String) -> some View {
    let selected = AppFeature.favourites(in: favouriteFeatures).contains(feature)
    return VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: feature.symbol).font(.title3).foregroundStyle(AniCePalette.accent(colorScheme)).accessibilityHidden(true)
        Spacer()
        Button { favouriteFeatures = feature.toggled(in: favouriteFeatures) } label: {
          Image(systemName: selected ? "star.fill" : "star").frame(width: 28, height: 28)
        }.buttonStyle(.plain).foregroundStyle(AniCePalette.accent(colorScheme))
          .accessibilityLabel((selected ? "Remove " : "Add ") + feature.title + (selected ? " from favourites" : " to favourites"))
      }
      Button { navigation.openFeature(feature) } label: {
        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            Text(feature.title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
          }
          Spacer(minLength: 8)
          Image(systemName: "chevron.right").foregroundStyle(AniCePalette.accent(colorScheme)).accessibilityHidden(true)
        }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain)
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    .background(AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 10))
    .overlay { RoundedRectangle(cornerRadius: 10).stroke(AniCePalette.separator(colorScheme), lineWidth: 0.5) }
  }

}

// Keeps playback permissions beside player setup rather than exposing another feature launcher.
struct PlaybackSetupView: View {
  let playback: MacPlaybackModel
  @Environment(\.colorScheme) private var colorScheme
  var body: some View {
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
