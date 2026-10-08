// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

struct MainWindowView: View {
  let delegate: AppDelegate
  @Bindable var identity: IdentityViewModel
  let discovery: MacDiscoveryModel
  let pairing: MacPairingModel
  let session: MacSessionModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.colorScheme) private var colorScheme

  @State private var discoveryExpanded = false

  private var deviceHeader: some View {
    HStack(spacing: 14) {
      Image(systemName: "laptopcomputer")
        .font(.title2)
        .foregroundStyle(AniCePalette.accent(colorScheme))
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
          if session.allowing || pairing.hasTrustedAndroid {
            MacSessionView(peers: pairing.peers, model: session)
          }
          MacPairingView(model: pairing)
          if pairing.hasTrustedAndroid && !pairing.active && !session.allowing {
            VStack(alignment: .leading, spacing: 8) {
              Button {
                discoveryExpanded.toggle()
              } label: {
                Label(
                  "Nearby discovery compatibility check",
                  systemImage: discoveryExpanded ? "chevron.down" : "chevron.right"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .foregroundStyle(AniCePalette.accent(colorScheme))
              .accessibilityValue(discoveryExpanded ? "Expanded" : "Collapsed")
              if discoveryExpanded { MacDiscoveryView(model: discovery) }
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
    .tint(AniCePalette.accent(colorScheme))
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
