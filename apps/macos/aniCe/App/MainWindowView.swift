// SPDX-License-Identifier: GPL-3.0-or-later
// Presents identity, pairing and shared Bluetooth/LAN connection details in the main window.
import AppKit
import SwiftUI
import Observation

@Observable @MainActor final class ConnectionNavigation {
  var managingDevices = false
  var details = false
  var diagnostics = false
  var automaticAfterPairing = true
}

struct MainWindowView: View {
  let delegate: AppDelegate
  @Bindable var identity: IdentityViewModel
  let discovery: MacDiscoveryModel
  let pairing: MacPairingModel
  let session: MacSessionModel
  let lan: MacLanSessionModel
  @Bindable var navigation: ConnectionNavigation
  @Environment(\.openWindow) private var openWindow
  @Environment(\.colorScheme) private var colorScheme

  private var deviceHeader: some View {
    HStack(spacing: 14) {
      Image(systemName: "laptopcomputer")
        .font(.title2)
        .foregroundStyle(AniCePalette.secondaryText(colorScheme))
      VStack(alignment: .leading, spacing: 2) {
        Text(identity.local?.identity.deviceName ?? "This Mac")
          .font(.title3.weight(.medium))
          .foregroundStyle(AniCePalette.primaryText(colorScheme))
        Text("macOS • " + (identity.local?.identity.groupedFingerprint.prefix(19) ?? ""))
          .font(.caption)
          .foregroundStyle(AniCePalette.secondaryText(colorScheme))
      }
      Spacer()
      Button("Edit name…") { identity.showingDetails = true }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .padding(16)
    .background(AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 20) {
          deviceHeader
          if navigation.managingDevices {
            Button("Back") { navigation.managingDevices = false }.buttonStyle(.bordered)
            Toggle("Connect automatically after pairing", isOn: $navigation.automaticAfterPairing)
              .tint(AniCePalette.accent(colorScheme))
              .disabled(pairing.phase == "paired")
            MacPairingView(model: pairing)
            if pairing.hasTrustedAndroid || session.allowing || lan.allowing {
              Button {
                navigation.managingDevices = false
                navigation.details = true
                navigation.diagnostics = true
              } label: {
                HStack(spacing: 6) {
                  Image(systemName: "chevron.right")
                  Text("Diagnostics")
                }.frame(maxWidth: .infinity, alignment: .leading)
              }.buttonStyle(.bordered)
            }
          } else {
            if session.state == "Secured" || lan.state == "Secured" ||
              (!pairing.active && (session.allowing || lan.allowing || pairing.hasTrustedAndroid)) {
              MacSessionView(peers: pairing.peers, model: session, lan: lan,
                details: $navigation.details, diagnostics: $navigation.diagnostics,
                discovery: discovery, canDiscover: !pairing.active && !session.allowing, automaticEnabled: !pairing.active,
                onManageDevices: { navigation.managingDevices = true })
            }
            if pairing.active || !pairing.hasTrustedAndroid || pairing.trustRecoveryNeeded {
              Toggle("Connect automatically after pairing", isOn: $navigation.automaticAfterPairing)
                .tint(AniCePalette.accent(colorScheme))
              .disabled(pairing.phase == "paired")
              MacPairingView(model: pairing, showTrustedDevices: !pairing.hasTrustedAndroid || pairing.trustRecoveryNeeded)
            }
            if pairing.hasTrustedAndroid {
              Button("Manage devices") { navigation.managingDevices = true }.buttonStyle(.bordered)
            }
          }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
      }
    }
    .frame(minWidth: 480, minHeight: 320)
    .background(AniCePalette.background(colorScheme))
    .tint(AniCePalette.primaryText(colorScheme))
    .toolbar {
      Button("This device", systemImage: "info.circle") { identity.showingDetails = true }
    }
    .sheet(isPresented: $identity.showingDetails) { IdentityView(model: identity) }
    .task {
      if !IdentityView.isTesting {
        await identity.load()
        if identity.local != nil { await pairing.refresh() }
      }
    }
    .onChange(of: identity.local?.identity.fingerprint) { _, _ in Task { await pairing.refresh() } }
    .onChange(of: identity.local?.identity.deviceName) { old, new in
      if old != nil, old != new, pairing.active {
        pairing.cancel(message: "Device name updated. Start a fresh invitation to share it.")
      }
    }
    .onAppear {
      let action = openWindow
      delegate.reopenMainWindow = {
        action(id: "main")
        NSApp.activate()
      }
    }
  }
}
