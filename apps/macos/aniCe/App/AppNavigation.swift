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
enum DeviceRoute { case overview, pairing }
enum SettingsRoute { case overview, identity, about }
// Stable identifiers belong to local presentation preferences, never peer capabilities.
enum AppFeature: String, CaseIterable, Identifiable {
  case playback, files, findDevice
  var id: Self { self }
  var title: String { switch self { case .playback: "Now Playing"; case .files: "Send files"; case .findDevice: "Find Device" } }
  var symbol: String { switch self { case .playback: "music.note"; case .files: "arrow.up.doc"; case .findDevice: "bell" } }
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
  var destination: AppDestination = .home
  var deviceRoute: DeviceRoute = .overview
  var settingsRoute: SettingsRoute = .overview
  var focusedPeer: String?
  var details = false
  var diagnostics = false
  var findDetails = false
  var featurePanel: AppFeature?
  var featureOrigin: AppDestination = .features
  var automaticAfterPairing = true
  var automaticLanAfterPairing = true

  func openFeature(_ feature: AppFeature) {
    featureOrigin = destination == .favourites ? .favourites : .features
    featurePanel = feature
    findDetails = feature == .findDevice
    show(.features)
  }

  func closeFeature() {
    featurePanel = nil
    findDetails = false
    show(featureOrigin)
  }

  func open(_ destination: AppDestination, peer: String? = nil, route: DeviceRoute = .overview, present: () -> Void) {
    show(destination, peer: peer, route: route)
    present()
  }

  func show(_ destination: AppDestination, peer: String? = nil, route: DeviceRoute = .overview) {
    self.destination = destination
    if destination == .devices {
      deviceRoute = route
      details = false
      if let peer { focusedPeer = peer }
    }
  }
}
