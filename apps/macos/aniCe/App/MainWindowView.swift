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
  let clipboard: MacClipboardModel
  let findDevice: MacFindDeviceModel
  let findNotifier: MacFindDeviceNotifier?
  let sms: MacSmsModel
  let smsPreferences: SmsPreferences
  @Bindable var navigation: ConnectionNavigation
  @Environment(\.openWindow) private var openWindow
  @State private var systemAppearance = SystemAppearance()
  var colorScheme: ColorScheme {
    WindowAppearance.stored(appearance).colorScheme(system: systemAppearance.colorScheme)
  }

  private var mediaSurfaceVisible: Bool {
    (navigation.destination == .home && playback.showOnMac) ||
      (navigation.destination == .features && navigation.featurePanel == .playback)
  }

  @AppStorage("window.appearance") var appearance = WindowAppearance.system.rawValue

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 0) {
        Text("aniCe").font(.system(size: 22, weight: .semibold))
          .foregroundStyle(AniCePalette.primaryText(colorScheme)).padding(.top, 24).padding(.bottom, 24).padding(.horizontal, 14)
        Text("Workspace").font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
          .padding(.horizontal, 14).padding(.bottom, 12)
        ForEach([AppDestination.home, .devices, .features, .favourites]) { sidebarItem($0) }
        Spacer(minLength: 24)
        sidebarItem(.settings)
        sidebarItem(.about)
      }.padding(.horizontal, 14).padding(.bottom, 24)
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        .background(AniCePalette.secondarySurface(colorScheme))
    } detail: {
      Group {
        switch navigation.destination {
        case .home: homeContent
        case .devices: devicesContent
        case .features: FeaturesView(playback: playback, transfer: transfer, clipboard: clipboard, findDevice: findDevice, sms: sms, findNotifier: findNotifier, peers: pairing.peers, navigation: navigation)
        case .favourites: FeaturesView(playback: playback, transfer: transfer, clipboard: clipboard, findDevice: findDevice, sms: sms, findNotifier: findNotifier, peers: pairing.peers, navigation: navigation, favouritesOnly: true)
        case .about: aboutContent
        case .settings: settingsContent

        }
      }.navigationTitle("aniCe")
        .toolbarBackground(AniCePalette.surface(colorScheme), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .background(AniCePalette.background(colorScheme))
        .overlay(alignment: .top) { Divider() }
    }
    .disclosureGroupStyle(ClickableDisclosureStyle())
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
    .onChange(of:navigation.featurePanel) { _,_ in if !IdentityView.isTesting { playback.presented("main",mediaSurfaceVisible) } }
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
  private func sidebarItem(_ destination: AppDestination) -> some View {
    let selected = navigation.destination == destination
    return Button {
      if destination == .features || destination == .favourites { navigation.featurePanel = nil; navigation.findDetails = false }
      navigation.show(destination)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: destination.symbol).frame(width: 18).accessibilityHidden(true)
        Text(destination.rawValue).font(.body)
        Spacer(minLength: 0)
      }.foregroundStyle(selected ? AniCePalette.accent(colorScheme) : AniCePalette.primaryText(colorScheme))
        .padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
        .background(selected ? AniCePalette.subtleAccent(colorScheme) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
      .padding(.bottom, 4)
  }

}

struct ClickableDisclosureStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Button { configuration.isExpanded.toggle() } label: {
        HStack {
          Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.forward")
            .font(.caption).accessibilityHidden(true)
          configuration.label
          Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
      if configuration.isExpanded { configuration.content }
    }
  }
}
