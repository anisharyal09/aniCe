// SPDX-License-Identifier: GPL-3.0-or-later
// Shows permission and session state for authenticated phone-requested input.
import AppKit
import SwiftUI

struct MacPhoneInputView: View {
  @Bindable var model: MacPhoneInputModel
  let onOpenDevices: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  private var appDisplayName: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? "aniCe"
  }

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
      }

      if model.needsPostEventAccess {
        VStack(alignment: .leading, spacing: 10) {
          Label("Allow Mac input", systemImage: "exclamationmark.triangle")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AniCePalette.error(colorScheme))
          Text("Allow the Events request for \(appDisplayName) in System Settings → Privacy & Security → Device Control and Data Access.")
            .font(.callout)
            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
          Button("Request Events access") {
            if !model.requestEventAccess() { openSystemSettings() }
          }
          .buttonStyle(AniCeButtonStyle())
          if !model.hasStableSigningIdentity {
            Text("This copy is ad hoc signed. Permission can be lost when its code changes; use a consistent Apple Development build for testing.")
              .font(.callout)
              .foregroundStyle(AniCePalette.secondaryText(colorScheme))
          }
          if model.permissionGrantMayBeStale {
            Text("Accessibility is allowed for \(appDisplayName), but macOS still blocks Events. Check the Events request for this copy.")
              .font(.callout)
              .foregroundStyle(AniCePalette.secondaryText(colorScheme))
          }
          if model.canOfferPermissionRestart {
            Button("Restart \(appDisplayName)") { restartAniCe() }
              .buttonStyle(AniCeButtonStyle())
            Text("If you just allowed access, restart the app to check again.")
              .font(.callout)
              .foregroundStyle(AniCePalette.secondaryText(colorScheme))
          }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 10))
      } else {
        Label("Mac input allowed", systemImage: "checkmark.circle")
          .font(.callout)
          .foregroundStyle(AniCePalette.success(colorScheme))

        if let phone = connectedPhone {
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

          Text("Input goes to the Mac app with keyboard focus.")
            .font(.callout)
            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        } else {
          Label("Connect a trusted Android phone over Bluetooth", systemImage: "iphone")
            .font(.headline)
            .foregroundStyle(AniCePalette.primaryText(colorScheme))
          Text("Open Control Mac on the phone after connecting.")
            .font(.callout)
            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
          Button("Open Devices", action: onOpenDevices)
            .buttonStyle(AniCeButtonStyle())
        }
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
