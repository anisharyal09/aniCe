// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies navigation, appearance and readiness presentation without changing connection ownership.
import CryptoKit
import AppKit
import Foundation
import XCTest
import SwiftUI
import Observation
import Carbon
import UserNotifications
import Vision

@testable import aniCe

extension SessionTests {
  func testNavigationGlassPresetsUseDistinctBackingWithoutChangingSolidFallback() {
    for scheme in [ColorScheme.light, .dark] {
      let standard = NativeGlassStyle.standard.navigationBackingOpacity(scheme)
      let vibrant = NativeGlassStyle.vibrant.navigationBackingOpacity(scheme)
      XCTAssertGreaterThan(standard - vibrant, 0.25)
      XCTAssertTrue((0...1).contains(standard))
      XCTAssertTrue((0...1).contains(vibrant))
    }
    XCTAssertEqual(NativeGlassPresentation.resolve(enabled: false, reduceTransparency: false, supportsGlass: true), .solid)
    XCTAssertEqual(NativeGlassPresentation.resolve(enabled: true, reduceTransparency: true, supportsGlass: true), .solid)
  }

  func testSidebarPinsUseIndependentOrderedLocalList() {
    let favourites = AppFeature.defaultFavourites
    let menu = AppFeature.defaultPinnedToCompanion
    let sidebar = AppFeature.files.toggled(in: "")
    XCTAssertEqual(AppFeature.favourites(in: sidebar), [.files])
    XCTAssertEqual(AppFeature.favourites(in: sidebar + ",files,unknown"), [.files])
    XCTAssertEqual(AppFeature.files.toggled(in: sidebar), "")
    XCTAssertEqual(favourites, AppFeature.defaultFavourites)
    XCTAssertEqual(menu, AppFeature.defaultPinnedToCompanion)
    XCTAssertEqual(AniCeSupport.url.scheme, "https")
    XCTAssertEqual(AniCeSupport.url.host, "anisharyal09.com.np")
  }

  @MainActor func testGlobalShortcutFailureAndCollisionPreserveSavedBinding() throws {
    let name = "aniCe.ShortcutTests.\(UUID())"
    let storage = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { storage.removePersistentDomain(forName: name) }
    var allow = false
    var attempts = 0
    let preferences = GlobalShortcutPreferences(storage: storage) { _, _ in attempts += 1; return allow }
    let candidate = GlobalShortcut(keyCode: 0, shift: true)
    XCTAssertFalse(preferences.set(candidate, for: .tray))
    XCTAssertEqual(preferences.binding(.tray), GlobalShortcutAction.tray.defaultBinding)
    XCTAssertNil(storage.dictionary(forKey: "ui.globalShortcut.tray"))
    XCTAssertFalse(preferences.set(preferences.binding(.floatingKey), for: .tray))
    XCTAssertEqual(attempts, 1, "Internal collisions must not reach native registration")
    allow = true
    XCTAssertTrue(preferences.set(candidate, for: .tray))
    XCTAssertEqual(preferences.binding(.tray), candidate)
    XCTAssertNil(preferences.errors[.tray])
    let restored = GlobalShortcutPreferences(storage: storage) { _, _ in true }
    XCTAssertEqual(restored.binding(.tray), candidate)
    XCTAssertFalse(preferences.set(GlobalShortcut(keyCode: 53, shift: false), for: .tray))
    XCTAssertEqual(preferences.binding(.tray), candidate)
  }

  @MainActor func testShortcutCaptureRejectsEditingAndSystemCombinations() throws {
    let reserved: [(UInt16, NSEvent.ModifierFlags)] = [
      (0, .command), (6, .command), (6, [.command, .shift]), (9, .command),
      (6, .control), (4, [.command, .option]), (2, [.command, .option]),
      (46, [.command, .option]), (53, [.command, .option]),
      (12, [.command, .option, .shift]), (12, [.command, .control]),
      (49, .command), (48, .command), (53, [.command, .shift]),
    ]
    XCTAssertGreaterThanOrEqual(reserved.count, 12)
    for (code, flags) in reserved {
      XCTAssertFalse(GlobalShortcut(keyCode: code, modifierFlags: flags).valid)
    }
    for flags: NSEvent.ModifierFlags in [.command, [.command, .shift], .control, [], .shift] {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
        characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
      XCTAssertNil(GlobalShortcut.captured(event))
    }
    let permitted: [(UInt16, NSEvent.ModifierFlags)] = [
      (0, [.command, .option, .shift]), (0, [.control, .shift]), (6, [.control, .option]),
      (40, [.command, .shift]), (7, [.control, .shift]), (50, .control), (18, .option),
      (123, [.control, .option]), (36, [.command, .option]), (53, [.control, .option]),
      (122, []), (120, .shift), (118, .control),
    ]
    XCTAssertGreaterThanOrEqual(permitted.count, 12)
    for (code, flags) in permitted {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
        characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: code))
      XCTAssertEqual(GlobalShortcut.captured(event), GlobalShortcut(keyCode: code, modifierFlags: flags))
    }
    XCTAssertFalse(GlobalShortcut(keyCode: 999, modifierFlags: .control).valid)
    XCTAssertFalse(GlobalShortcut(keyCode: 40, modifierFlags: [.control, .capsLock]).valid)
  }

  @MainActor func testExpandedShortcutPersistenceRetainsLegacyBindingsAndRejectsMalformedState() throws {
    let name = "aniCe.ExpandedShortcuts.\(UUID())"
    let storage = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { storage.removePersistentDomain(forName: name) }
    storage.set(["keyCode": 40, "shift": true], forKey: "ui.globalShortcut.tray")
    let preferences = GlobalShortcutPreferences(storage: storage) { _, _ in true }
    XCTAssertEqual(preferences.binding(.tray), GlobalShortcut(keyCode: 40, shift: true))
    let expanded = GlobalShortcut(keyCode: 40, modifierFlags: [.control, .shift])
    XCTAssertTrue(preferences.set(expanded, for: .tray))
    let restored = GlobalShortcutPreferences(storage: storage) { _, _ in true }
    XCTAssertEqual(restored.binding(.tray), expanded)
    XCTAssertEqual(expanded.modifiers, UInt32(controlKey | shiftKey))
    XCTAssertEqual(expanded.label, "⌃⇧K")
    XCTAssertEqual(GlobalShortcut(keyCode: 122, modifierFlags: []).label, "F1")
    for invalid in [
      ["keyCode": -1, "modifiers": Int(NSEvent.ModifierFlags.control.rawValue)],
      ["keyCode": 999, "modifiers": Int(NSEvent.ModifierFlags.control.rawValue)],
      ["keyCode": 40, "modifiers": -1],
      ["keyCode": 40, "modifiers": Int(NSEvent.ModifierFlags.capsLock.rawValue)],
    ] {
      storage.set(invalid, forKey: "ui.globalShortcut.tray")
      XCTAssertEqual(GlobalShortcutPreferences(storage: storage).binding(.tray), GlobalShortcutAction.tray.defaultBinding)
    }
  }

  func testEnabledSystemShortcutDetectionRequiresExactKeyAndModifiers() {
    let binding = GlobalShortcut(keyCode: 40, modifierFlags: [.control, .option])
    let row: [String: Any] = [
      kHISymbolicHotKeyEnabled as String: true,
      kHISymbolicHotKeyCode as String: Int(binding.keyCode),
      kHISymbolicHotKeyModifiers as String: Int(binding.modifiers),
    ]
    XCTAssertTrue(GlobalShortcut.matchesEnabledSystemHotkey(binding, entries: [row]))
    var disabled = row
    disabled[kHISymbolicHotKeyEnabled as String] = false
    XCTAssertFalse(GlobalShortcut.matchesEnabledSystemHotkey(binding, entries: [disabled]))
    XCTAssertFalse(GlobalShortcut.matchesEnabledSystemHotkey(
      GlobalShortcut(keyCode: 40, modifierFlags: .control), entries: [row]))
    XCTAssertFalse(GlobalShortcut.matchesEnabledSystemHotkey(binding, entries: [[:]]))
  }

  @MainActor func testPermissionSummaryHidesGrantedRowsInAllAndReflowsInPermissions() throws {
    let name = "aniCe.PermissionSummaryTests.\(UUID())"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("anice-permission-refinement-renders", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let native = ClipboardNativeFake()
    let clipboard = MacClipboardModel(native: native)
    defer { clipboard.invalidate() }
    for status in [UNAuthorizationStatus.authorized, .provisional] {
      let empty = NSHostingView(rootView: MacPermissionSummary(
        clipboard: clipboard, notifications: status, showGranted: false).frame(width: 300))
      empty.frame.size = empty.fittingSize
      empty.layoutSubtreeIfNeeded()
      XCTAssertLessThan(empty.bounds.height, 1, "Granted permission rows must not occupy All")
    }
    XCTAssertFalse(MacPermissionSummary.notificationsAllowed(.denied))
    XCTAssertFalse(MacPermissionSummary.notificationsAllowed(.notDetermined))
    XCTAssertFalse(MacPermissionSummary.notificationsAllowed(nil))
    var renders = 0
    for showGranted in [false, true] {
      for scheme in [ColorScheme.light, .dark] {
        for width in [280.0, 600.0] {
          for allowed in [false, true] {
            native.automaticAccessAllowed = allowed
            let view = MacPermissionSummary(clipboard: clipboard,
              notifications: allowed ? .authorized : .denied, showGranted: showGranted)
              .font(.system(size: 13 * 1.2)).padding(14).frame(width: width)
              .background(AniCePalette.surface(scheme))
              .environment(\.colorScheme, scheme).defaultAppStorage(preferences)
            preferences.set(1.2, forKey: "ui.fontScale")
            let host = NSHostingView(rootView: view)
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.width, width, accuracy: 1)
            XCTAssertLessThan(host.bounds.height, 380)
            if showGranted { XCTAssertGreaterThan(host.bounds.height, 90) }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
              .write(to: directory.appendingPathComponent("permissions-\(showGranted)-\(scheme)-\(Int(width))-\(allowed).png"))
            renders += 1
          }
        }
      }
    }
    XCTAssertEqual(renders, 16)
    XCTAssertEqual(native.writes, 0)
    print("Permission summary renders: \(directory.path)")
  }

  @MainActor func testFeatureSettingsTargetSurvivesBackAndForward() {
    let navigation = ConnectionNavigation()
    navigation.openFeature(.clipboard)
    navigation.openSettings(section: "clipboard")
    XCTAssertEqual(navigation.destination, .settings)
    XCTAssertEqual(navigation.settingsSection, "clipboard")
    navigation.goBack()
    XCTAssertEqual(navigation.featurePanel, .clipboard)
    navigation.goForward()
    XCTAssertEqual(navigation.settingsSection, "clipboard")
  }

  func testNativeGlassAccessibilityOverridesEveryStyleWithoutChangingPreference() {
    XCTAssertEqual(NativeGlassStyle.stored("invalid"), .standard)
    XCTAssertEqual(NativeGlassStyle.allCases.count, 2)
    for enabled in [false, true] {
      for supported in [false, true] {
        XCTAssertEqual(NativeGlassPresentation.resolve(enabled: enabled,
          reduceTransparency: true, supportsGlass: supported), .solid)
        XCTAssertEqual(NativeGlassPresentation.resolve(enabled: enabled,
          reduceTransparency: false, supportsGlass: supported),
          enabled ? (supported ? .glass : .material) : .solid)
      }
    }
  }

  func testSettingsCategoriesKeepAppearanceInGeneralAndFeaturesReachable() {
    XCTAssertEqual(MacSettingsCategory.allCases.count, 5)
    for section in ["appearance", "updates", "connection", "this-device"] {
      XCTAssertEqual(MacSettingsCategory.category(for: section), .general)
    }
    XCTAssertEqual(MacSettingsCategory.category(for: "permissions"), .permissions)
    XCTAssertEqual(MacSettingsCategory.category(for: "shortcuts"), .shortcuts)
    for section in ["clipboard", "messages", "desk-deck", "dnd-sync", "file-transfer", "now-playing"] {
      XCTAssertEqual(MacSettingsCategory.category(for: section), .features)
    }
  }

  @MainActor func testNativeGlassPreferencesRenderWithoutOverwritingAccessibilityLockedChoice() throws {
    let name = "aniCe.NativeGlassTests.\(UUID())"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("anice-native-glass-renders", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var renders = 0
    for style in NativeGlassStyle.allCases {
      for scheme in [ColorScheme.light, .dark] {
        for reduced in [false, true] {
          for scale in [0.8, 1.2] {
            preferences.set(true, forKey: "ui.nativeGlass")
            preferences.set(style.rawValue, forKey: "ui.nativeGlassStyle")
            preferences.set(scale, forKey: "ui.fontScale")
            let view = NativeGlassPreferencesRows(
              enabled: Binding(get: { preferences.bool(forKey: "ui.nativeGlass") },
                set: { preferences.set($0, forKey: "ui.nativeGlass") }),
              savedStyle: Binding(get: { preferences.string(forKey: "ui.nativeGlassStyle") ?? "" },
                set: { preferences.set($0, forKey: "ui.nativeGlassStyle") }),
              fontScale: scale, reduceTransparency: reduced)
              .padding(14).frame(width: 280)
              .background(AniCePalette.surface(scheme))
              .environment(\.colorScheme, scheme)
              .defaultAppStorage(preferences)
            let host = NSHostingView(rootView: view)
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.width, 280)
            XCTAssertLessThan(host.bounds.height, 220)
            XCTAssertTrue(preferences.bool(forKey: "ui.nativeGlass"))
            XCTAssertEqual(preferences.string(forKey: "ui.nativeGlassStyle"), style.rawValue)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
              .write(to: folder.appendingPathComponent("glass-\(style)-\(scheme)-\(reduced)-\(Int(scale * 100)).png"))
            renders += 1
          }
        }
      }
    }
    XCTAssertEqual(renders, 16)
    print("Native Glass preference renders: \(folder.path)")
  }

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

  func testEmailLinkContainsOnlyThePublicAddressAndFixedSubject() throws {
    let components = try XCTUnwrap(URLComponents(url: IssueReport.emailURL, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.scheme, "mailto")
    XCTAssertEqual(components.path, "anish.creations.hq@gmail.com")
    XCTAssertNil(components.fragment)
    XCTAssertEqual(components.queryItems, [URLQueryItem(name: "subject", value: "[aniCe] Feedback & Support")])
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
    XCTAssertEqual(presentation("Connecting", bleAllowing: true).action, .cancel)
    XCTAssertEqual(presentation(automatic: true).summary, "Waiting nearby")
    XCTAssertEqual(presentation(automatic: true).action, .stop)
    XCTAssertEqual(presentation("Failed", "Secured", lanAllowing: true).summary, "Connected")
    XCTAssertEqual(presentation("Secured", "Failed", bleAllowing: true).action, .disconnect)
    XCTAssertEqual(presentation("Secured", "Connecting", bleAllowing: true, lanAllowing: true).summary,
      "Connected")
  }

  func testPausedPresentationOffersExplicitConnectDespiteStaleAdmission() {
    for bluetooth in ["Disconnected", "Connecting", "Failed", "Secured"] {
      for lan in ["Disconnected", "Connecting", "Failed", "Secured"] {
        let presentation = ConnectionPresentation(bluetooth: bluetooth, lan: lan,
          bluetoothAllowing: true, lanAllowing: true, automatic: true, paused: true)
        if bluetooth == "Secured" || lan == "Secured" {
          XCTAssertTrue(presentation.connected)
          XCTAssertEqual(presentation.action, .disconnect)
        } else {
          XCTAssertEqual(presentation.summary, "Paused")
          XCTAssertEqual(presentation.action, .allow)
        }
      }
    }
  }

}

@MainActor
final class PauseMenuTests: XCTestCase {
  func testPauseMenuGroupsExistingChoicesWithoutHidingResumeBehindAMenu() {
    let handler = MacPauseMenuHandler(), items = handler.makeMenu().items
    XCTAssertEqual(items.filter { !$0.isSeparatorItem }.map(\.title),
      ["1 hour", "3 hours", "6 hours", "Until I resume", "Custom…"])
    XCTAssertEqual(items.indices.filter { items[$0].isSeparatorItem }, [3, 5])
    for item in items where !item.isSeparatorItem {
      XCTAssertTrue(item.target === handler)
      XCTAssertNotNil(item.action)
    }
    var durations: [TimeInterval?] = [], custom = 0
    handler.onPause = { durations.append($0) }
    handler.onCustom = { custom += 1 }
    handler.select1Hour(); handler.select3Hours(); handler.select6Hours()
    handler.selectUntilResume(); handler.selectCustom()
    XCTAssertEqual(durations.count, 4)
    XCTAssertEqual(durations.compactMap { $0 }, [3600, 10800, 21600])
    XCTAssertNil(durations.last!)
    XCTAssertEqual(custom, 1)
  }
}


@MainActor final class SettingsScrollTests: XCTestCase {
  func testDeferredSettingsTargetWaitsForAttachmentAndReplacementWins() {
    let coordinator = SettingsScrollCoordinator()
    var completed: [String] = []
    coordinator.request("old") { completed.append("old") }
    coordinator.request("new") { completed.append("new") }
    coordinator.resolvePending()
    XCTAssertTrue(completed.isEmpty)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    let document = FlippedSettingsDocument(frame: NSRect(x: 0, y: 0, width: 500, height: 1200))
    scroll.documentView = document
    let target = NSView(frame: NSRect(x: 0, y: 900, width: 450, height: 80))
    document.addSubview(target)
    coordinator.anchors["new"] = target
    coordinator.resolvePending()
    coordinator.resolvePending()
    XCTAssertEqual(completed, ["new"])
    XCTAssertTrue(scroll.documentVisibleRect.contains(target.frame))
  }

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

  func testDetachedAnimatedScrollCompletesDirectlyOnTheMainActorAtTheTarget() async {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    let document = FlippedSettingsDocument(frame: NSRect(x: 0, y: 0, width: 500, height: 1200))
    scroll.documentView = document
    let target = NSView(frame: NSRect(x: 0, y: 900, width: 450, height: 80))
    document.addSubview(target)
    let coordinator = SettingsScrollCoordinator()
    coordinator.anchors["target"] = target
    let completed = expectation(description: "main-actor animation completion")
    coordinator.scroll(to: "target", animated: true) {
      MainActor.assertIsolated()
      XCTAssertTrue(scroll.documentVisibleRect.contains(target.frame))
      completed.fulfill()
    }
    await fulfillment(of: [completed], timeout: 5)
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

@MainActor final class AboutFeedbackLinksTests: XCTestCase {
  func testIssueAndEmailActionsOpenIndependentDestinationsWithoutSendingData() async throws {
    let report = IssueReport.url(appVersion: "0.9.0-beta.4", osVersion: "macOS fixture")
    for scheme in [ColorScheme.light, .dark] {
      for scale in [0.8, 1.0, 1.2] {
        for width in [220.0, 600.0] {
          var opened = [URL]()
          let content = AboutFeedbackLinks(reportURL: report, fontScale: scale)
            .environment(\.colorScheme, scheme)
            .environment(\.openURL, OpenURLAction { url in opened.append(url); return .handled })
            .frame(width: width)
          let host = NSHostingView(rootView: content)
          let size = host.fittingSize
          let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
          window.isReleasedWhenClosed = false
          window.contentView = host
          window.orderFront(nil)
          defer { window.contentView = nil; window.close() }
          try await Task.sleep(for: .milliseconds(80))
          host.layoutSubtreeIfNeeded()
          XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
          XCTAssertTrue(opened.isEmpty, "Rendering About must not open a mail composer or issue form")
          XCTAssertNil(window.firstResponder as? NSTextView)
          for point in [NSPoint(x: 45, y: 18), NSPoint(x: width - 16, y: size.height - 18)] {
            let location = host.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
              let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
              window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(80))
          }
          XCTAssertEqual(opened, [report, IssueReport.emailURL])
        }
      }
    }
  }
}

@MainActor final class AboutSupportLinksTests: XCTestCase {
  func testCenteredNativeLinksOpenOnlyTheirDestinationAcrossThemesAndTextSizes() async throws {
    for scheme in [ColorScheme.light, .dark] {
      for scale in [0.8, 1.0, 1.2] {
        for width in [300.0, 600.0] {
          var opened = [URL]()
          let content = AboutSupportLinks(fontScale: scale)
            .environment(\.colorScheme, scheme)
            .environment(\.openURL, OpenURLAction { url in opened.append(url); return .handled })
            .frame(width: width, height: 64, alignment: .top)
          let host = NSHostingView(rootView: content)
          let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 64),
            styleMask: [.titled], backing: .buffered, defer: false)
          window.isReleasedWhenClosed = false
          window.contentView = host
          window.orderFront(nil)
          defer { window.contentView = nil; window.close() }
          try await Task.sleep(for: .milliseconds(80))
          host.layoutSubtreeIfNeeded()
          XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
          XCTAssertTrue(opened.isEmpty, "Rendering a reminder must not open any URL")
          XCTAssertNil(window.firstResponder as? NSTextView, "About must not acquire typing focus")
          // Both native targets are centered, with separate 32 pt rows.
          for y in [16.0, 48.0] {
            let location = host.convert(NSPoint(x: width / 2, y: y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
              let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
              window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(80))
          }
          XCTAssertEqual(opened.map(\.absoluteString), [
            "https://anisharyal09.com.np/support?from=anice",
            "https://github.com/anisharyal09/aniCe",
          ])
        }
      }
    }
  }
}

@MainActor final class AutomaticUpdateCheckOptionsTests: XCTestCase {
  func testNativeClicksExpandToggleAndCollapseWithoutBlockingManualChecks() async throws {
    let name = "aniCe.UpdateOptionsTests.\(UUID())", preferences = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    let model = MacUpdateModel(discovery: MacReleaseDiscovery(defaults: preferences))
    var manualChecks = 0
    let content = VStack(alignment: .leading, spacing: 16) {
      AutomaticUpdateCheckOptions(checked: Binding(get: { model.automaticChecks }, set: { model.automaticChecks = $0 }))
      Button("Check for updates") { manualChecks += 1 }.buttonStyle(AniCeButtonStyle())
    }
    .font(.system(size: 13)).padding(14)
    .frame(width: 340, height: 280, alignment: .topLeading)
    .defaultAppStorage(preferences).disclosureGroupStyle(ClickableDisclosureStyle())
    let host = NSHostingView(rootView: content)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 280),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    try await settle(host)
    XCTAssertTrue(model.automaticChecks)
    try click(host, in: window, at: NSPoint(x: 70, y: 22))
    try await settle(host)
    // Toggle is the first disclosed row, beneath the 16 pt disclosure and its shared 10 pt gap.
    try click(host, in: window, at: NSPoint(x: 21, y: 49))
    try await settle(host)
    XCTAssertFalse(model.automaticChecks)
    try click(host, in: window, at: NSPoint(x: 70, y: 22))
    try await settle(host)
    // The off-state caption remains between the collapsed disclosure and manual action.
    try click(host, in: window, at: NSPoint(x: 80, y: 77))
    try await settle(host)
    XCTAssertEqual(manualChecks, 1)
    XCTAssertFalse(model.automaticChecks)
    try click(host, in: window, at: NSPoint(x: 70, y: 22))
    try await settle(host)
    try click(host, in: window, at: NSPoint(x: 21, y: 49))
    try await settle(host)
    XCTAssertTrue(model.automaticChecks)
  }

  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(80))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
  }

  private func click(_ host: NSView, in window: NSWindow, at point: NSPoint) throws {
    let location = host.convert(point, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      window.sendEvent(event)
    }
  }

  func testOptionsRenderCollapsedAndExpandedInBothThemesAtSupportedSizes() throws {
    let name = "aniCe.UpdateOptionsTests.\(UUID())", preferences = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    var renders = 0
    for scheme in [ColorScheme.light, .dark] {
      for scale in [0.8, 1.0, 1.2] {
        for width in [300.0, 600.0] {
          preferences.set(scale, forKey: "ui.fontScale")
          for checked in [true, false] {
            var collapsedHeight = 0.0
            for expanded in [false, true] {
              let content = VStack(alignment: .leading, spacing: 8) {
                Text("Updates").font(.system(size: 13 * scale, weight: .medium))
                BetaUpdatePreference(checked: .constant(false))
                Button("Check for updates") {}.buttonStyle(AniCeButtonStyle())
                AutomaticUpdateCheckOptions(checked: .constant(checked), expanded: expanded)
              }
              .font(.system(size: 13 * scale)).padding(14).frame(width: width, alignment: .leading)
              .background(AniCePalette.surface(scheme)).environment(\.colorScheme, scheme)
              .tint(AniCePalette.primaryText(scheme)).defaultAppStorage(preferences)
              .disclosureGroupStyle(ClickableDisclosureStyle())
              let host = NSHostingView(rootView: content)
              host.frame.size = host.fittingSize
              host.layoutSubtreeIfNeeded()
              XCTAssertEqual(host.bounds.width, width, accuracy: 1)
              XCTAssertGreaterThan(host.bounds.height, 90)
              XCTAssertLessThan(host.bounds.height, 360)
              if expanded { XCTAssertGreaterThan(host.bounds.height, collapsedHeight + 20) }
              else { collapsedHeight = host.bounds.height }
              try capture(host, name: "automatic-updates-\(checked ? "on" : "off")-\(expanded ? "expanded" : "collapsed")-\(scheme)-\(Int(width))-\(Int(scale * 100))")
              renders += 1
            }
          }
        }
      }
    }
    XCTAssertEqual(renders, 48)
  }

  private func capture(_ host: NSView, name: String) throws {
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    XCTAssertGreaterThan(data.count, 1000)
    if let path = ProcessInfo.processInfo.environment["ANICE_REVIEW_RENDER_DIR"] {
      let directory = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
  }
}

@MainActor final class PreferenceToggleTests: XCTestCase {
  @Observable final class FixtureState {
    var checked = false
    var enabled = true
    var requests: [Bool] = []
    var confirming = false
  }

  private struct PreferenceFixture: View {
    let state: FixtureState
    var requiresConsent = false
    var body: some View {
      Toggle("Enable option", isOn: Binding(
        get: { state.checked }, set: {
          state.requests.append($0)
          if $0 && requiresConsent { state.confirming = true } else { state.checked = $0 }
        }))
        .toggleStyle(AniCePreferenceToggleStyle(description: "Helper text"))
        .disabled(!state.enabled)
    }
  }

  private struct SegmentedFixture: View {
    let state: FixtureState
    var body: some View {
      AniCeSegmentedControl(
        options: [(value: false, title: "Share"), (value: true, title: "History")],
        selection: Binding(get: { state.checked }, set: { state.checked = $0; state.requests.append($0) }),
        accessibilityLabel: "Clipboard view"
      )
      .disabled(!state.enabled)
    }
  }

  func testLabelHelperAndCapsuleUseOneBindingAndDisabledRowsIgnoreClicks() async throws {
    let name = "aniCe.PreferenceToggleTests.\(UUID())"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    for scheme in [ColorScheme.light, .dark] {
      for direction in [LayoutDirection.leftToRight, .rightToLeft] {
        for width in [260.0, 600.0] {
          let state = FixtureState()
          let content = PreferenceFixture(state: state)
            .font(.system(size: 13)).frame(height: 60)
            .padding(14).frame(width: width, height: 120, alignment: .topLeading)
            .environment(\.colorScheme, scheme).environment(\.layoutDirection, direction)
            .defaultAppStorage(preferences)
          let host = NSHostingView(rootView: content)
          let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
          window.isReleasedWhenClosed = false
          window.contentView = host
          window.orderFront(nil)
          defer { window.contentView = nil; window.close() }
          try await settle(host)
          XCTAssertTrue(state.requests.isEmpty, "Rendering must not write preferences")
          let labelX = direction == .leftToRight ? 40.0 : width - 40
          let capsuleX = direction == .leftToRight ? width - 36 : 36.0
          let points = [NSPoint(x: labelX, y: 34), NSPoint(x: labelX, y: 54), NSPoint(x: capsuleX, y: 44)]
          for point in points {
            try click(host, in: window, at: point)
            try await settle(host)
          }
          XCTAssertEqual(state.requests, [true, false, true], "Each face must activate the same binding once")
          XCTAssertTrue(state.checked)
          state.enabled = false
          try await settle(host)
          for point in points { try click(host, in: window, at: point) }
          try await settle(host)
          XCTAssertEqual(state.requests, [true, false, true], "Disabled labels and capsules must not activate")
        }
      }
    }
  }

  func testDeferredConsentStaysOffUntilTheOwnerConfirms() async throws {
    let state = FixtureState()
    let content = PreferenceFixture(state: state, requiresConsent: true)
      .font(.system(size: 13)).frame(height: 60).padding(14)
      .frame(width: 340, height: 120, alignment: .topLeading)
    let host = NSHostingView(rootView: content)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 120),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.contentView = nil; window.close() }
    try await settle(host)
    try click(host, in: window, at: NSPoint(x: 40, y: 34))
    try await settle(host)
    XCTAssertTrue(state.confirming)
    XCTAssertFalse(state.checked, "The face must not enable itself while consent is pending")
    state.confirming = false
    try click(host, in: window, at: NSPoint(x: 304, y: 44))
    try await settle(host)
    XCTAssertEqual(state.requests, [true, true], "Cancelling consent leaves both click routes requesting enablement")
    state.checked = true
    state.confirming = false
    try await settle(host)
    try click(host, in: window, at: NSPoint(x: 40, y: 34))
    try await settle(host)
    XCTAssertEqual(state.requests, [true, true, false])
    XCTAssertFalse(state.checked)
    XCTAssertFalse(state.confirming)
  }

  func testAccessibleControlMatchesNativeSwitchAndDoesNotDuplicateLabelActions() async throws {
    let state = FixtureState()
    let native = NSHostingView(rootView: Toggle("Enable option", isOn: .constant(false))
      .toggleStyle(.switch).frame(width: 340, height: 120))
    let nativeWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 120),
      styleMask: [.titled], backing: .buffered, defer: false)
    nativeWindow.isReleasedWhenClosed = false
    nativeWindow.contentView = native
    nativeWindow.orderFront(nil)
    defer { nativeWindow.contentView = nil; nativeWindow.close() }
    try await settle(native)
    let nativeElements = accessibilityElements(native)
    guard let nativeControl = nativeElements.first(where: {
      $0.accessibilityRole() == .checkBox
    }) else {
      throw XCTSkip("This hosted runner exposes no accessibility children even for a native SwiftUI switch; verify with VoiceOver in a live app.")
    }
    let host = NSHostingView(rootView: PreferenceFixture(state: state)
      .font(.system(size: 13)).padding(14).frame(width: 340, height: 120))
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 120),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.contentView = nil; window.close() }
    try await settle(host)
    let elements = accessibilityElements(host)
    let controls = elements.filter { $0.accessibilityRole() == nativeControl.accessibilityRole() }
    XCTAssertEqual(controls.count, 1, "Label and capsule must expose one native switch, not two controls")
    let control = try XCTUnwrap(controls.first)
    let nativeLabel = accessibleLabel(nativeControl)
    XCTAssertEqual(nativeLabel, "Enable option")
    XCTAssertEqual(accessibleLabel(control), nativeLabel)
    XCTAssertEqual((control.accessibilityValue() as? NSNumber)?.boolValue, false)
    XCTAssertFalse(elements.contains { $0.accessibilityRole() == .button }, "Visible label is not a second accessibility action")
    XCTAssertTrue(control.accessibilityPerformPress())
    try await settle(host)
    XCTAssertTrue(state.checked)
    XCTAssertEqual(state.requests, [true])
    let updated = try XCTUnwrap(accessibilityElements(host).first { $0.accessibilityRole() == .checkBox })
    XCTAssertEqual((updated.accessibilityValue() as? NSNumber)?.boolValue, true)
    state.enabled = false
    try await settle(host)
    let disabled = try XCTUnwrap(accessibilityElements(host).first { $0.accessibilityRole() == .checkBox })
    XCTAssertFalse(disabled.isAccessibilityEnabled())
  }

  func testSegmentedControlKeepsOneSelectionAcrossThemes() async throws {
    for scheme in [ColorScheme.light, .dark] {
      let state = FixtureState()
      let host = NSHostingView(rootView: SegmentedFixture(state: state)
        .frame(width: 260, height: 80, alignment: .leading).padding(10)
        .background(AniCePalette.surface(scheme))
        .environment(\.colorScheme, scheme))
      let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 100),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.orderFront(nil)
      defer { window.contentView = nil; window.close() }
      try await settle(host)

      try click(host, in: window, at: NSPoint(x: 94, y: 50))
      try await settle(host)
      XCTAssertTrue(state.checked, "Tapping the trailing segment updates one binding")
      try click(host, in: window, at: NSPoint(x: 94, y: 50))
      try await settle(host)
      XCTAssertEqual(state.requests, [true], "Reselecting a tab must not repeat its action")
      try click(host, in: window, at: NSPoint(x: 32, y: 50))
      try await settle(host)
      XCTAssertFalse(state.checked, "Tapping the leading segment is the only other choice")
      state.enabled = false
      try await settle(host)
      try click(host, in: window, at: NSPoint(x: 94, y: 50))
      try await settle(host)
      XCTAssertEqual(state.requests, [true, false], "Disabled segments cannot activate")
    }
  }

  func testSegmentsStayContentSizedAcrossThemesAndTextSizes() throws {
    var requests = 0, renders = 0
    for scheme in [ColorScheme.light, .dark] {
      for scale in [0.8, 1.2] {
        for titles in [["Share", "History"], ["All", "Pinned", "Mac", "Phone"]] {
          let control = AniCeSegmentedControl(
            options: titles.map { (value: $0, title: $0) },
            selection: Binding(get: { titles[0] }, set: { _ in requests += 1 }),
            fontScale: scale
          )
          let host = NSHostingView(rootView: control.environment(\.colorScheme, scheme))
          host.frame.size = host.fittingSize
          host.layoutSubtreeIfNeeded()
          XCTAssertLessThan(host.bounds.width, titles.count == 2 ? 180 : 260,
            "A segmented control must not stretch across the workspace")
          XCTAssertGreaterThan(host.bounds.width, 70)
          XCTAssertLessThan(host.bounds.height, 40)
          let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          host.cacheDisplay(in: host.bounds, to: bitmap)
          let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          if let path = ProcessInfo.processInfo.environment["ANICE_REVIEW_RENDER_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("segments-\(titles.count)-\(scheme)-\(Int(scale * 100)).png"))
          }
          renders += 1
        }
      }
    }
    XCTAssertEqual(renders, 8)
    XCTAssertEqual(requests, 0, "Rendering and layout never change the selection")
  }

  func testClipboardTabsAreLargerThanFiltersButRemainContentSized() throws {
    for scale in [0.8, 1.2] {
      let options = [(value: false, title: "Share"), (value: true, title: "History")]
      let compact = NSHostingView(rootView: AniCeSegmentedControl(
        options: options, selection: .constant(false), fontScale: scale))
      let regular = NSHostingView(rootView: AniCeSegmentedControl(
        options: options, selection: .constant(false), fontScale: scale, size: .regular))
      for host in [compact, regular] {
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
      }
      XCTAssertGreaterThan(regular.bounds.height, compact.bounds.height)
      XCTAssertGreaterThan(regular.bounds.width, compact.bounds.width)
      XCTAssertLessThan(regular.bounds.width, 240, "Larger tabs must not become workspace-wide buttons")
      XCTAssertEqual(regular.bounds.height, 36, accuracy: 1)
    }
  }

  func testPreferenceSelectorsStayTrailingWithoutStretchingTheirHelperRows() async throws {
    for scale in [0.8, 1.2] {
      for width in [300.0, 600.0] {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
          let frames = LayoutFrames()
          let host = NSHostingView(rootView: PreferenceRowFixture(frames: frames, scale: scale)
            .padding(14).frame(width: width)
            .environment(\.layoutDirection, direction))
          host.frame.size = host.fittingSize
          try await settle(host)
          let control = try XCTUnwrap(frames.control)
          let row = try XCTUnwrap(frames.row)
          XCTAssertGreaterThan(control.width, 50)
          XCTAssertEqual(control.minY, row.minY, accuracy: 1, "The selector aligns with the label, not the helper")
          XCTAssertGreaterThan(row.height, control.height, "The helper contributes height only to the label column")
          XCTAssertLessThan(host.bounds.height, 200, "Narrow settings must reflow without runaway height")
          if direction == .leftToRight {
            XCTAssertEqual(control.maxX, row.maxX, accuracy: 1)
          } else {
            XCTAssertEqual(control.minX, row.minX, accuracy: 1)
          }
        }
      }
    }
  }

  private final class LayoutFrames {
    var control: CGRect?
    var row: CGRect?
  }

  private struct PreferenceRowFixture: View {
    let frames: LayoutFrames
    let scale: Double
    var body: some View {
      AniCePreferenceRow("Shelf edge",
        description: "Drag files to the selected edge and drop them on the shelf.", fontScale: scale) {
        Text("Right").padding(.horizontal, 12).frame(height: 32)
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.control = $0 }
      }
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.row = $0 }
    }
  }

  func testShelfEdgeAndGlobalShortcutRowsRenderAtBothSettingsWidths() throws {
    let name = "aniCe.SelectorAlignment.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = EdgeDropPreferences(storage: defaults)
    let transfer = MacTransferModel()
    let controller = MacEdgeDropController(model: transfer, preferences: preferences)
    defer { controller.shutdown(); transfer.dismiss() }
    for scheme in [ColorScheme.light, .dark] {
      for scale in [0.8, 1.2] {
        defaults.set(scale, forKey: "ui.fontScale")
        for width in [300.0, 600.0] {
          let content = VStack(alignment: .leading, spacing: 12) {
            EdgeDropSettingsView(controller: controller, settingsFontScale: scale)
            Divider()
            GlobalShortcutSettingsView()
            AniCeSegmentedControl(
              options: [(value: false, title: "Share"), (value: true, title: "History")],
              selection: .constant(false), fontScale: scale, size: .regular)
          }
          .padding(14).frame(width: width)
          .background(AniCePalette.surface(scheme)).environment(\.colorScheme, scheme)
          .defaultAppStorage(defaults)
          let host = NSHostingView(rootView: content)
          host.frame.size = host.fittingSize
          host.layoutSubtreeIfNeeded()
          XCTAssertEqual(host.bounds.width, width, accuracy: 1)
          XCTAssertLessThan(host.bounds.height, width == 300 ? 520 : 380,
            "Narrow recorder groups reflow below their labels; wide groups remain on one row")
          XCTAssertEqual(preferences.edge, .right, "Rendering must not change the selected edge")
          let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          host.cacheDisplay(in: host.bounds, to: bitmap)
          let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          if let path = ProcessInfo.processInfo.environment["ANICE_REVIEW_RENDER_DIR"] {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("selector-rows-\(scheme)-\(Int(width))-\(Int(scale * 100)).png"))
          }
        }
      }
    }
  }

  func testCapsulesRenderAcrossThemesWidthsTextSizesAndAccessibilityStates() throws {
    let name = "aniCe.PreferenceToggleTests.\(UUID())"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    var writes = 0, renders = 0
    for scheme in [ColorScheme.light, .dark] {
      for scale in [0.8, 1.2] {
        preferences.set(scale, forKey: "ui.fontScale")
        for width in [260.0, 600.0] {
          for checked in [false, true] {
            for enabled in [false, true] {
              for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                for contrast in [ColorSchemeContrast.standard, .increased] {
                  let content = Toggle("Use local network automatically", isOn: Binding(
                    get: { checked }, set: { _ in writes += 1 }))
                    .toggleStyle(AniCePreferenceToggleStyle(description: "Enable on both devices to use Wi-Fi."))
                    .disabled(!enabled).font(.system(size: 13 * scale)).padding(14).frame(width: width)
                    .background(AniCePalette.surface(scheme))
                    .environment(\.colorScheme, scheme)
                    .environment(\.layoutDirection, direction).defaultAppStorage(preferences)
                  let host = NSHostingView(rootView: content)
                  host.appearance = NSAppearance(named: contrast == .increased
                    ? (scheme == .dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                    : (scheme == .dark ? .darkAqua : .aqua))
                  host.frame.size = host.fittingSize
                  host.layoutSubtreeIfNeeded()
                  XCTAssertEqual(host.bounds.width, width, accuracy: 1)
                  XCTAssertLessThan(host.bounds.height, 140, "The fuller thumb must not inflate a preference row")
                  let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                  host.cacheDisplay(in: host.bounds, to: bitmap)
                  let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                  XCTAssertGreaterThan(data.count, 300)
                  if scale == 1.2, width == 260, enabled, direction == .leftToRight, contrast == .standard,
                    let path = ProcessInfo.processInfo.environment["ANICE_REVIEW_RENDER_DIR"] {
                    let directory = URL(fileURLWithPath: path, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: directory.appendingPathComponent("soft-switch-\(scheme)-\(checked).png"))
                  }
                  renders += 1
                }
              }
            }
          }
        }
      }
    }
    XCTAssertEqual(renders, 128)
    XCTAssertEqual(writes, 0)
  }

  @MainActor func testContextualGuideActionOpensCategorizedOfflineGuideWithoutInlineClutter() async throws {
    let name = "aniCe.GuideTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(1.2, forKey: "ui.fontScale")

    XCTAssertEqual(AppDestination.primary, [.home, .devices, .features, .favourites, .settings, .about])

    let navigation = ConnectionNavigation()
    navigation.openFeature(.files)
    navigation.openGuide(.filesAndEdgeDrop)
    XCTAssertEqual(navigation.destination, .guide)
    XCTAssertEqual(navigation.guideTopic, .filesAndEdgeDrop)
    navigation.goBack()
    XCTAssertEqual(navigation.destination, .features)
    XCTAssertEqual(navigation.featurePanel, .files)
    navigation.goForward()
    XCTAssertEqual(navigation.destination, .guide)
    XCTAssertEqual(navigation.guideTopic, .filesAndEdgeDrop)

    let transfer = MacTransferModel()
    let keyboard = MacKeyboardTrackpadModel(preferences: defaults)
    let clipboard = MacClipboardModel(native: ClipboardNativeFake(), preferences: ClipboardPreferences(storage: defaults))
    let findDevice = MacFindDeviceModel(notifier: MacFindDeviceNotifier())
    let smsPrefs = SmsPreferences(storage: nil)
    let sms = MacSmsModel(notifier: MacSmsNotifier(preferences: smsPrefs))
    let edgeDrop = MacEdgeDropController(model: transfer, preferences: EdgeDropPreferences(storage: defaults))
    defer {
      transfer.dismiss()
      clipboard.invalidate()
    }

    for (title, body) in [
      ("Open Link in Mac", "Launch any http or https link from Android straight into your Mac’s default browser."),
      ("Control Mac (from Android)", "Turn your Android screen and keyboard into a wireless touchpad and keyboard for Mac."),
    ] {
      let host = NSHostingView(rootView: AniCeHelpDisclosure(title: title, bodyText: body)
        .disclosureGroupStyle(ClickableDisclosureStyle())
        .padding(12).frame(width: 340)
        .defaultAppStorage(defaults))
      host.frame.size = host.fittingSize
      host.layoutSubtreeIfNeeded()
      XCTAssertLessThan(host.bounds.height, 75, "\(title) must stay collapsed by default")
    }

    for scheme in [ColorScheme.light, .dark] {
      let inlineCheck = VStack(alignment: .leading, spacing: 12) {
        TransferView(model: transfer, peers: [], compact: false, overview: false)
        MacKeyboardTrackpadView(model: keyboard, floatingPresentation: false)
      }
      .padding(16).frame(width: 480)
      .background(AniCePalette.surface(scheme))
      .environment(\.colorScheme, scheme)
      .defaultAppStorage(defaults)

      let inlineHost = NSHostingView(rootView: inlineCheck)
      inlineHost.frame.size = inlineHost.fittingSize
      let inlineText = try recognizedText(inlineHost)
      XCTAssertFalse(inlineText.contains("How transfers work"))
      XCTAssertFalse(inlineText.contains("How Control Android works"))

      for favouritesOnly in [false, true] {
        let featNav = ConnectionNavigation()
        featNav.select(favouritesOnly ? .favourites : .features)
        let featuresView = FeaturesView(
          playback: MacPlaybackModel(),
          transfer: transfer,
          clipboard: clipboard,
          findDevice: findDevice,
          sms: sms,
          keyboardTrackpad: keyboard,
          smsPreferences: smsPrefs,
          findNotifier: nil,
          peers: [],
          edgeDrop: edgeDrop,
          navigation: featNav,
          favouritesOnly: favouritesOnly
        )
        .frame(width: 720, height: 820)
        .background(AniCePalette.background(scheme))
        .environment(\.colorScheme, scheme)
        .defaultAppStorage(defaults)

        let featHost = NSHostingView(rootView: featuresView)
        featHost.frame.size = CGSize(width: 720, height: 820)
        let featText = try recognizedText(featHost)
        if favouritesOnly {
          XCTAssertFalse(featText.contains("More built into aniCe"))
        } else {
          XCTAssertTrue(featText.contains("More built into aniCe"))
          XCTAssertTrue(featText.contains("Open Guide"))
          if let path = ProcessInfo.processInfo.environment["ANICE_REVIEW_RENDER_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(featHost.bitmapImageRepForCachingDisplay(in: featHost.bounds))
            featHost.cacheDisplay(in: featHost.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("mac-features-\(scheme).png"))
          }
        }
      }

      let guideHost = NSHostingView(rootView: GuideView(initialTopic: nil)
        .disclosureGroupStyle(ClickableDisclosureStyle())
        .frame(width: 680, height: 780)
        .background(AniCePalette.background(scheme))
        .environment(\.colorScheme, scheme)
        .defaultAppStorage(defaults))
      guideHost.frame.size = CGSize(width: 680, height: 780)
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 780),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      window.contentView = guideHost
      window.orderFront(nil)
      defer { window.contentView = nil; window.close() }
      try await settle(guideHost)

      let initialText = try recognizedText(guideHost)
      XCTAssertTrue(initialText.contains("aniCe Guide"))
      XCTAssertTrue(initialText.contains("Open Link in Mac"))
      XCTAssertTrue(initialText.contains("Send files & Edge Drop"))
      XCTAssertFalse(initialText.contains("without overwriting your Mac clipboard"))

      let linkPoint = try XCTUnwrap(try textCenter(guideHost, matching: "Open Link in Mac"))
      try click(guideHost, in: window, at: linkPoint)
      try await settle(guideHost)
      let expandedText = try recognizedText(guideHost)
      XCTAssertTrue(expandedText.contains("launches it directly"))

      if let path = ProcessInfo.processInfo.environment["ANICE_REVIEW_RENDER_DIR"] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(guideHost.bitmapImageRepForCachingDisplay(in: guideHost.bounds))
        guideHost.cacheDisplay(in: guideHost.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("mac-guide-\(scheme).png"))
      }

      let controlPoint = try XCTUnwrap(try textCenter(guideHost, matching: "Control"))
      try click(guideHost, in: window, at: controlPoint)
      try await settle(guideHost)
      let controlText = try recognizedText(guideHost)
      XCTAssertTrue(controlText.contains("Floating Key"), "OCR output: \(controlText)")
      XCTAssertTrue(controlText.contains("Desk Deck") || controlText.contains("Monitor Mac vitals"), "OCR output: \(controlText)")

      let sharePoint = try XCTUnwrap(try textCenter(guideHost, matching: "Share & Files"))
      try click(guideHost, in: window, at: sharePoint)
      try await settle(guideHost)
      let filteredText = try recognizedText(guideHost)
      XCTAssertFalse(filteredText.contains("Pairing & Connections"))
      XCTAssertTrue(filteredText.contains("Open Link in Mac"))

      let allPoint = try XCTUnwrap(try textCenter(guideHost, matching: "All"))
      try click(guideHost, in: window, at: allPoint)
      try await settle(guideHost)
      let expandPoint = try XCTUnwrap(try textCenter(guideHost, matching: "Expand all"))
      try click(guideHost, in: window, at: expandPoint)
      try await settle(guideHost)
      XCTAssertTrue(try recognizedText(guideHost).contains("Collapse all"))
      let collapsePoint = try XCTUnwrap(try textCenter(guideHost, matching: "Collapse all"))
      try click(guideHost, in: window, at: collapsePoint)
      try await settle(guideHost)
      XCTAssertTrue(try recognizedText(guideHost).contains("Expand all"))

      let contextualHost = NSHostingView(rootView: GuideView(initialTopic: .openLinkInMac)
        .disclosureGroupStyle(ClickableDisclosureStyle())
        .frame(width: 680, height: 640)
        .background(AniCePalette.background(scheme))
        .environment(\.colorScheme, scheme)
        .defaultAppStorage(defaults))
      contextualHost.frame.size = CGSize(width: 680, height: 640)
      let contextualText = try recognizedText(contextualHost)
      XCTAssertTrue(contextualText.contains("launches it directly"))
    }
  }

  private func recognizedText(_ host: NSView) throws -> String {
    host.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let image = try XCTUnwrap(bitmap.cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
  }

  private func textCenter(_ host: NSView, matching query: String) throws -> NSPoint? {
    host.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let image = try XCTUnwrap(bitmap.cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    let ordered = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
    for observation in ordered {
      guard let recognized = observation.topCandidates(1).first,
            let range = recognized.string.range(of: query) else { continue }
      let box = (try? recognized.boundingBox(for: range)?.boundingBox) ?? observation.boundingBox
      let y = host.isFlipped ? (1.0 - box.midY) * host.bounds.height : box.midY * host.bounds.height
      return NSPoint(x: box.midX * host.bounds.width, y: y)
    }
    return nil
  }

  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(80))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
  }

  private func accessibilityElements(_ element: Any) -> [any NSAccessibilityProtocol] {
    guard let element = element as? any NSAccessibilityProtocol else { return [] }
    return [element] + (element.accessibilityChildren() ?? []).flatMap { accessibilityElements($0) }
  }
  private func accessibleLabel(_ element: any NSAccessibilityProtocol) -> String? {
    element.accessibilityLabel() ??
      (element.accessibilityTitleUIElement() as? any NSAccessibilityProtocol)?.accessibilityValue() as? String
  }

  private func click(_ host: NSView, in window: NSWindow, at point: NSPoint) throws {
    let location = host.convert(point, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      window.sendEvent(event)
    }
  }
}
