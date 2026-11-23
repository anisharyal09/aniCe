// SPDX-License-Identifier: GPL-3.0-or-later
// Edits a local display alias directly from device-name actions without changing peer identity.
import SwiftUI

struct MacNicknamePanel: View {
  @Bindable var model: MacPairingModel
  let peer: DeviceIdentity
  @State private var name = ""
  @State private var enabled = false
  @State private var submitted = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Name on this Mac").font(.headline)
      Text("Device name: " + peer.knownDeviceName)
        .font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
      Text("Private to this Mac.").font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
      TextField("Private nickname", text: $name).textFieldStyle(.roundedBorder).disabled(model.savingNickname)
      Toggle("Use nickname", isOn: $enabled).toggleStyle(AniCePreferenceToggleStyle()).disabled(model.savingNickname)
      if submitted && model.nicknameFailure { Text("Couldn't save. Try again.").foregroundStyle(AniCePalette.error(scheme)) }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.savingNickname)
        Button(model.savingNickname ? "Saving…" : "Save") {
          submitted = true
          model.saveNickname(peer: peer, name: name, enabled: enabled)
        }.buttonStyle(AniCeButtonStyle(prominent: true))
          .keyboardShortcut(.defaultAction)
          .disabled(model.savingNickname || name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > 64 ||
            (enabled && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
      }
    }.padding(24).frame(width: 360).background(AniCePalette.surface(scheme))
      .foregroundStyle(AniCePalette.primaryText(scheme))
      .interactiveDismissDisabled(model.savingNickname)
      .onAppear { name = model.nickname(for: peer)?.name ?? ""; enabled = model.nickname(for: peer)?.enabled ?? false }
      .onChange(of: model.savingNickname) { _, working in
        if submitted && !working && !model.nicknameFailure { dismiss() }
      }
  }
}

struct MacDeviceNamePanel: View {
  @Bindable var model: IdentityViewModel
  @State private var name = ""
  @State private var submitted = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Edit this Mac's name").font(.headline)
      TextField("Mac name", text: $name).textFieldStyle(.roundedBorder).disabled(model.isWorking)
      Text("Shared with your paired devices.").font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
      if submitted && model.renameFailure {
        Text("Couldn't save. Try again.").foregroundStyle(AniCePalette.error(scheme))
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isWorking)
        Button(model.isWorking ? "Saving…" : "Save") {
          submitted = true
          Task {
            await model.rename(name)
            if !model.renameFailure { dismiss() }
          }
        }.buttonStyle(AniCeButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
          .disabled(model.isWorking || model.local == nil ||
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > 64)
      }
    }.padding(24).frame(width: 360).background(AniCePalette.surface(scheme))
      .foregroundStyle(AniCePalette.primaryText(scheme))
      .interactiveDismissDisabled(model.isWorking)
      .onAppear { name = model.local?.identity.deviceName ?? "" }
  }
}
