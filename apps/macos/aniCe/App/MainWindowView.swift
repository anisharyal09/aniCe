// SPDX-License-Identifier: GPL-3.0-or-later
// Presents identity, pairing and shared Bluetooth/LAN connection details in the main window.
import AppKit
import SwiftUI
import Observation

struct MainWindowView: View {
  let delegate: AppDelegate
  @Bindable var identity: IdentityViewModel
  let discovery: MacDiscoveryModel
  let pairing: MacPairingModel
  let session: MacSessionModel
  let lan: MacLanSessionModel
  let playback: MacPlaybackModel
  let transfer: MacTransferModel
  @Bindable var navigation: ConnectionNavigation
  @Environment(\.openWindow) private var openWindow
  @State private var systemAppearance = SystemAppearance()
  var colorScheme: ColorScheme {
    WindowAppearance.stored(appearance).colorScheme(system: systemAppearance.colorScheme)
  }

  private var mediaSurfaceVisible: Bool {
    navigation.destination == .features || (navigation.destination == .home && playback.showOnMac)
  }

  @AppStorage("window.appearance") var appearance = WindowAppearance.system.rawValue

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 0) {
        Text("aniCe").font(.title3.weight(.semibold)).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
        List(AppDestination.allCases, selection: $navigation.destination) { destination in
          Label(destination.rawValue, systemImage: destination.symbol).tag(destination)
        }
      }.navigationSplitViewColumnWidth(min: 140, ideal: 160)
    } detail: {
      Group {
        switch navigation.destination {
        case .home: homeContent
        case .devices: devicesContent
        case .features: FeaturesView(playback: playback, transfer: transfer)
        case .settings: settingsContent

        }
      }.navigationTitle(navigation.destination.rawValue)
        .toolbarBackground(AniCePalette.surface(colorScheme), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .background(AniCePalette.background(colorScheme))
        .overlay(alignment: .top) { Divider() }
    }
    .preferredColorScheme(colorScheme)
    .frame(minWidth: 620, minHeight: 420)
    .tint(AniCePalette.primaryText(colorScheme))
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
    .onChange(of:navigation.destination) { _,_ in if !IdentityView.isTesting { playback.presented("main",mediaSurfaceVisible) } }
    .onChange(of:playback.showOnMac) { _,_ in if !IdentityView.isTesting { playback.presented("main",mediaSurfaceVisible) } }
    .onDisappear { playback.presented("main",false) }
    .onAppear {
      if !IdentityView.isTesting { playback.presented("main",mediaSurfaceVisible) }
      let action = openWindow
      delegate.reopenMainWindow = {
        action(id: "main")
        for window in NSApp.windows where window.identifier?.rawValue == "main" || window.title == "aniCe" {
          window.deminiaturize(nil)
          window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
        playback.presented("main",mediaSurfaceVisible)
      }
    }
  }
}
