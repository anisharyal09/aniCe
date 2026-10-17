// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies navigation, appearance and readiness presentation without changing connection ownership.
import CryptoKit
import AppKit
import Foundation
import XCTest
import SwiftUI
import Observation

@testable import aniCe

extension SessionTests {
  @MainActor func testNavigationDeepLinkUpdatesContextBeforePresentationAndRetainsItAcrossTabs() {
    let navigation = ConnectionNavigation()
    XCTAssertEqual(navigation.destination, .home)
    navigation.destination = .settings
    navigation.details = true
    navigation.diagnostics = false
    var presentations = 0
    navigation.open(.devices, peer: "phone-a") {
      presentations += 1
      XCTAssertEqual(navigation.destination, .devices)
      XCTAssertEqual(navigation.focusedPeer, "phone-a")
      XCTAssertEqual(navigation.deviceRoute, .overview)
    }
    navigation.show(.settings)
    XCTAssertEqual(navigation.settingsRoute, .overview)
    navigation.settingsRoute = .identity
    navigation.show(.devices)
    navigation.show(.settings)
    XCTAssertEqual(navigation.settingsRoute, .identity)
    navigation.settingsRoute = .overview
    navigation.show(.devices)
    XCTAssertEqual(navigation.focusedPeer, "phone-a")
    XCTAssertFalse(navigation.details)
    XCTAssertFalse(navigation.diagnostics)
    navigation.open(.devices, route: .pairing) {
      presentations += 1
      XCTAssertEqual(navigation.deviceRoute, .pairing)
    }
    XCTAssertEqual(presentations, 2)
  }

  @MainActor func testWorkspaceNavigationExposesSectionsAndRetainsSecurityContext() {
    XCTAssertEqual(AppDestination.primary, [.home, .devices, .features, .favourites, .settings, .about])
    let navigation = ConnectionNavigation()
    navigation.show(.devices, peer: "phone-b", route: .pairing)
    XCTAssertEqual(navigation.destination, .devices)
    XCTAssertFalse(navigation.details)
    navigation.show(.devices, peer: "phone-a")
    XCTAssertEqual(navigation.destination, .devices)
    XCTAssertFalse(navigation.details)
    XCTAssertEqual(navigation.focusedPeer, "phone-a")
    navigation.show(.features)
    XCTAssertEqual(navigation.focusedPeer, "phone-a")
    navigation.show(.devices, route: .pairing)
    XCTAssertFalse(navigation.details)
    XCTAssertEqual(navigation.focusedPeer, "phone-a")
  }

  @MainActor func testFavouritesIgnoreUnknownEntriesAndRouteWithoutChangingDeviceContext() {
    XCTAssertEqual(AppFeature.favourites(in: "files,files,unknown,playback"), [.playback, .files])
    XCTAssertTrue(AppFeature.favourites(in: "unknown").isEmpty)
    XCTAssertEqual(AppFeature.files.toggled(in: "files,unknown,playback"), "playback")
    XCTAssertEqual(AppFeature.findDevice.toggled(in: "files,files"), "files,findDevice")
    XCTAssertEqual(AppFeature.allCases.count, 3)
    for feature in AppFeature.allCases {
      XCTAssertEqual(AppFeature.favourites(in: feature.toggled(in: "")), [feature])
      XCTAssertEqual(feature.toggled(in: feature.toggled(in: "")), "")
    }
    let navigation = ConnectionNavigation()
    navigation.focusedPeer = "phone-a"
    navigation.diagnostics = true
    for origin in [AppDestination.features, .favourites] {
      for feature in AppFeature.allCases {
        navigation.show(origin)
        navigation.openFeature(feature)
        XCTAssertEqual(navigation.destination, .features)
        XCTAssertEqual(navigation.featurePanel, feature)
        XCTAssertEqual(navigation.focusedPeer, "phone-a")
        XCTAssertTrue(navigation.diagnostics)
        navigation.closeFeature()
        XCTAssertEqual(navigation.destination, origin)
        XCTAssertNil(navigation.featurePanel)
      }
    }
    navigation.settingsRoute = .about
    navigation.show(.settings)
    XCTAssertEqual(navigation.settingsRoute, .about)
  }

  func testPrimaryPeerListShowsOnlyReadyDevicesAndFallsBackWhenDisconnected() {
    let peers = [("a", "Secured", "Failed"), ("b", "Connecting", "Disconnected"), ("c", "Disconnected", "Secured")]
    let selected = ConnectionPresentation.primaryPeers(peers) { row in
      ConnectionPresentation(bluetooth: row.1, lan: row.2, bluetoothAllowing: false, lanAllowing: false, automatic: false).connected
    }
    XCTAssertEqual(selected.map { $0.0 }, ["a", "c"])
    XCTAssertEqual(ConnectionPresentation.primaryPeers(peers) { _ in false }.map { $0.0 }, ["a", "b", "c"])
    XCTAssertEqual(ConnectionPresentation.primaryPeers(peers) { _ in true }.count, 3)
    XCTAssertTrue(ConnectionPresentation.primaryPeers([String]()) { _ in true }.isEmpty)
  }

  func testWindowAppearanceResolvesForcedAndSystemColors() {
    XCTAssertEqual(WindowAppearance.allCases.count, 3)
    for system in [ColorScheme.light, .dark] {
      XCTAssertEqual(WindowAppearance.light.colorScheme(system: system), .light)
      XCTAssertEqual(WindowAppearance.dark.colorScheme(system: system), .dark)
      XCTAssertEqual(WindowAppearance.system.colorScheme(system: system), system)
      XCTAssertEqual(WindowAppearance.stored("invalid").colorScheme(system: system), system)
    }
  }

  @MainActor func testSystemColorsFollowApplicationWhileWindowIsForced() async {
    let application = NSApplication.shared
    let previous = application.appearance
    defer { application.appearance = previous }
    application.appearance = NSAppearance(named: .darkAqua)
    let system = SystemAppearance(application: application)
    let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    window.appearance = NSAppearance(named: .aqua)
    XCTAssertEqual(system.colorScheme, .dark)
    XCTAssertEqual(WindowAppearance.light.colorScheme(system: system.colorScheme), .light)
    XCTAssertEqual(window.appearance?.name, .aqua)
    XCTAssertEqual(WindowAppearance.system.colorScheme(system: system.colorScheme), .dark)

    let changed = expectation(description: "System appearance updates SwiftUI colors")
    withObservationTracking { _ = system.colorScheme } onChange: { changed.fulfill() }
    application.appearance = NSAppearance(named: .aqua)
    await fulfillment(of: [changed], timeout: 2)
    XCTAssertEqual(system.colorScheme, .light)
    XCTAssertEqual(WindowAppearance.system.colorScheme(system: system.colorScheme), .light)
    XCTAssertEqual(WindowAppearance.dark.colorScheme(system: system.colorScheme), .dark)
    XCTAssertEqual(application.appearance?.name, .aqua)
  }

  func testSessionFailuresExposeReadableReasonsInsteadOfNSErrorCodes() {
    let failures: [SessionFailure] = [.malformed, .unsupportedProfile, .untrustedPeer, .authentication,
      .state, .cancelled, .expired, .controlTimeout]
    XCTAssertEqual(failures.count, 8)
    XCTAssertEqual(Set(failures.map(\.localizedDescription)).count, 8)
    for failure in failures {
      XCTAssertFalse(failure.localizedDescription.contains("SessionFailure"))
      XCTAssertFalse(failure.localizedDescription.contains("couldn’t be completed"))
      XCTAssertFalse(failure.localizedDescription.isEmpty)
    }
    XCTAssertEqual(SessionFailure.cancelled.localizedDescription, "The connection closed")
    XCTAssertEqual(SessionFailure.authentication.localizedDescription, "Device authentication failed")
  }
  @MainActor func testCompanionContextMenuKeepsLeftClickDistinctAndRoutesWithoutSessionActions() {
    XCTAssertTrue(CompanionHost.showsContextMenu(eventType: .rightMouseUp, modifiers: []))
    XCTAssertTrue(CompanionHost.showsContextMenu(eventType: .leftMouseUp, modifiers: [.control]))
    XCTAssertFalse(CompanionHost.showsContextMenu(eventType: .leftMouseUp, modifiers: []))
    XCTAssertFalse(CompanionHost.showsContextMenu(eventType: nil, modifiers: []))
    XCTAssertFalse(CompanionHost.showsContextMenu(eventType: .leftMouseUp, modifiers: [.shift]))
    let target = NSObject()
    let items = CompanionHost.makeMenu(target: target).items
    XCTAssertEqual(items.filter { !$0.isSeparatorItem }.map(\.title),
      ["Open aniCe", "Devices", "Manage devices", "Quit aniCe"])
    XCTAssertEqual(items.filter(\.isSeparatorItem).count, 1)
    for item in items where !item.isSeparatorItem {
      XCTAssertTrue(item.target === target)
      XCTAssertNotNil(item.action)
    }
    XCTAssertEqual(Set(items.compactMap(\.action)).count, 4)
  }

  func testConnectionSummaryRequiresReadinessAcrossBothTransports() {
    let states = ["Disconnected", "Connecting", "Secured", "Failed"]
    var connected = 0, unready = 0
    for bluetooth in states {
      for lan in states {
        let result = ConnectionPresentation(bluetooth: bluetooth, lan: lan,
          bluetoothAllowing: bluetooth == "Connecting" || bluetooth == "Secured",
          lanAllowing: lan == "Connecting" || lan == "Secured", automatic: false)
        if bluetooth == "Secured" || lan == "Secured" {
          connected += 1
          XCTAssertTrue(result.connected)
          XCTAssertEqual(result.action, .disconnect)
          XCTAssertEqual(result.summary.contains("Bluetooth"), bluetooth == "Secured")
          XCTAssertEqual(result.summary.contains("Local network"), lan == "Secured")
        } else {
          unready += 1
          XCTAssertFalse(result.connected)
          XCTAssertFalse(result.summary.hasPrefix("Connected"))
        }
      }
    }
    XCTAssertEqual(connected, 7)
    XCTAssertEqual(unready, 9)
  }

  func testConnectionActionPreservesWaitingAndSecondaryFailure() {
    func presentation(_ bluetooth: String = "Disconnected", _ lan: String = "Disconnected",
      bleAllowing: Bool = false, lanAllowing: Bool = false, automatic: Bool = false) -> ConnectionPresentation {
      ConnectionPresentation(bluetooth: bluetooth, lan: lan, bluetoothAllowing: bleAllowing,
        lanAllowing: lanAllowing, automatic: automatic)
    }
    XCTAssertEqual(presentation().action, .allow)
    XCTAssertEqual(presentation("Failed").action, .retry)
    XCTAssertEqual(presentation(bleAllowing: true).summary, "Waiting for phone")
    XCTAssertEqual(presentation("Connecting", bleAllowing: true).action, .stop)
    XCTAssertEqual(presentation(automatic: true).summary, "Waiting nearby")
    XCTAssertEqual(presentation(automatic: true).action, .stop)
    XCTAssertEqual(presentation("Failed", "Secured", lanAllowing: true).summary, "Connected · Local network")
    XCTAssertEqual(presentation("Secured", "Failed", bleAllowing: true).action, .disconnect)
    XCTAssertEqual(presentation("Secured", "Connecting", bleAllowing: true, lanAllowing: true).summary,
      "Connected · Bluetooth")
  }

}
