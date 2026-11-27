// SPDX-License-Identifier: GPL-3.0-or-later
// Shows permission and session state for authenticated phone-requested input.
import AppKit
import SwiftUI

struct MacPhoneInputView: View {
  @Bindable var model: MacPhoneInputModel
  var showGranted = true
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
    VStack(alignment: .leading, spacing: 12) {
      if model.needsPostEventAccess {
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Event Posting")
            Spacer(minLength: 8)
            Text("Not allowed").foregroundStyle(AniCePalette.secondaryText(colorScheme))
          }
          if showGranted {
            Text("Allow keyboard and pointer input in Privacy & Security → \(permissionPaneName).")
              .font(.system(size: 12 * fontScale))
              .foregroundStyle(AniCePalette.secondaryText(colorScheme))
              .fixedSize(horizontal: false, vertical: true)
          }
          Button("Request Events access") {
            if !model.requestEventAccess() { openSystemSettings() }
          }
          .buttonStyle(AniCeButtonStyle())
          .help("Allow Events access for \(appDisplayName) in \(permissionPaneName).")
          if showGranted {
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
      } else if showGranted {
        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Event Posting")
            Spacer(minLength: 8)
            Text("Allowed").foregroundStyle(AniCePalette.secondaryText(colorScheme))
          }
          Text("Post keyboard and pointer input for Control Mac and supported Lock Mac actions.")
            .font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
        }

        if let phone = connectedPhone, model.isArmed(for: phone) {
          Label(
            model.isArmed(for: phone) || model.statusMessage != "Phone input is off."
              ? model.statusMessage : "Ready. Start Control Mac on your phone.",
            systemImage: model.isReceiving ? "keyboard" : "circle"
          )
            .font(.system(size: 12 * fontScale))
            .foregroundStyle(model.isReceiving ? AniCePalette.success(colorScheme) : AniCePalette.secondaryText(colorScheme))

          Button("Stop receiving") { model.disarm(for: phone) }
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
