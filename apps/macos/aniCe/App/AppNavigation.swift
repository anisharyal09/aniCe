// SPDX-License-Identifier: GPL-3.0-or-later
// Owns main-window routes, peer context and appearance selection without transport lifecycle work.
import AppKit
import SwiftUI
import Observation

enum AppDestination: String, CaseIterable, Identifiable {
  case home = "Overview", devices = "Devices", features = "Features", favourites = "Favourites", settings = "Settings", about = "About"
  static let primary: [Self] = [.home, .devices, .features, .favourites, .settings, .about]
  var id: Self { self }
  var symbol: String { switch self { case .home: "house"; case .devices: "laptopcomputer.and.iphone"; case .features: "square.grid.2x2"; case .favourites: "star"; case .about: "info.circle"; case .settings: "gearshape" } }
}
enum DeviceRoute: Equatable { case overview, pairing }
enum SettingsRoute: Equatable { case overview, identity, about }
// Stable identifiers belong to local presentation preferences, never peer capabilities.
enum AppFeature: String, CaseIterable, Identifiable {
  case playback, files, findDevice, clipboard, messages
  var id: Self { self }
  var title: String { switch self { case .playback: "Now Playing"; case .files: "Send files"; case .findDevice: "Find Device"; case .clipboard: "Clipboard"; case .messages: "Messages" } }
  var symbol: String { switch self { case .playback: "music.note"; case .files: "arrow.up.doc"; case .findDevice: "bell"; case .clipboard: "doc.on.clipboard"; case .messages: "message" } }
  static func favourites(in value: String) -> [Self] {
    let saved = Set(value.split(separator: ",").map(String.init))
    return allCases.filter { saved.contains($0.rawValue) }
  }
  func toggled(in value: String) -> String {
    var saved = Set(Self.favourites(in: value))
    if !saved.insert(self).inserted { saved.remove(self) }
    return Self.allCases.filter { saved.contains($0) }.map(\.rawValue).joined(separator: ",")
  }
}

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
  private struct Route: Equatable {
    var destination: AppDestination = .home
    var deviceRoute: DeviceRoute = .overview
    var settingsRoute: SettingsRoute = .overview
    var focusedPeer: String?
    var featurePanel: AppFeature?
    var featureOrigin: AppDestination = .features
  }

  private var route = Route()
  private var previous: [Route] = []
  private var next: [Route] = []
  var canGoBack: Bool { !previous.isEmpty }
  var canGoForward: Bool { !next.isEmpty }
  var destination: AppDestination {
    get { route.destination }
    set { navigate { $0.destination = newValue } }
  }
  var deviceRoute: DeviceRoute {
    get { route.deviceRoute }
    set { navigate { $0.deviceRoute = newValue } }
  }
  var settingsRoute: SettingsRoute {
    get { route.settingsRoute }
    set { navigate { $0.settingsRoute = newValue } }
  }
  var focusedPeer: String? {
    get { route.focusedPeer }
    set { navigate { $0.focusedPeer = newValue } }
  }
  var featurePanel: AppFeature? {
    get { route.featurePanel }
    set { navigate { $0.featurePanel = newValue } }
  }
  var featureOrigin: AppDestination { route.featureOrigin }
  var details = false
  var diagnostics = false
  var findDetails = false
  var automaticAfterPairing = true
  var automaticLanAfterPairing = true

  private func navigate(_ update: (inout Route) -> Void) {
    var target = route
    update(&target)
    guard target != route else { return }
    // A new destination after Back starts a new branch of presentation history.
    previous.append(route)
    next.removeAll()
    route = target
  }

  func goBack() {
    guard let target = previous.popLast() else { return }
    next.append(route)
    restore(target)
  }

  func goForward() {
    guard let target = next.popLast() else { return }
    previous.append(route)
    restore(target)
  }

  private func restore(_ target: Route) {
    route = target
    details = false
    findDetails = target.featurePanel == .findDevice
  }

  func select(_ destination: AppDestination) {
    navigate {
      $0.destination = destination
      if destination == .features || destination == .favourites { $0.featurePanel = nil }
      if destination == .devices { $0.deviceRoute = .overview }
    }
    details = false
    findDetails = false
  }

  func showSettings(_ settingsRoute: SettingsRoute) {
    navigate {
      $0.destination = .settings
      $0.settingsRoute = settingsRoute
    }
  }

  func openFeature(_ feature: AppFeature) {
    navigate {
      if $0.destination != .features || $0.featurePanel == nil {
        $0.featureOrigin = $0.destination == .home || $0.destination == .favourites ? $0.destination : .features
      }
      $0.featurePanel = feature
      $0.destination = .features
    }
    findDetails = feature == .findDevice
  }

  func closeFeature() {
    navigate {
      $0.featurePanel = nil
      $0.destination = $0.featureOrigin
    }
    findDetails = false
  }

  func open(_ destination: AppDestination, peer: String? = nil, route: DeviceRoute = .overview, present: () -> Void) {
    show(destination, peer: peer, route: route)
    present()
  }

  func show(_ destination: AppDestination, peer: String? = nil, route: DeviceRoute = .overview) {
    navigate {
      $0.destination = destination
      if destination == .devices {
        $0.deviceRoute = route
        if let peer { $0.focusedPeer = peer }
      }
    }
    if destination == .devices { details = false }
  }
}
