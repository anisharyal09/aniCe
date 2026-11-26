// SPDX-License-Identifier: GPL-3.0-or-later
// Owns main-window routes, peer context and appearance selection without transport lifecycle work.
import AppKit
import SwiftUI
import Observation

enum AppDestination: String, CaseIterable, Identifiable {
  case home = "Overview", devices = "Devices", features = "Features", favourites = "Favourites", settings = "Settings", about = "About", guide = "Guide"
  static let primary: [Self] = [.home, .devices, .features, .favourites, .settings, .about]
  var id: Self { self }
  var symbol: String {
    switch self {
    case .home: "house"
    case .devices: "laptopcomputer.and.iphone"
    case .features: "square.grid.2x2"
    case .favourites: "star"
    case .about: "info.circle"
    case .settings: "gearshape"
    case .guide: "questionmark.circle"
    }
  }
}
enum DeviceRoute: Equatable { case overview, pairing }
enum SettingsRoute: Equatable { case overview, identity, about }

enum GuideCategory: String, CaseIterable, Identifiable {
  case all = "All", connect = "Connect", shareAndFiles = "Share & Files", control = "Control", syncAndAlerts = "Sync & Alerts"
  var id: Self { self }
}

enum GuideTopic: String, CaseIterable, Identifiable {
  case pairingAndConnection
  case permissions
  case openLinkInMac
  case filesAndEdgeDrop
  case clipboardAndQuickSend
  case pasteTrayAndPins
  case controlMac
  case controlAndroidAndFloatingKey
  case macDeskDeck
  case nowPlayingAndAudio
  case messagesAndSms
  case notificationsAndCalls
  case dndSync
  case findDeviceAndPing
  case companionAndShortcuts

  var id: Self { self }

  var category: GuideCategory {
    switch self {
    case .pairingAndConnection, .permissions: .connect
    case .openLinkInMac, .filesAndEdgeDrop, .clipboardAndQuickSend, .pasteTrayAndPins: .shareAndFiles
    case .controlMac, .controlAndroidAndFloatingKey, .macDeskDeck, .nowPlayingAndAudio: .control
    case .messagesAndSms, .notificationsAndCalls, .dndSync, .findDeviceAndPing, .companionAndShortcuts: .syncAndAlerts
    }
  }
}

enum MacSettingsCategory: String, CaseIterable {
  case all = "All", general = "General", permissions = "Permissions", features = "Features", shortcuts = "Shortcuts"

  static func category(for section: String) -> Self {
    switch section {
    case "appearance", "updates", "connection", "this-device", "guide": .general
    case "permissions": .permissions
    case "shortcuts": .shortcuts
    default: .features
    }
  }
}
// Stable identifiers belong to local presentation preferences, never peer capabilities.
enum AppFeature: String, CaseIterable, Identifiable {
  case keyboardTrackpad, messages, files, clipboard, findDevice, playback
  static let defaultFavourites = "clipboard,keyboardTrackpad,messages"
  static let defaultPinnedToCompanion = "clipboard,keyboardTrackpad,messages"
  var id: Self { self }
  var title: String { switch self { case .keyboardTrackpad: "Control Android"; case .messages: "Messages"; case .files: "Send files"; case .clipboard: "Clipboard"; case .findDevice: "Find Device"; case .playback: "Now Playing" } }
  var symbol: String { switch self { case .keyboardTrackpad: "keyboard"; case .messages: "message"; case .files: "arrow.up.doc"; case .clipboard: "doc.on.clipboard"; case .findDevice: "bell"; case .playback: "music.note" } }
  static func favourites(in value: String) -> [Self] {
    uniqueFeatures(in: value)
  }
  func toggled(in value: String) -> String {
    var saved = Self.favourites(in: value)
    if let index = saved.firstIndex(of: self) { saved.remove(at: index) }
    else { saved.append(self) }
    return saved.map(\.rawValue).joined(separator: ",")
  }
  static func ordered(in value: String) -> [Self] {
    let saved = uniqueFeatures(in: value)
    return saved + allCases.filter { !saved.contains($0) }
  }
  static func pinnedToCompanion(in value: String) -> [Self] {
    uniqueFeatures(in: value)
  }
  func toggledPinned(in value: String) -> String {
    var saved = Self.pinnedToCompanion(in: value)
    if let index = saved.firstIndex(of: self) { saved.remove(at: index) }
    else { saved.append(self) }
    return saved.map(\.rawValue).joined(separator: ",")
  }
  static func isPinned(_ feature: Self, in value: String) -> Bool {
    pinnedToCompanion(in: value).contains(feature)
  }
  static func moved(_ feature: Self, in rows: [Self], offset: Int) -> String {
    var reordered = rows
    guard let index = reordered.firstIndex(of: feature), reordered.count > 1 else {
      return reordered.map(\.rawValue).joined(separator: ",")
    }
    let destination = min(reordered.count - 1, max(0, index + offset))
    reordered.insert(reordered.remove(at: index), at: destination)
    return reordered.map(\.rawValue).joined(separator: ",")
  }
  private static func uniqueFeatures(in value: String) -> [Self] {
    var saved = [Self]()
    for raw in value.split(separator: ",") {
      if let feature = Self(rawValue: String(raw)), !saved.contains(feature) { saved.append(feature) }
    }
    return saved
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
    var settingsSection: String?
    var focusedPeer: String?
    var featurePanel: AppFeature?
    var featureOrigin: AppDestination = .features
    var guideTopic: GuideTopic?
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
  var settingsSection: String? { route.settingsSection }

  func openSettings(section: String) {
    navigate {
      $0.destination = .settings
      $0.settingsRoute = .overview
      $0.settingsSection = section
    }
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
  var guideTopic: GuideTopic? { route.guideTopic }

  func openGuide(_ topic: GuideTopic? = nil) {
    navigate {
      $0.destination = .guide
      $0.guideTopic = topic
    }
  }
  var details = false
  var diagnostics = false
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
  }

  func select(_ destination: AppDestination) {
    navigate {
      $0.destination = destination
      if destination == .features || destination == .favourites { $0.featurePanel = nil }
      if destination == .devices { $0.deviceRoute = .overview }
    }
    details = false
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
  }

  func closeFeature() {
    navigate {
      $0.featurePanel = nil
      $0.destination = $0.featureOrigin
    }
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
    if destination == .devices {
      details = false
      diagnostics = false
    }
  }
}
