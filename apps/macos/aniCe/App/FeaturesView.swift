// SPDX-License-Identifier: GPL-3.0-or-later
// Presents phone playback capability and explicit local permission actions.
import SwiftUI

struct FeaturesView: View {
  let playback: MacPlaybackModel
  let transfer: MacTransferModel
  @Environment(\.colorScheme) private var colorScheme
  var body: some View {
          ScrollView {
            VStack(alignment:.leading,spacing:16) {
              TransferView(model: transfer)
              Text("Phone controls").font(.title2.weight(.semibold))
              VStack(alignment:.leading,spacing:8) {
                Text("Now Playing").font(.headline)
                Text("Control this Mac’s playback from Home on your phone.").font(.callout)
                Text(playback.phoneSubscribed ? "Active on your phone":"Open aniCe on your connected phone.")
                  .font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                if playback.playback.actions & 16 != 0 {
                  Button("Allow playback control…") { playback.requestPermission() }
                }
                if playback.volumeCandidate && playback.playerVolume==nil {
                  Button("Allow player volume…") { playback.requestPermission() }
                  Button("Verify player volume") { playback.verifyPlayerVolume() }.disabled(playback.busy)
                }
                Text(playback.controlStatus).font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                Text(playback.volumeStatus).font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                Button("Refresh player controls") { playback.refreshCapabilities() }.disabled(playback.busy)
                Text(playback.outputVolume.level != nil ? "Phone volume buttons control Mac output volume.":"Mac output volume is unavailable for this audio output.").font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                PlayerVolumeView(model:playback)
                if !playback.feedback.isEmpty {
                  Text(playback.feedback).font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                  if playback.playback.source.isEmpty { Button("Retry observation") { playback.retryObservation() } }
                }
              }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                .background(AniCePalette.surface(colorScheme),in:RoundedRectangle(cornerRadius:12))
            }.frame(maxWidth:760,alignment:.leading).padding(24).frame(maxWidth:.infinity,alignment:.leading)
          }
  }
}
