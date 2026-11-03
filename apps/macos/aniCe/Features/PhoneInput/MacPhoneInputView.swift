// SPDX-License-Identifier: GPL-3.0-or-later
// Lets the user arm phone input for the currently authenticated Bluetooth peer.
import AppKit
import SwiftUI

struct MacPhoneInputView: View {
  @Bindable var model: MacPhoneInputModel
  let onOpenDevices: () -> Void
  @Environment(\.colorScheme) private var colorScheme
  @State private var ownerID = UUID()
  @State private var setupRequested = false

  // Device selection stays in Devices; this feature only arms the live authenticated phone.
  private var connectedPhone: DeviceIdentity? {
    guard let peer = model.connectedPeer, peer.platform == "android" else { return nil }
    return peer
  }

  private var inputAllowed: Binding<Bool> {
    Binding(
      get: { model.isArmed(by: ownerID) },
      set: { enabled in
        if enabled, let peer = connectedPhone {
          model.arm(ownerID: ownerID, for: peer)
        } else {
          model.disarm(ownerID: ownerID)
        }
      }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let phone = connectedPhone {
        Label(phone.deviceName, systemImage: "iphone")
          .font(.headline)
          .foregroundStyle(AniCePalette.primaryText(colorScheme))

        if model.needsPostEventAccess {
          VStack(alignment: .leading, spacing: 10) {
            Label("Allow Device Control to continue", systemImage: "exclamationmark.triangle")
              .font(.subheadline.weight(.medium))
              .foregroundStyle(AniCePalette.error(colorScheme))
            Text("Open Privacy & Security → Device Control and Data Access, then turn on aniCe. This lets your phone use the Mac keyboard and pointer.")
              .font(.callout)
              .foregroundStyle(AniCePalette.secondaryText(colorScheme))
            Button("Set up Device Control") {
              setupRequested = true
              if !model.requestEventAccess() { openSystemSettings() }
            }
            .buttonStyle(AniCeButtonStyle())
            if setupRequested {
              Text("Already enabled? Quit and reopen this copy of aniCe, then return here. macOS still reports permission as unavailable.")
                .font(.callout)
                .foregroundStyle(AniCePalette.secondaryText(colorScheme))
            }
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 10))
        } else {
          Label("Device Control allowed", systemImage: "checkmark.circle")
            .font(.callout)
            .foregroundStyle(AniCePalette.success(colorScheme))

          Toggle("Receive keyboard and trackpad input", isOn: inputAllowed)
            .toggleStyle(.checkbox)
            .aniCeControlFeedback()

          Label(model.statusMessage, systemImage: model.isReceiving ? "keyboard" : "circle")
            .font(.callout)
            .foregroundStyle(model.isReceiving ? AniCePalette.success(colorScheme) : AniCePalette.secondaryText(colorScheme))

          Text("Input goes to the Mac app with keyboard focus. Start typing on the phone while this control is on.")
            .font(.callout)
            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        }
      } else {
        Label("Connect a trusted Android phone over Bluetooth", systemImage: "iphone")
          .font(.headline)
          .foregroundStyle(AniCePalette.primaryText(colorScheme))
        Text("Choose a phone and connect from Devices. Input stays off until you enable it here.")
          .font(.callout)
          .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        Button("Open Devices", action: onOpenDevices)
          .buttonStyle(AniCeButtonStyle())
      }
    }
    .frame(maxWidth: 680, alignment: .leading)
    .onAppear { model.refreshAccessState(); enableFirstSetup() }
    .onChange(of: model.eventAccessAvailable) { _, _ in enableFirstSetup() }
    .onChange(of: connectedPhone?.fingerprint) { _, _ in enableFirstSetup() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      model.refreshAccessState()
    }
    .task {
      // Refresh without prompting while this page is visible; SwiftUI cancels the task on exit.
      while !Task.isCancelled {
        model.refreshAccessState()
        do { try await Task.sleep(for: .seconds(1)) }
        catch { break }
      }
    }
    .onDisappear { model.disarm(ownerID: ownerID) }
  }

  // Enable once per trusted credential; subsequent visits require the user's toggle.
  private func enableFirstSetup() {
    guard let phone = connectedPhone, !model.needsPostEventAccess else { return }
    let key = "phoneInput.initialSetup.\(phone.deviceId).\(phone.fingerprint)"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)
    model.arm(ownerID: ownerID, for: phone)
  }

  private func openSystemSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
       NSWorkspace.shared.open(url) {
      return
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
  }
}
