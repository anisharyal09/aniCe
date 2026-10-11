// SPDX-License-Identifier: GPL-3.0-or-later
// Owns main-window routes, peer context and appearance selection without transport lifecycle work.
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
