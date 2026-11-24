// SPDX-License-Identifier: GPL-3.0-or-later
// Presents explicit capture preparation, peer readiness and Stop without starting audio from view lifecycle.
import AppKit
import SwiftUI

struct PrivateListeningView: View {
  let model: MacPrivateListeningModel
  let phoneAudio: MacPhoneAudioModel
  @AppStorage("ui.fontScale") private var fontScale = 1.0
  @Environment(\.colorScheme) private var colorScheme
  private func text(_ key: String) -> String { NSLocalizedString(key, tableName: "PrivateListening", comment: "") }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if phoneAudio.busy {
        phoneAudioSection
        Divider()
        macAudioSection
      } else {
        macAudioSection
        Divider()
        phoneAudioSection
      }
    }
    .font(.system(size: 13 * fontScale))
    .foregroundStyle(AniCePalette.primaryText(colorScheme))
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var macAudioSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(model.peer.map { String(format: text("listening_audio_to"), $0.deviceName) }
        ?? text("listening_connect_phone"))
        .font(.system(size: 14 * fontScale, weight: .medium))
      Text(model.status)
        .fixedSize(horizontal: false, vertical: true)
      ListeningActionGroup {
        if model.busy && model.state == 0 {
          Button(text("listening_stopping")) {}.disabled(true)
            .buttonStyle(AniCeButtonStyle(compact: true))
        } else if model.active || model.busy {
          Button(text("listening_stop")) { model.stop() }
            .buttonStyle(AniCeButtonStyle(compact: true))
            .accessibilityIdentifier("listening.stop")
        } else {
          Button(text("listening_prepare")) { model.prepareCapture() }
            .buttonStyle(AniCeButtonStyle(prominent: !model.capturePrepared, compact: true))
            .disabled(!model.canPrepare)
            .accessibilityIdentifier("listening.prepare")
          Button(text("listening_start")) { model.start() }
            .buttonStyle(AniCeButtonStyle(prominent: model.capturePrepared, compact: true))
            .disabled(!model.canStart)
            .accessibilityIdentifier("listening.start")
        }
      }
      Text(text("listening_phone_setup"))
        .font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
      Toggle(text("listening_also_mac"), isOn: Binding(
        get: { model.alsoPlayThroughMacSpeakers },
        set: { model.setAlsoPlayThroughMacSpeakers($0) }))
        .toggleStyle(.checkbox).aniCeControlFeedback()
        .fixedSize(horizontal: false, vertical: true)
      Text(text("listening_restore_warning"))
        .font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
      Button(text("listening_recording_settings")) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
          NSWorkspace.shared.open(url)
        }
      }.buttonStyle(AniCeButtonStyle(compact: true))
        .accessibilityIdentifier("listening.recording-settings")
    }
  }

  private var phoneAudioSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(text("phone_audio_title")).font(.system(size: 14 * fontScale, weight: .medium))
      Text(phoneAudio.status)
        .fixedSize(horizontal: false, vertical: true)
      if phoneAudio.active {
        Button(text("phone_audio_stop")) { phoneAudio.stop() }
          .buttonStyle(AniCeButtonStyle(compact: true))
          .accessibilityIdentifier("phone-audio.stop")
      } else if phoneAudio.busy {
        Button(text("listening_stopping")) {}.disabled(true)
          .buttonStyle(AniCeButtonStyle(compact: true))
      }
      Toggle(text("phone_audio_allow"), isOn: Binding(
        get: { phoneAudio.receivingEnabled },
        set: { phoneAudio.setReceiving($0) }))
        .toggleStyle(.checkbox).disabled(!phoneAudio.canToggle).aniCeControlFeedback()
        .fixedSize(horizontal: false, vertical: true)
      Text(text("phone_audio_help"))
        .font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
      if phoneAudio.active && phoneAudio.acceptedPackets > 0 {
        Text(String(format: text("phone_audio_diagnostics"), phoneAudio.acceptedPackets,
          phoneAudio.gapPackets))
          .font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
        Text(String(format: text("phone_audio_output_diagnostics"), phoneAudio.queuedOutputFrames,
          phoneAudio.outputResyncs))
          .font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      }
    }
  }
}

/// Shares the listening action row's real narrow-width fallback with layout regressions.
struct ListeningActionGroup<Content: View>: View {
  @ViewBuilder let content: () -> Content
  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8, content: content).fixedSize(horizontal: true, vertical: false)
      VStack(alignment: .leading, spacing: 8, content: content)
    }
  }
}
