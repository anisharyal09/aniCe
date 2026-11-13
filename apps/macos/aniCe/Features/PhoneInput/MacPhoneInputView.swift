// SPDX-License-Identifier: GPL-3.0-or-later
// Shows permission and session state for authenticated phone-requested input.
import AppKit
import SwiftUI

struct MacPhoneInputView: View {
  @Bindable var model: MacPhoneInputModel
  let onOpenDevices: () -> Void
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage("ui.fontScale") private var fontScale = 1.0

  private var appDisplayName: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? "aniCe"
  }

  private var permissionPaneName: String {
    if #available(macOS 27, *) { return "Device Control and Data Access" }
    return "Accessibility"
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
          .font(.system(size: 13 * fontScale, weight: .medium))
          .foregroundStyle(AniCePalette.primaryText(colorScheme))
      }

      if model.needsPostEventAccess {
        VStack(alignment: .leading, spacing: 10) {
          Label("Allow Mac input", systemImage: "exclamationmark.triangle")
            .font(.system(size: 13 * fontScale, weight: .medium))
            .foregroundStyle(AniCePalette.error(colorScheme))
          Text("Allow Events access for \(appDisplayName) in System Settings → Privacy & Security → \(permissionPaneName).")
            .font(.system(size: 12 * fontScale))
            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
          Button("Request Events access") {
            if !model.requestEventAccess() { openSystemSettings() }
          }
          .buttonStyle(AniCeButtonStyle())
#if DEBUG
          if !model.hasStableSigningIdentity {
            Text("Development build: rebuilding may require permission again.")
              .font(.system(size: 12 * fontScale))
              .foregroundStyle(AniCePalette.secondaryText(colorScheme))
          }
#endif
          if model.permissionGrantMayBeStale {
            Text("Accessibility is allowed, but macOS still blocks Events for \(appDisplayName).")
              .font(.system(size: 12 * fontScale))
              .foregroundStyle(AniCePalette.secondaryText(colorScheme))
          }
          if model.hasStableSigningIdentity {
            Text("Already allowed? Remove the old aniCe entry in System Settings and add this copy again.")
              .font(.system(size: 12 * fontScale))
              .foregroundStyle(AniCePalette.secondaryText(colorScheme))
            Button("Show this app in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
            .buttonStyle(AniCeButtonStyle())
          }
          if model.canOfferPermissionRestart {
            Button("Restart \(appDisplayName)") { restartAniCe() }
              .buttonStyle(AniCeButtonStyle())
          }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 10))
      } else {
        Label("Mac input allowed", systemImage: "checkmark.circle")
          .font(.system(size: 13 * fontScale))
          .foregroundStyle(AniCePalette.success(colorScheme))

        if let phone = connectedPhone {
          Label(
            model.isArmed(for: phone) || model.statusMessage != "Phone input is off."
              ? model.statusMessage : "Ready. Start Control Mac on your phone.",
            systemImage: model.isReceiving ? "keyboard" : "circle"
          )
            .font(.system(size: 12 * fontScale))
            .foregroundStyle(model.isReceiving ? AniCePalette.success(colorScheme) : AniCePalette.secondaryText(colorScheme))

          if model.isArmed(for: phone) {
            Button("Stop receiving") { model.disarm(for: phone) }
              .buttonStyle(AniCeButtonStyle())
          }
        } else {
          Label("Connect a trusted Android phone over Bluetooth", systemImage: "iphone")
            .font(.system(size: 13 * fontScale, weight: .medium))
            .foregroundStyle(AniCePalette.primaryText(colorScheme))
          Text("Then start Control Mac on the phone.")
            .font(.system(size: 12 * fontScale))
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
