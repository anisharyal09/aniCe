// SPDX-License-Identifier: GPL-3.0-or-later
// Presents identity, pairing and shared Bluetooth/LAN connection details in the main window.
import AppKit
import SwiftUI
import Observation

enum AppDestination: String, CaseIterable, Identifiable {
  case home = "Home", devices = "Devices", features = "Features", settings = "Settings"
  var id: Self { self }
  var symbol: String { switch self { case .home: "house"; case .devices: "laptopcomputer.and.iphone"; case .features: "square.grid.2x2"; case .settings: "gearshape" } }
}
enum DeviceRoute { case overview, pairing }
enum SettingsRoute { case overview, identity }
enum WindowAppearance: String, CaseIterable {
  case system = "System", light = "Light", dark = "Dark"
  func colorScheme(system: ColorScheme) -> ColorScheme {
    switch self { case .system: system; case .light: .light; case .dark: .dark }
  }
  static func stored(_ value: String) -> Self { Self(rawValue: value) ?? .system }
}

// Reads application appearance independently of the main window's forced appearance.
@Observable @MainActor final class SystemAppearance {
  private(set) var colorScheme: ColorScheme
  @ObservationIgnored private var observation: NSKeyValueObservation?

  init(application: NSApplication = .shared) {
    colorScheme = Self.scheme(application.effectiveAppearance)
    observation = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] application, _ in
      Task { @MainActor [weak self] in
        self?.colorScheme = Self.scheme(application.effectiveAppearance)
      }
    }
  }

  private static func scheme(_ appearance: NSAppearance) -> ColorScheme {
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
  }
}

@Observable @MainActor final class ConnectionNavigation {
  var destination: AppDestination = .home
  var deviceRoute: DeviceRoute = .overview
  var settingsRoute: SettingsRoute = .overview
  var focusedPeer: String?
  var details = false
  var diagnostics = false
  var automaticAfterPairing = true

  func open(_ destination: AppDestination, peer: String? = nil, route: DeviceRoute = .overview, present: () -> Void) {
    show(destination, peer: peer, route: route)
    present()
  }

  func show(_ destination: AppDestination, peer: String? = nil, route: DeviceRoute = .overview) {
    self.destination = destination
    if destination == .devices {
      deviceRoute = route
      if let peer { focusedPeer = peer }
    }
  }
}

struct MainWindowView: View {
  let delegate: AppDelegate
  @Bindable var identity: IdentityViewModel
  let discovery: MacDiscoveryModel
  let pairing: MacPairingModel
  let session: MacSessionModel
  let lan: MacLanSessionModel
  let playback: MacPlayback
  @Bindable var navigation: ConnectionNavigation
  @Environment(\.openWindow) private var openWindow
  @State private var systemAppearance = SystemAppearance()
  private var colorScheme: ColorScheme {
    WindowAppearance.stored(appearance).colorScheme(system: systemAppearance.colorScheme)
  }

  private var mediaSurfaceVisible: Bool {
    navigation.destination == .features || (navigation.destination == .home && playback.showOnMac)
  }

  @AppStorage("window.appearance") private var appearance = WindowAppearance.system.rawValue

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
        case .home:
          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              if pairing.active {
                Text(pairing.status)
                Button("Review pairing") { navigation.show(.devices, route: .pairing) }
              }
              if pairing.hasTrustedAndroid {
                MacSessionView(peers: pairing.peers, model: session, lan: lan,
                  details: $navigation.details, diagnostics: $navigation.diagnostics,
                  compact: true, onManageDevices: { navigation.show(.devices) },
                  onOpenDevice: { peer in navigation.show(.devices, peer: peer) })
              } else {
                Text("No devices paired yet").font(.headline)
                Button("Pair a device") { navigation.show(.devices, route: .pairing) }.buttonStyle(.bordered)
              }
              if playback.showOnMac && !playback.playback.source.isEmpty { MediaView(model:playback,compact:true,visible:playback.mainVisible) { navigation.show(.features) } }
            }.frame(maxWidth: 760, alignment: .leading).padding(24)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        case .devices:
          ScrollView {
            VStack(alignment: .leading, spacing: 20) {
              if navigation.deviceRoute == .pairing || !pairing.hasTrustedAndroid {
                if pairing.hasTrustedAndroid {
                  Button { navigation.deviceRoute = .overview } label: { Label("Back", systemImage: "chevron.backward") }
                }
                Toggle("Connect automatically after pairing", isOn: $navigation.automaticAfterPairing)
                  .tint(AniCePalette.accent(colorScheme)).disabled(pairing.phase == "paired")
                MacPairingView(model: pairing)
              } else {
                if pairing.peers.filter({ $0.peer.platform == "android" }).count > 1 {
                  Picker("Device", selection: $navigation.focusedPeer) {
                    Text("Current device").tag(String?.none)
                    ForEach(pairing.peers.filter { $0.peer.platform == "android" }) { record in
                      Text(record.peer.deviceName).tag(Optional(record.peer.deviceId))
                    }
                  }
                }
                MacSessionView(peers: pairing.peers, model: session, lan: lan,
                  details: $navigation.details, diagnostics: $navigation.diagnostics,
                  focusedPeer: navigation.focusedPeer, discovery: discovery, canDiscover: !pairing.active && !session.allowing,
                  automaticEnabled: !pairing.active,
                  onManageDevices: { navigation.deviceRoute = .pairing })
                Button(pairing.active ? "Review pairing" : "Manage devices") { navigation.deviceRoute = .pairing }
                  .buttonStyle(.bordered)
              }
            }.frame(maxWidth: 760, alignment: .leading).padding(24)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        case .features:
          ScrollView {
            VStack(alignment:.leading,spacing:16) {
              Text("Phone controls").font(.title2.weight(.semibold))
              VStack(alignment:.leading,spacing:8) {
                Text("Now Playing").font(.headline)
                Text("Control this Mac’s playback from Home on your phone.").font(.callout)
                Text(playback.phoneSubscribed ? "Active on your phone":"Open aniCe on your connected phone.")
                  .font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                if playback.playback.actions & 16 != 0 {
                  Button("Allow playback control…") { playback.requestPermission() }
                }
                if !playback.feedback.isEmpty {
                  Text(playback.feedback).font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                  if playback.playback.source.isEmpty { Button("Retry observation") { playback.retryObservation() } }
                }
              }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                .background(AniCePalette.surface(colorScheme),in:RoundedRectangle(cornerRadius:12))
            }.frame(maxWidth:760,alignment:.leading).padding(24).frame(maxWidth:.infinity,alignment:.leading)
          }
        case .settings:
          if navigation.settingsRoute == .identity {
            IdentityView(model: identity, embedded: true, onBack: { navigation.settingsRoute = .overview })
          } else {
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text("Window appearance")
                Spacer()
                Picker("Window appearance", selection: Binding(get: { WindowAppearance.stored(appearance).rawValue }, set: { appearance = $0 })) {
                  ForEach(WindowAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }.labelsHidden().pickerStyle(.menu).frame(width: 130)
              }.padding(.horizontal, 24).padding(.top, 20)
              Text("The menu-bar companion follows macOS appearance.")
                .font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme)).padding(.horizontal, 24)
              Divider().padding(.vertical, 12)
              Toggle("Show Now Playing on this Mac",isOn:Binding(get:{playback.showOnMac},set:{playback.setShowOnMac($0)}))
                .padding(.horizontal,24)
              Text("Show a local playback card in Home and the menu-bar companion.")
                .font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme)).padding(.horizontal,24)
              Divider().padding(.vertical,12)
              Button { navigation.settingsRoute = .identity } label: {
                HStack(spacing: 12) {
                  Image(systemName: "desktopcomputer").accessibilityHidden(true)
                  VStack(alignment: .leading, spacing: 4) {
                    Text("This device")
                    if let local = identity.local {
                      Text(local.identity.deviceName).font(.callout)
                        .foregroundStyle(AniCePalette.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                  }
                  Spacer()
                  Image(systemName: "chevron.right").accessibilityHidden(true)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
              }.buttonStyle(.plain)
                .background(AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
              Spacer()
            }
          }
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
