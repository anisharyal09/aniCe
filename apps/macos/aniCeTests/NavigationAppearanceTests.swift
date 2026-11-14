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
  @MainActor func testPackagedAppIconIsDarkAndDockKeepsSystemVariants() throws {
    let packagedURL = try XCTUnwrap(Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
    let packaged = try XCTUnwrap(NSImage(contentsOf: packagedURL))
    let dock = try XCTUnwrap(NSImage(named: "DockIcon"))
    let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
    XCTAssertEqual(appearances.count, 2)

    func background(_ image: NSImage, appearance: NSAppearance.Name) throws -> NSColor {
      let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
      let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
      let drawingAppearance = try XCTUnwrap(NSAppearance(named: appearance))
      drawingAppearance.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
      }
      return try XCTUnwrap(bitmap.colorAt(x: 64, y: 16)?.usingColorSpace(.sRGB))
    }

    let dark = try background(dock, appearance: .darkAqua)
    for appearance in appearances {
      let color = try background(packaged, appearance: appearance)
      XCTAssertGreaterThan(color.alphaComponent, 0.95)
      XCTAssertLessThan(max(color.redComponent, color.greenComponent, color.blueComponent), 0.22,
        "The packaged Finder icon uses the near-black Dock tile, not the gray tile")
      XCTAssertEqual(color.redComponent, dark.redComponent, accuracy: 0.01)
      XCTAssertEqual(color.greenComponent, dark.greenComponent, accuracy: 0.01)
      XCTAssertEqual(color.blueComponent, dark.blueComponent, accuracy: 0.01)
    }
    let light = try background(dock, appearance: .aqua)
    XCTAssertGreaterThan(min(light.redComponent, light.greenComponent, light.blueComponent), 0.8)
    XCTAssertLessThan(max(dark.redComponent, dark.greenComponent, dark.blueComponent), 0.3)
    XCTAssertGreaterThan(light.alphaComponent, 0.95)
    XCTAssertGreaterThan(dark.alphaComponent, 0.95)
  }

  func testIssueReportEncodesOnlyAppAndOSVersions() throws {
    let cases = [
      ("0.9.0-beta.1", "macOS 27.1"),
      ("build + preview & test#1", "macOS / नमस्ते"),
      ("v1\n&title=other&body=private", "https://other.invalid/#redirect")
    ]
    XCTAssertEqual(cases.count, 3)
    for (version, system) in cases {
      let url = IssueReport.url(appVersion: version, osVersion: system)
      let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
      XCTAssertEqual(components.scheme, "https")
      XCTAssertEqual(components.host, "github.com")
      XCTAssertEqual(components.path, "/anisharyal09/aniCe/issues/new")
      XCTAssertNil(components.fragment)
      XCTAssertNil(components.user)
      XCTAssertFalse(try XCTUnwrap(components.percentEncodedQuery).contains("+"),
        "A literal plus must survive GitHub's form-style query decoding")
      let fields = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value) })
      XCTAssertEqual(Set(fields.keys), ["template", "app-version", "os-version"])
      XCTAssertEqual(fields["template"], "bug_report.yml")
      XCTAssertEqual(fields["app-version"], version)
      XCTAssertEqual(fields["os-version"], system)
    }
  }

  @MainActor func testDockReopenRestoresMainWindowWhenOtherWindowsAreVisible() {
    let delegate = AppDelegate()
    var requests = 0
    delegate.reopenMainWindow = { requests += 1 }
    XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
    XCTAssertEqual(requests, 1)
  }

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
    XCTAssertEqual(AppFeature.favourites(in: "files,files,unknown,playback"), [.files, .playback])
    XCTAssertTrue(AppFeature.favourites(in: "unknown").isEmpty)
    XCTAssertTrue(AppFeature.favourites(in: "typeToMac").isEmpty)
    XCTAssertEqual(AppFeature.files.toggled(in: "files,unknown,playback"), "playback")
    XCTAssertEqual(AppFeature.findDevice.toggled(in: "files,files"), "files,findDevice")
    XCTAssertEqual(AppFeature.allCases.count, 6)
    for feature in AppFeature.allCases {
      XCTAssertEqual(AppFeature.favourites(in: feature.toggled(in: "")), [feature])
      XCTAssertEqual(feature.toggled(in: feature.toggled(in: "")), "")
    }
    let navigation = ConnectionNavigation()
    navigation.focusedPeer = "phone-a"
    navigation.diagnostics = true
    for origin in [AppDestination.home, .features, .favourites] {
      for feature in AppFeature.allCases {
        navigation.show(origin)
        navigation.openFeature(feature)
        XCTAssertEqual(navigation.destination, .features)
        XCTAssertEqual(navigation.featurePanel, feature)
        navigation.openFeature(feature)
        XCTAssertEqual(navigation.featureOrigin, origin)
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

  @MainActor func testHistoryRestoresNestedRoutesAndPeerAndBranchesAfterBack() {
    let navigation = ConnectionNavigation()
    navigation.goBack()
    navigation.goForward()
    XCTAssertFalse(navigation.canGoBack)
    navigation.show(.devices, peer: "phone-a", route: .pairing)
    navigation.showSettings(.identity)
    navigation.openFeature(.messages)
    navigation.goBack()
    XCTAssertEqual(navigation.destination, .settings)
    XCTAssertEqual(navigation.settingsRoute, .identity)
    navigation.goBack()
    XCTAssertEqual(navigation.destination, .devices)
    XCTAssertEqual(navigation.deviceRoute, .pairing)
    XCTAssertEqual(navigation.focusedPeer, "phone-a")
    navigation.goForward()
    XCTAssertEqual(navigation.destination, .settings)
    navigation.goForward()
    XCTAssertEqual(navigation.featurePanel, .messages)
    navigation.goBack()
    navigation.show(.about)
    XCTAssertFalse(navigation.canGoForward)
    navigation.goForward()
    XCTAssertEqual(navigation.destination, .about)
  }

  @MainActor func testHistoryIgnoresPreferenceChangesAndRepeatedNavigation() {
    let navigation = ConnectionNavigation()
    navigation.show(.home)
    navigation.automaticAfterPairing = false
    navigation.automaticLanAfterPairing = false
    XCTAssertFalse(navigation.canGoBack)
    navigation.select(.favourites)
    navigation.openFeature(.files)
    navigation.goBack()
    XCTAssertEqual(navigation.destination, .favourites)
    XCTAssertNil(navigation.featurePanel)
    navigation.goForward()
    XCTAssertEqual(navigation.featurePanel, .files)
    navigation.select(.features)
    XCTAssertNil(navigation.featurePanel)
    navigation.goBack()
    XCTAssertEqual(navigation.featurePanel, .files)
    XCTAssertFalse(navigation.automaticAfterPairing)
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
      ["Open aniCe", "Manage devices", "Show Floating Key  ⌥⌘K", "Quit aniCe"])
    XCTAssertEqual(items.filter(\.isSeparatorItem).count, 1)
    for item in items where !item.isSeparatorItem {
      XCTAssertTrue(item.target === target)
      XCTAssertNotNil(item.action)
    }
    XCTAssertEqual(Set(items.compactMap(\.action)).count, 4)
    XCTAssertEqual(CompanionHost.makeMenu(target: target, floatingKeyboardVisible: true).items[2].title,
      "Hide Floating Key  ⌥⌘K")
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
          XCTAssertEqual(result.summary, "Connected")
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
    XCTAssertEqual(presentation("Failed", "Secured", lanAllowing: true).summary, "Connected")
    XCTAssertEqual(presentation("Secured", "Failed", bleAllowing: true).action, .disconnect)
    XCTAssertEqual(presentation("Secured", "Connecting", bleAllowing: true, lanAllowing: true).summary,
      "Connected")
  }

}


@MainActor final class SettingsScrollTests: XCTestCase {
  func testTargetsClampAndRepeatWithoutLosingCompletion() {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    let document = FlippedSettingsDocument(frame: NSRect(x: 0, y: 0, width: 500, height: 1200))
    scroll.documentView = document
    let first = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 80))
    let last = NSView(frame: NSRect(x: 0, y: 1100, width: 450, height: 80))
    document.addSubview(first); document.addSubview(last)
    let coordinator = SettingsScrollCoordinator()
    coordinator.anchors = ["first": first, "last": last]
    var completions = 0
    coordinator.scroll(to: "last", animated: false) { completions += 1 }
    XCTAssertEqual(scroll.contentView.bounds.maxY, last.frame.maxY + 12, accuracy: 1)
    let bottomOffset = scroll.contentView.bounds.origin.y
    coordinator.scroll(to: "last", animated: false) { completions += 1 }
    XCTAssertEqual(scroll.contentView.bounds.origin.y, bottomOffset, accuracy: 1)
    XCTAssertEqual(completions, 2)
    coordinator.scroll(to: "first", animated: false) { completions += 1 }
    XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
    XCTAssertEqual(completions, 3)
    coordinator.scroll(to: "missing", animated: false) { XCTFail("Missing targets must not report a completed jump") }
    XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
  }

  func testVisibleSectionsDoNotMoveAndPartiallyHiddenHeadingsAreRevealed() {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    let document = FlippedSettingsDocument(frame: NSRect(x: 0, y: 0, width: 500, height: 1200))
    scroll.documentView = document
    let section = NSView(frame: NSRect(x: 0, y: 80, width: 450, height: 60))
    document.addSubview(section)
    let coordinator = SettingsScrollCoordinator()
    coordinator.anchors["appearance"] = section
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
    coordinator.scroll(to: "appearance", animated: false) {}
    XCTAssertEqual(scroll.contentView.bounds.minY, 40, accuracy: 1)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
    coordinator.scroll(to: "appearance", animated: false) {}
    XCTAssertEqual(scroll.contentView.bounds.minY, 68, accuracy: 1)
    XCTAssertTrue(scroll.documentVisibleRect.contains(section.frame))
  }
}

private final class FlippedSettingsDocument: NSView {
  override var isFlipped: Bool { true }
}

@MainActor final class MainWindowSizingTests: XCTestCase {
  func testRoomierWindowAndExactSidebarIconDefaults() {
    XCTAssertEqual(MainWindowSizing.defaultSize, CGSize(width: 960, height: 640))
    XCTAssertEqual(MainWindowSizing.sidebarIconSize, 27)
    XCTAssertEqual(MainWindowSizing.sidebarBreathingRoom, 12)
    XCTAssertEqual(MainWindowSizing.sidebarMaximumWidth, 250)
  }

  func testCompactSidebarFitsAllLabelsAndBrandingAtSupportedTextSizes() {
    let scales = [0.8, 1.0, 1.2]
    XCTAssertEqual(scales.count, 3)
    XCTAssertEqual(AppDestination.primary.count, 6)
    for scale in scales {
      let minimum = MainWindowSizing.sidebarMinimumWidth(fontScale: scale)
      let preferred = minimum + MainWindowSizing.sidebarBreathingRoom
      let insets = 4 * MainWindowSizing.sidebarInset
      let wordmark = NSAttributedString(string: "aniCe", attributes: [
        .font: NSFont.systemFont(ofSize: 21 * scale, weight: .semibold)
      ]).size().width
      XCTAssertGreaterThanOrEqual(minimum, insets + 27 + 8 + wordmark)
      for destination in AppDestination.primary {
        for weight in [NSFont.Weight.regular, .medium] {
          let label = NSAttributedString(string: destination.rawValue, attributes: [
            .font: NSFont.systemFont(ofSize: 13 * scale, weight: weight)
          ]).size().width
          XCTAssertGreaterThanOrEqual(minimum, insets + 18 + 12 + label, destination.rawValue)
        }
      }
      XCTAssertEqual(minimum.truncatingRemainder(dividingBy: 4), 0)
      XCTAssertLessThan(preferred, 210, "The initial sidebar stays narrower than the previous default")
      XCTAssertLessThan(preferred, MainWindowSizing.sidebarMaximumWidth, "Native widening remains available")
    }
  }
}

final class BetaUpdatePreferenceTests: XCTestCase {
  func testConsentDefersOnlyEnablementAndCancelKeepsTheSettingOff() {
    var consent = BetaUpdateConsent()
    XCTAssertNil(consent.request(true, current: false))
    XCTAssertTrue(consent.confirming)
    consent.cancel()
    XCTAssertFalse(consent.confirming)
    XCTAssertNil(consent.request(true, current: false))
    XCTAssertTrue(consent.confirm())
    XCTAssertFalse(consent.confirming)
  }

  func testDisablingBetaUpdatesIsImmediateAndNeedsNoConfirmation() {
    var consent = BetaUpdateConsent()
    XCTAssertEqual(consent.request(false, current: true), false)
    XCTAssertFalse(consent.confirming)
    XCTAssertEqual(consent.request(false, current: false), false)
    XCTAssertFalse(consent.confirming)
  }
}
