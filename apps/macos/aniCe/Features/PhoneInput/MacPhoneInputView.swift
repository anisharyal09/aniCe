// SPDX-License-Identifier: GPL-3.0-or-later
// Shows permission and session state for authenticated phone-requested input.
import AppKit
import SwiftUI

struct MacPhoneInputView: View {
  @Bindable var model: MacPhoneInputModel
  let onOpenDevices: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  // Device selection stays in Devices; status follows the live authenticated phone.
  private var connectedPhone: DeviceIdentity? {
    guard let peer = model.connectedPeer, peer.platform == "android" else { return nil }
    return peer
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let phone = connectedPhone {
        Label(phone.deviceName, systemImage: "iphone")
          .font(.headline)
          .foregroundStyle(AniCePalette.primaryText(colorScheme))

        if model.needsPostEventAccess {
          VStack(alignment: .leading, spacing: 10) {
            Label("Allow Mac input", systemImage: "exclamationmark.triangle")
              .font(.subheadline.weight(.medium))
              .foregroundStyle(AniCePalette.error(colorScheme))
            Text("Allow aniCe's event-posting request in System Settings → Privacy & Security → Device Control and Data Access. When you return, aniCe checks the permission and stays open.")
              .font(.callout)
              .foregroundStyle(AniCePalette.secondaryText(colorScheme))
            Button("Set up Mac input") {
              if !model.requestEventAccess() { openSystemSettings() }
            }
            .buttonStyle(AniCeButtonStyle())
            if !model.hasStableSigningIdentity {
              Text("This build has no stable Apple Development signature. macOS may not match its permission after a rebuild. Use the Apple Development signed aniCe build, then add that copy in System Settings.")
                .font(.callout)
                .foregroundStyle(AniCePalette.secondaryText(colorScheme))
            }
            if model.permissionGrantMayBeStale {
              Text("macOS reports Accessibility (Device Control and Data Access) as allowed, but Event Posting is still blocked. Remove aniCe from that settings list and add this signed copy again.")
                .font(.callout)
                .foregroundStyle(AniCePalette.secondaryText(colorScheme))
            }
            if model.canOfferPermissionRestart {
              Button("Restart aniCe") { restartAniCe() }
                .buttonStyle(AniCeButtonStyle())
              Text("Restart aniCe only if you just allowed access and the status is still blocked. This closes and reopens the app to refresh macOS’s check.")
                .font(.callout)
                .foregroundStyle(AniCePalette.secondaryText(colorScheme))
              if !model.permissionGrantMayBeStale {
                Text("If access is still blocked, remove aniCe from this settings list and add the current signed copy again.")
                  .font(.callout)
                  .foregroundStyle(AniCePalette.secondaryText(colorScheme))
              }
            }
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 10))
        } else {
          Label("Mac input allowed", systemImage: "checkmark.circle")
            .font(.callout)
            .foregroundStyle(AniCePalette.success(colorScheme))

          Label(
            model.isArmed(for: phone) || model.statusMessage != "Phone input is off."
              ? model.statusMessage : "Ready. Start Control Mac on your phone.",
            systemImage: model.isReceiving ? "keyboard" : "circle"
          )
            .font(.callout)
            .foregroundStyle(model.isReceiving ? AniCePalette.success(colorScheme) : AniCePalette.secondaryText(colorScheme))

          if model.isArmed(for: phone) {
            Button("Stop receiving") { model.disarm(for: phone) }
              .buttonStyle(AniCeButtonStyle())
          }

          Text("Start Control Mac on your phone to begin. Input goes to the Mac app with keyboard focus.")
            .font(.callout)
            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        }
      } else {
        Label("Connect a trusted Android phone over Bluetooth", systemImage: "iphone")
          .font(.headline)
          .foregroundStyle(AniCePalette.primaryText(colorScheme))
        Text("Choose a trusted phone and connect from Devices. The phone can start a session when it is ready.")
          .font(.callout)
          .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        Button("Open Devices", action: onOpenDevices)
          .buttonStyle(AniCeButtonStyle())
      }
    }
    .frame(maxWidth: 680, alignment: .leading)
    .onAppear { model.refreshAccessState() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      model.refreshAccessState()
    }
  }

  private func restartAniCe() {
    // Wait for shutdown before reopening so BLE and session owners never overlap.
    let relauncher = Process()
    relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
    relauncher.arguments = [
      "-c",
      "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open -a \"$2\"",
      "aniCe-relaunch",
      String(ProcessInfo.processInfo.processIdentifier),
      Bundle.main.bundlePath,
    ]
    relauncher.standardInput = FileHandle.nullDevice
    relauncher.standardOutput = FileHandle.nullDevice
    relauncher.standardError = FileHandle.nullDevice
    do {
      try relauncher.run()
      NSApp.terminate(nil)
    } catch {
      let alert = NSAlert()
      alert.messageText = "Could not restart aniCe"
      alert.informativeText = "Quit aniCe, then reopen it from the Dock or Applications."
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
  }

  private func openSystemSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
       NSWorkspace.shared.open(url) {
      return
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
  }
}
