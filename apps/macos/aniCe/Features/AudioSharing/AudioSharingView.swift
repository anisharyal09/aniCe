// SPDX-License-Identifier: GPL-3.0-or-later
// Presents explicit capture preparation, peer readiness and Stop without starting audio from view lifecycle.
import AppKit
import SwiftUI

struct AudioSharingView: View {
  let model: MacAudioSharingModel
  let phoneAudio: MacPhoneAudioModel
  var lan: MacLanSessionModel? = nil
  var targetPhone: DeviceIdentity? = nil
  var peerPause: String? = nil
  var openDevices: () -> Void = {}
  @AppStorage("ui.fontScale") private var fontScale = 1.0
  @Environment(\.colorScheme) private var colorScheme
  private func text(_ key: String) -> String { NSLocalizedString(key, tableName: "AudioSharing", comment: "") }

  private var needsLAN: Bool {
    model.peer == nil && phoneAudio.peer == nil && !model.busy && !phoneAudio.busy
  }
  private var pauseStatus: String? {
    lan?.isConnectionPaused() == true ? text("listening_lan_paused") : peerPause
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      note(text("listening_overview"))
      if let lan, needsLAN {
        lanConnectionSection(lan)
      } else if phoneAudio.busy {
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
    .task(id: needsLAN && pauseStatus == nil) {
      if needsLAN, pauseStatus == nil { _ = lan?.requestAutomaticConnection() }
    }
  }

  private func lanConnectionSection(_ lan: MacLanSessionModel) -> some View {
    let connecting = lan.state == "Connecting" || lan.allowing
    return VStack(alignment: .leading, spacing: 8) {
      Text(text("listening_lan_title")).font(.system(size: 14 * fontScale, weight: .medium))
      if let pauseStatus {
        note(pauseStatus)
      } else if lan.verifyingConnection {
        note(text("listening_lan_checking"))
      } else if connecting || lan.state == "Failed" {
        note(lan.status)
      } else {
        note(text(targetPhone == nil ? "listening_lan_choose_phone" : "listening_lan_help"))
      }
      Toggle(text("listening_lan_auto"), isOn: Binding(
        get: { lan.automatic },
        set: { enabled in
          lan.setAutomatic(enabled)
          if enabled { _ = lan.requestAutomaticConnection() }
        }))
        .toggleStyle(.checkbox).disabled(pauseStatus != nil).aniCeControlFeedback()
        .fixedSize(horizontal: false, vertical: true)
      note(text("listening_lan_auto_help"))
      if pauseStatus != nil || targetPhone == nil {
        Button(text("listening_open_devices"), action: openDevices)
          .buttonStyle(AniCeButtonStyle(compact: true))
      } else if let targetPhone {
        Button(text(connecting ? "listening_lan_connecting" : "listening_lan_connect")) {
          if pauseStatus == nil { lan.connectAlongside(targetPhone) }
        }
        .buttonStyle(AniCeButtonStyle(prominent: !connecting && !lan.verifyingConnection, compact: true))
        .disabled(connecting || lan.verifyingConnection)
      }
    }
  }

  private var macAudioSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(text("listening_send_mac_audio")).font(.system(size: 14 * fontScale, weight: .medium))
      if let peer = model.peer { note(peer.deviceName) }
      Text(model.reverseBusy ? text("listening_reverse_busy") : model.status)
        .fixedSize(horizontal: false, vertical: true)
      ListeningActionGroup {
        if model.busy && model.state == 0 {
          Button(text("listening_stopping")) {}.disabled(true)
            .buttonStyle(AniCeButtonStyle(compact: true))
        } else if model.active || model.busy {
          Button(text("listening_stop")) { model.stop() }
            .buttonStyle(AniCeButtonStyle(compact: true))
            .accessibilityIdentifier("listening.stop")
        } else if model.capturePrepared {
          Button(text("listening_start")) { model.start() }
            .buttonStyle(AniCeButtonStyle(prominent: model.canStart, compact: true))
            .disabled(!model.canStart)
            .accessibilityIdentifier("listening.start")
        } else {
          Button(text("listening_prepare")) { model.prepareCapture() }
            .buttonStyle(AniCeButtonStyle(prominent: model.canPrepare, compact: true))
            .disabled(!model.canPrepare)
            .accessibilityIdentifier("listening.prepare")
          if model.canPrepare {
            Button(text("listening_recording_settings")) {
              if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                NSWorkspace.shared.open(url)
              }
            }.buttonStyle(AniCeButtonStyle(compact: true))
              .accessibilityIdentifier("listening.recording-settings")
          }
        }
      }
      if !model.busy && !model.receivingEnabled && !model.reverseBusy {
        note(text("listening_phone_setup"))
      }
      Toggle(text("listening_also_mac"), isOn: Binding(
        get: { model.alsoPlayThroughMacSpeakers },
        set: { model.setAlsoPlayThroughMacSpeakers($0) }))
        .toggleStyle(.checkbox).aniCeControlFeedback()
        .fixedSize(horizontal: false, vertical: true)
      if !model.alsoPlayThroughMacSpeakers { note(text("listening_restore_warning")) }
    }
  }

  private var phoneAudioSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(text("phone_audio_title")).font(.system(size: 14 * fontScale, weight: .medium))
      Text(model.busy && !phoneAudio.busy ? text("phone_audio_forward_busy") : phoneAudio.status)
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
        .toggleStyle(.checkbox).disabled(!phoneAudio.canToggle || (model.busy && !phoneAudio.receivingEnabled))
        .aniCeControlFeedback()
        .fixedSize(horizontal: false, vertical: true)
      if !phoneAudio.busy { note(text("phone_audio_help")) }
      if phoneAudio.active && phoneAudio.acceptedPackets > 0 {
        DisclosureGroup(text("listening_details")) {
          VStack(alignment: .leading, spacing: 4) {
            note(String(format: text("phone_audio_diagnostics"), phoneAudio.acceptedPackets, phoneAudio.gapPackets))
            note(String(format: text("phone_audio_output_diagnostics"), phoneAudio.queuedOutputFrames, phoneAudio.outputResyncs))
          }
        }
      }
    }
  }

  private func note(_ message: String) -> some View {
    Text(message)
      .font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      .fixedSize(horizontal: false, vertical: true)
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
