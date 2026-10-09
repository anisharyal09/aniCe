// SPDX-License-Identifier: GPL-3.0-or-later
// Presents shared device and transport actions in the native menu-bar companion.
import AppKit
import SwiftUI

struct CompanionView: View {
  let identity: IdentityViewModel
  let discovery: MacDiscoveryModel
  let pairing: MacPairingModel
  let session: MacSessionModel
  let lan: MacLanSessionModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 24) {
      if session.allowing || lan.allowing {
        MacSessionView(peers: pairing.peers, model: session, lan: lan)
      } else if pairing.active {
        Text(pairing.status)
        Button("Stop pairing") { pairing.cancel() }
      } else if pairing.hasTrustedAndroid {
        MacSessionView(peers: pairing.peers, model: session, lan: lan)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text("Pair your phone")
            .font(.headline)
          Text("Open aniCe to pair using a QR code or six-digit code.")
            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 12) {
        Button("Open aniCe") {
          openWindow(id: "main")
          NSApp.activate()
        }
        .buttonStyle(.borderedProminent)
        .foregroundStyle(AniCePalette.onAccent(colorScheme))
        .frame(maxWidth: .infinity)

        Menu {
          Button("This device") {
            identity.showingDetails = true
            openWindow(id: "main")
            NSApp.activate()
          }
          Button("Quit aniCe") { NSApp.terminate(nil) }
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("More options")
      }
    }
    .padding(24)
    .frame(width: 350)
    .background(AniCePalette.surface(colorScheme))
    .tint(AniCePalette.accent(colorScheme))
    .task {
      if !IdentityView.isTesting {
        await identity.load()
        if identity.local != nil { await pairing.refresh() }
      }
    }
  }
}
