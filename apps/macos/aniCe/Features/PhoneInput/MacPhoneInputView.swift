// SPDX-License-Identifier: GPL-3.0-or-later
// Lets the user arm phone input for the currently authenticated Bluetooth peer.
import AppKit
import SwiftUI

struct MacPhoneInputView: View {
  @Bindable var model: MacPhoneInputModel
  let onOpenDevices: () -> Void
  @Environment(\.colorScheme) private var colorScheme
  @State private var ownerID = UUID()

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

        Toggle("Allow this phone to type on this Mac", isOn: inputAllowed)
          .toggleStyle(.checkbox)
          .aniCeControlFeedback()
          .disabled(model.needsPostEventAccess && !model.isArmed(by: ownerID))

        if model.needsPostEventAccess {
          VStack(alignment: .leading, spacing: 10) {
            Label("macOS event access is off", systemImage: "exclamationmark.triangle")
              .font(.subheadline.weight(.medium))
              .foregroundStyle(AniCePalette.error(colorScheme))
            Text("Review aniCe's access in System Settings → Privacy & Security before receiving input.")
              .font(.callout)
              .foregroundStyle(AniCePalette.secondaryText(colorScheme))
            Button("Open System Settings", action: openSystemSettings)
              .buttonStyle(AniCeButtonStyle())
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 10))
        } else {
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
    .onAppear(perform: model.refreshAccessState)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      model.refreshAccessState()
    }
    .onDisappear { model.disarm(ownerID: ownerID) }
  }

  private func openSystemSettings() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
  }
}
