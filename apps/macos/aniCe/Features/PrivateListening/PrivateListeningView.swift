// SPDX-License-Identifier: GPL-3.0-or-later
// Presents explicit capture preparation, peer readiness and Stop without starting audio from view lifecycle.
import AppKit
import SwiftUI

struct PrivateListeningView: View {
  let model: MacPrivateListeningModel
  @Environment(\.colorScheme) private var colorScheme
  private func text(_ key: String) -> String { NSLocalizedString(key, tableName: "PrivateListening", comment: "") }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.peer.map { String(format: text("listening_audio_to"), $0.deviceName) }
        ?? text("listening_connect_phone"))
        .font(.headline)
      Text(text("listening_phone_setup"))
        .font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      Text(model.status).font(.callout)
      HStack(spacing: 8) {
        if model.active || model.busy {
          Button(text("listening_stop")) { model.stop() }.buttonStyle(AniCeButtonStyle())
        } else {
          Button(text("listening_prepare")) { model.prepareCapture() }
            .buttonStyle(AniCeButtonStyle()).disabled(!model.canPrepare)
          Button(text("listening_start")) { model.start() }
            .buttonStyle(AniCeButtonStyle()).disabled(!model.canStart)
        }
      }
      Toggle(text("listening_also_mac"), isOn: Binding(
        get: { model.alsoPlayThroughMacSpeakers },
        set: { model.setAlsoPlayThroughMacSpeakers($0) }))
        .toggleStyle(.checkbox).aniCeControlFeedback()
      Text(text("listening_restore_warning"))
        .font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      Button(text("listening_recording_settings")) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
          NSWorkspace.shared.open(url)
        }
      }.buttonStyle(AniCeHoverButtonStyle())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
