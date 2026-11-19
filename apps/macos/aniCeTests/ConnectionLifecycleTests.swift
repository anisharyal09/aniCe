// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies pairing contracts, durable trust and exclusive BLE ownership across native lifecycle faults.
import CryptoKit
import Foundation
import XCTest
import SwiftUI
import AppKit
import Network

@testable import aniCe

@MainActor private final class SessionRadioFake: SessionPeripheralAdapter {
  var pairingWrite: ((Data) -> Bool)?
  var pairingDisconnect: (() -> Void)?
  var sessionWrite: ((Data) -> Bool)?
  var sessionDisconnect: (() -> Void)?
  var sessionAdmitted: (() -> Bool)?
  var event: ((PeripheralEvent) -> Void)?
  var started = false
  var resumes = 0
  var stopped = 0
  var retirement = 0
  var advertisingEvent: PeripheralEvent = .advertising
  func begin(
    event: @escaping (PeripheralEvent) -> Void, read: @escaping (Bool, Int) -> DiscoveryRead
  ) {
    self.event = event
    started = true
    event(.available)
  }
  func publish() { event?(.published) }
  func advertise() { event?(advertisingEvent) }
  func stop() {
    stopped += 1
    event = nil
  }
  func sendPairing(_ message: Data) throws { throw PairingFailure.transport }
  func drainPairing() async {}
  func retirePairingConnection() { retirement += 1 }
  var hasCapacity = true
  func sessionCapacity(_ bytes: Int) -> Bool { hasCapacity }
  var sent: [Data] = []
  var failReadyAck = false
  func sendSession(_ message: Data) async throws {
    if failReadyAck, message.first == 6 { throw SessionFailure.authentication }
    sent.append(message)
  }
  func resumeSessionAdvertising() { resumes += 1 }
  func tickSessionTransport() throws {}
}
@MainActor private final class VisualSmsNotifier: SmsNotifying {
  func post(_ note: SmsNotification) async -> SmsPostOutcome { .submitted }
}
@MainActor private final class VisualFindNotifier: FindDeviceNotifying {
  var posts = 0
  func post(identifier: String, peerName: String) async -> FindResult { posts += 1; return .failed }
  func clear(identifier: String) {}
}
@MainActor private final class SessionRecoveryWait {
  var delays = [TimeInterval]()
  var continuation: CheckedContinuation<Void, Never>?
  func pause(_ delay: TimeInterval) async {
    delays.append(delay)
    await withCheckedContinuation { continuation = $0 }
  }
  func release() { continuation?.resume(); continuation = nil }
}
@MainActor final class SessionLifecycleTests: XCTestCase {
  func testActivationClearsAnOverdueTimedPauseWhileExclusiveWorkRemainsSuspended() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Test", tagPrefix: "pause.test.")
    let name = "aniCe.PauseTests.\(UUID())", preferences = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    preferences.set(true, forKey: "session.automatic")
    preferences.set(true, forKey: "session.paused")
    preferences.set(Date().addingTimeInterval(3600).timeIntervalSince1970, forKey: "session.pausedUntil")
    let radio = SessionRadioFake(), timer = SessionRecoveryWait()
    let model = MacSessionModel(identity: identity, adapter: radio, store: { trust },
      preferences: preferences, wait: { await timer.pause($0) })
    defer { model.setAutomatic(false); timer.release() }
    model.suspendAutomatic()
    model.restoreAutomatic()
    var resumed = 0
    model.automaticPauseEnded = { resumed += 1 }
    preferences.set(Date().addingTimeInterval(-3600).timeIntervalSince1970, forKey: "session.pausedUntil")
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    XCTAssertFalse(preferences.bool(forKey: "session.paused"))
    XCTAssertNil(preferences.object(forKey: "session.pausedUntil"))
    XCTAssertNil(model.connectionPauseStatus)
    XCTAssertEqual(resumed, 1)
    XCTAssertTrue(model.automatic)
    XCTAssertFalse(model.allowing, "Pause expiry must not steal the radio from exclusive work")
  }

  func testNetworkReturnClearsAnOverdueTimedPauseWithoutEnablingADisabledChoice() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Test", tagPrefix: "pause.test.")
    let name = "aniCe.PauseTests.\(UUID())", preferences = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    preferences.set(true, forKey: "session.automatic")
    preferences.set(true, forKey: "session.paused")
    preferences.set(Date().addingTimeInterval(3600).timeIntervalSince1970, forKey: "session.pausedUntil")
    let model = MacSessionModel(identity: identity, adapter: SessionRadioFake(), store: { trust }, preferences: preferences)
    defer { model.setAutomatic(false) }
    model.suspendAutomatic()
    model.restoreAutomatic()
    var resumed = 0
    model.automaticPauseEnded = { resumed += 1 }
    preferences.set(Date().addingTimeInterval(-60).timeIntervalSince1970, forKey: "session.pausedUntil")
    model.reconcileConnectionPause()
    XCTAssertFalse(preferences.bool(forKey: "session.paused"))
    XCTAssertNil(preferences.object(forKey: "session.pausedUntil"))
    XCTAssertEqual(resumed, 1)
    XCTAssertFalse(model.allowing, "Expiry must still respect suspended exclusive work")

    preferences.set(false, forKey: "session.automatic")
    preferences.set(true, forKey: "session.paused")
    preferences.set(Date().addingTimeInterval(-60).timeIntervalSince1970, forKey: "session.pausedUntil")
    let disabled = MacSessionModel(identity: identity, adapter: SessionRadioFake(), store: { trust }, preferences: preferences)
    disabled.restoreAutomatic()
    disabled.reconcileConnectionPause()
    XCTAssertTrue(preferences.bool(forKey: "session.paused"), "A disabled choice stays paused")
    XCTAssertNotNil(preferences.object(forKey: "session.pausedUntil"))
  }

  func testActivationPreservesAnIndefiniteAutomaticPause() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Test", tagPrefix: "pause.test.")
    let name = "aniCe.PauseTests.\(UUID())", preferences = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    preferences.set(true, forKey: "session.automatic")
    preferences.set(true, forKey: "session.paused")
    preferences.set(0.0, forKey: "session.pausedUntil")
    let model = MacSessionModel(identity: identity, adapter: SessionRadioFake(), store: { trust }, preferences: preferences)
    defer { model.setAutomatic(false) }
    model.suspendAutomatic()
    model.restoreAutomatic()
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    XCTAssertTrue(preferences.bool(forKey: "session.paused"))
    XCTAssertEqual(preferences.double(forKey: "session.pausedUntil"), 0)
    XCTAssertEqual(model.connectionPauseStatus, "Paused")
    XCTAssertFalse(model.allowing)
  }

  func testPauseTimerRechecksWallClockAfterRollback() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Test", tagPrefix: "pause.test.")
    let name = "aniCe.PauseTests.\(UUID())", preferences = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    var wall = Date(timeIntervalSince1970: 1_800_000_000)
    let deadline = wall.addingTimeInterval(300)
    preferences.set(true, forKey: "session.automatic")
    preferences.set(true, forKey: "session.paused")
    preferences.set(deadline.timeIntervalSince1970, forKey: "session.pausedUntil")
    let timer = SessionRecoveryWait()
    let model = MacSessionModel(identity: identity, adapter: SessionRadioFake(), store: { trust },
      preferences: preferences, wallNow: { wall }, wait: { await timer.pause($0) })
    defer { model.setAutomatic(false); timer.release() }
    model.suspendAutomatic()
    model.restoreAutomatic()
    try await waitFor { timer.delays.count == 1 }
    XCTAssertEqual(timer.delays, [300])
    wall = wall.addingTimeInterval(-3600)
    timer.release()
    try await waitFor { timer.delays.count == 2 }
    XCTAssertEqual(timer.delays, [300, 3900])
    XCTAssertTrue(preferences.bool(forKey: "session.paused"))
    XCTAssertEqual(preferences.double(forKey: "session.pausedUntil"), deadline.timeIntervalSince1970)
    XCTAssertFalse(model.allowing)
  }

  func testStartupBackoffRequiresUninterruptedAuthenticatedStability() {
    var recovery = SessionStartupRecovery()
    XCTAssertEqual((0..<8).map { _ in recovery.nextDelay() }, [2, 5, 15, 30, 60, 90, 90, 90])
    recovery.secured(100)
    recovery.tick(114.999)
    recovery.retired()
    recovery.tick(200)
    XCTAssertEqual(recovery.nextDelay(), 90, "A retired stability deadline cannot reset flapping recovery")
    recovery.secured(200)
    recovery.tick(215)
    XCTAssertEqual(recovery.nextDelay(), 2)
  }
  func testAutomaticStartupRecoveryAndNativeBlockRemainOwned() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Test", tagPrefix: "startup.test.")
    let local = try await identity.publicIdentity(), key = P256.Signing.PrivateKey()
    let peer = try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: [
      "identitySchemaVersion": 1, "algorithm": "ECDSA_P256_SHA256", "platform": "android",
      "deviceId": UUID().uuidString.lowercased(), "deviceName": "Phone",
      "publicKey": key.publicKey.x963Representation.base64EncodedString(),
      "fingerprint": DeviceIdentity.fingerprint(key.publicKey.x963Representation)]))
    let hash = Data(repeating: 7, count: 32)
    try trust.prepare(PeerTrustRecord(peer: peer, localFingerprint: local.fingerprint, method: .qr,
      pairedAt: Date(), transcriptHash: hash, active: false))
    try trust.activate(peerID: peer.deviceId, hash: hash, receipt: key.signature(for: PairingCodec.receipt(hash, 1)).derRepresentation)
    let radio = SessionRadioFake(), timer = SessionRecoveryWait(), peers = SessionPeerReservation()
    radio.advertisingEvent = .failure
    let model = MacSessionModel(identity: identity, adapter: radio, store: { trust }, peers: peers, wait: { await timer.pause($0) })
    defer { model.cancel(); timer.release() }
    model.selectedPeer = peer
    model.setAutomatic(true)
    try await waitFor { timer.delays.count == 1 }
    XCTAssertEqual(timer.delays, [2]); XCTAssertNotEqual(model.state, "Failed")
    let stale = radio.event
    timer.release()
    try await waitFor { timer.delays.count == 2 }
    XCTAssertEqual(timer.delays, [2, 5])
    radio.advertisingEvent = .advertising
    timer.release()
    try await waitFor { model.allowing }
    try await waitFor { model.maintenanceDeadline != nil }
    radio.event?(.off)
    XCTAssertEqual(model.status, "Waiting for Bluetooth.")
    XCTAssertNil(peers.peer)
    XCTAssertEqual(timer.delays, [2, 5]); XCTAssertNotNil(radio.event)
    radio.event?(.available)
    try await waitFor { model.maintenanceDeadline != nil }
    XCTAssertNotNil(peers.peer, "Radio recovery must reacquire the pinned reservation")
    model.disconnect()
    stale?(.failure)
    radio.event?(.available)
    XCTAssertFalse(model.allowing); XCTAssertFalse(model.automatic)
    XCTAssertEqual(timer.delays, [2, 5])
  }
  func testGattSubmissionCompletionRetirementAndStaleCallbacksAreIndependent() async throws {
    let waiters = GattSubmissionWaiters()
    let first = UUID(), second = UUID()
    let sent = Task { @MainActor in
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        waiters.insert(first, continuation)
      }
    }
    let retired = Task { @MainActor in
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        waiters.insert(second, continuation)
      }
    }
    for _ in 0..<100 {
      if waiters.contains(first), waiters.contains(second) { break }
      await Task.yield()
    }
    XCTAssertTrue(waiters.contains(first)); XCTAssertTrue(waiters.contains(second))
    waiters.complete(UUID())
    XCTAssertTrue(waiters.contains(first)); XCTAssertTrue(waiters.contains(second))
    waiters.complete(first); waiters.complete(first)
    try await sent.value
    XCTAssertFalse(waiters.contains(first)); XCTAssertTrue(waiters.contains(second))
    waiters.retire(); waiters.complete(second)
    do { try await retired.value; XCTFail("Retired encrypted submission reported success") }
    catch let error as SessionFailure { XCTAssertEqual(error, .cancelled) }
    XCTAssertFalse(waiters.contains(second))
  }
  func testCompanionFitsInlineDeviceStatusAndIncomingOffersWithoutStartingWork() async throws {
    XCTAssertTrue(IdentityView.isTesting)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let service = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Fixture Mac", tagPrefix: "visual.test.")
    let radio = SessionRadioFake(), discovery = MacDiscoveryModel(adapter: radio)
    let pairing = MacPairingModel(identity: service, discovery: discovery, makeStore: { trust })
    let reservation = SessionPeerReservation()
    let session = MacSessionModel(identity: service, adapter: radio, store: { trust }, peers: reservation)
    let lan = MacLanSessionModel(identity: service, peers: reservation, store: { trust })
    let preferences = try XCTUnwrap(UserDefaults(suiteName: "anice.companion.visual." + UUID().uuidString))
    preferences.set(true, forKey: "media.showOnMac")
    var commands = 0
    let playback = MacPlaybackModel(preferences: preferences, requestSink: { _ in commands += 1; return true })
    let quietPreferences = try XCTUnwrap(UserDefaults(suiteName: "anice.companion.quiet." + UUID().uuidString))
    let quietPlayback = MacPlaybackModel(preferences: quietPreferences, requestSink: { _ in commands += 1; return true })
    let keyboardTrackpad = MacKeyboardTrackpadModel(transport: FakeKeyboardTrackpadTransport(), preferences: preferences)
    let floatingKeyboard = FloatingKeyboardController(model: keyboardTrackpad, preferences: preferences)
    defer { floatingKeyboard.shutdown(); keyboardTrackpad.shutdown() }
    let pid = ProcessInfo.processInfo.processIdentifier
    playback.read(try JSONSerialization.data(withJSONObject: [
      "pid": pid, "playbackRevision": UUID().uuidString, "sourceIsAutomatic": true,
      "sources": [["pid": pid, "bundleIdentifier": Bundle.main.bundleIdentifier!, "displayName": "Fixture player",
        "isMusicApp": false, "isPlaying": true, "hasTrack": true]],
      "kMRMediaRemoteNowPlayingInfoTitle": "A Walk Home", "kMRMediaRemoteNowPlayingInfoArtist": "The Evening Hours",
      "kMRMediaRemoteNowPlayingInfoDuration": 236, "kMRMediaRemoteNowPlayingInfoElapsedTime": 92,
      "isPlaying": true, "canSendCommandsDirectly": true, "canToggle": true, "canSeek": true]))
    XCTAssertTrue(playback.compactVisible)
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ANICE_REVIEW_RENDER_DIR"]
      ?? "/private/tmp/aniCe-reference-renders", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var renders = 0
    for (index, name) in ["Pixel 9", "Alexandra’s Android phone for work and travel"].enumerated() {
      let key = P256.Signing.PrivateKey()
      let peer = try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: [
        "identitySchemaVersion": 1, "algorithm": "ECDSA_P256_SHA256", "platform": "android",
        "deviceId": UUID().uuidString.lowercased(), "deviceName": name,
        "publicKey": key.publicKey.x963Representation.base64EncodedString(),
        "fingerprint": DeviceIdentity.fingerprint(key.publicKey.x963Representation)]))
      pairing.peers = [PeerTrustRecord(peer: peer, localFingerprint: "fixture", method: .qr,
        pairedAt: Date(), transcriptHash: Data(repeating: 0, count: 32), active: true)]
      session.selectedPeer = peer
      session.state = "Secured"
      let transfer = MacTransferModel(), channel = MockSecuredChannel(peer: peer)
      transfer.available(channel)
      _ = await transfer.handle(try TransferMessage.capability().encode(), on: channel.descriptor)
      for incoming in [false, true] {
        if incoming {
          let offer = TransferMessage.offer(batch: UUID().uuidString.lowercased(), sliceIndex: 0,
            totalSlices: 1, totalFiles: 1, totalBytes: 0,
            files: [.array([.text(UUID().uuidString.lowercased()), .text("Trip notes.pdf"), .integer(0), .bytes(Data(SHA256.hash(data: Data())))])])
          _ = await transfer.handle(try offer.encode(), on: channel.descriptor)
          XCTAssertNotNil(transfer.pendingOffer)
        }
        for scheme: ColorScheme in [.light, .dark] {
          for showPlayback in [true, false] where showPlayback || (index == 0 && !incoming) {
          let view = CompanionView(identity: IdentityViewModel(service: service), discovery: discovery,
            pairing: pairing, session: session, lan: lan, privateListening: MacPrivateListeningModel(preferences: nil), connectionPause: MacConnectionPauseModel(), playback: showPlayback ? playback : quietPlayback, transfer: transfer, clipboard: MacClipboardModel(native: ClipboardNativeFake()),
            keyboardTrackpad: keyboardTrackpad, floatingKeyboard: floatingKeyboard, phonePower: MacPhonePowerModel(), navigation: ConnectionNavigation(),
            openMainWindow: { XCTFail("Rendering opened the main window") })
            .environment(\.colorScheme, scheme)
          let host = NSHostingView(rootView: view)
          let size = host.fittingSize
          XCTAssertEqual(size.width, 350, accuracy: 1)
          XCTAssertGreaterThan(size.height, showPlayback ? 250 : 150)
          XCTAssertLessThanOrEqual(size.height, 680)
          host.frame = NSRect(origin: .zero, size: size)
          host.layoutSubtreeIfNeeded()
          let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          host.cacheDisplay(in: host.bounds, to: bitmap)
          let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          XCTAssertGreaterThan(bytes.count, 1000)
          try bytes.write(to: folder.appendingPathComponent("companion-\(index)-\(incoming ? "offer" : "idle")\(showPlayback ? "" : "-no-media")-\(scheme == .light ? "light" : "dark").png"))
          renders += 1
          }
        }
      }
      transfer.retired(channel.descriptor)
    }
    XCTAssertEqual(renders, 10)
    XCTAssertFalse(radio.started)
    XCTAssertTrue(radio.sent.isEmpty)
    XCTAssertFalse(lan.allowing)
    XCTAssertEqual(commands, 0)
    XCTAssertTrue(trust.list(localFingerprint: "fixture").isEmpty)
  }

  func testWindowSectionsRenderAtNarrowAndWideSizesWithoutStartingWork() async throws {
    XCTAssertTrue(IdentityView.isTesting)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let service = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Fixture Mac", tagPrefix: "window.visual.")
    let radio = SessionRadioFake(), discovery = MacDiscoveryModel(adapter: radio)
    let pairing = MacPairingModel(identity: service, discovery: discovery, makeStore: { trust })
    let reservation = SessionPeerReservation()
    let preferences = try XCTUnwrap(UserDefaults(suiteName: "anice.window.visual." + UUID().uuidString))
    preferences.set(true, forKey: "media.showOnMac")
    let session = MacSessionModel(identity: service, adapter: radio, store: { trust }, preferences: preferences, peers: reservation)
    let lan = MacLanSessionModel(identity: service, peers: reservation, store: { trust })
    var commands = 0
    let playback = MacPlaybackModel(preferences: preferences, requestSink: { _ in commands += 1; return true })
    let pid = ProcessInfo.processInfo.processIdentifier
    playback.read(try JSONSerialization.data(withJSONObject: [
      "pid": pid, "playbackRevision": UUID().uuidString, "sourceIsAutomatic": true,
      "sources": [["pid": pid, "bundleIdentifier": Bundle.main.bundleIdentifier!, "displayName": "Fixture player",
        "isMusicApp": false, "isPlaying": true, "hasTrack": true]],
      "kMRMediaRemoteNowPlayingInfoTitle": "A Walk Home", "kMRMediaRemoteNowPlayingInfoArtist": "The Evening Hours",
      "kMRMediaRemoteNowPlayingInfoDuration": 236, "kMRMediaRemoteNowPlayingInfoElapsedTime": 92,
      "isPlaying": true, "canSendCommandsDirectly": true, "canToggle": true, "canSeek": true]))
    let transfer = MacTransferModel(), notifier = VisualFindNotifier()
    let find = MacFindDeviceModel(notifier: notifier)
    let key = P256.Signing.PrivateKey()
    let peer = try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: [
      "identitySchemaVersion": 1, "algorithm": "ECDSA_P256_SHA256", "platform": "android",
      "deviceId": UUID().uuidString.lowercased(), "deviceName": "Alexandra’s Android phone for work and travel",
      "publicKey": key.publicKey.x963Representation.base64EncodedString(),
      "fingerprint": DeviceIdentity.fingerprint(key.publicKey.x963Representation)]))
    pairing.peers = [PeerTrustRecord(peer: peer, localFingerprint: "fixture", method: .qr,
      pairedAt: Date(), transcriptHash: Data(repeating: 0, count: 32), active: true)]
    session.selectedPeer = peer
    session.state = "Secured"
    let channel = MockSecuredChannel(peer: peer)
    transfer.available(channel)
    _ = await transfer.handle(try TransferMessage.capability().encode(), on: channel.descriptor)

    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ANICE_REVIEW_RENDER_DIR"]
      ?? "/private/tmp/aniCe-reference-renders", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var renders = 0
    let trustedRecords = pairing.peers
    let keyboardTransport = FakeKeyboardTrackpadTransport()
    let linkedBluetooth = PairedBluetoothDevice(address: "01:23:45:67:89:AB", name: peer.deviceName)
    keyboardTransport.devices = [linkedBluetooth]
    let keyboardTrackpad = MacKeyboardTrackpadModel(transport: keyboardTransport, preferences: preferences)
    keyboardTrackpad.updateTargets([peer], connectedPeerIDs: [peer.deviceId], peerContextID: nil)
    keyboardTrackpad.refreshPairedDevices()
    XCTAssertTrue(keyboardTrackpad.link(linkedBluetooth))
    defer { keyboardTrackpad.shutdown() }
    let widths = [620.0, 720.0, MainWindowSizing.defaultSize.width, 1240.0]
    for appearance in ["Light", "Dark"] {
      preferences.set(appearance, forKey: "window.appearance")
      preferences.set("playback,files", forKey: "ui.favouriteFeatures")
      for width in widths {
        let height = width == MainWindowSizing.defaultSize.width ? MainWindowSizing.defaultSize.height : 800
        let routes: [(AppDestination, AppFeature?, String?)] =
          AppDestination.primary.map { ($0, nil, nil) } + AppFeature.allCases.map { (.features, $0, nil) } + [
            (.home, nil, "first-run"), (.devices, nil, "pairing"), (.devices, nil, "pairing-code"),
            (.devices, nil, "pairing-approval"), (.settings, nil, "pending-pairing"),
            (.settings, nil, "settings-80"), (.settings, nil, "settings-120"),
            (.about, nil, "about-80"), (.about, nil, "about-120")]
        for (destination, feature, scenario) in routes {
          preferences.set(scenario?.hasSuffix("-80") == true ? 0.8
            : scenario?.hasSuffix("-120") == true ? 1.2 : 1.0, forKey: "ui.fontScale")
          pairing.peers = scenario == "first-run" ? [] : trustedRecords
          if feature == .keyboardTrackpad {
            keyboardTrackpad.updateTargets([peer], connectedPeerIDs: [peer.deviceId], peerContextID: nil)
            keyboardTrackpad.selectTarget(peer)
            keyboardTrackpad.refreshPairedDevices()
            XCTAssertTrue(keyboardTrackpad.link(linkedBluetooth))
          }
          pairing.active = ["pairing-code", "pairing-approval", "pending-pairing"].contains(scenario ?? "")
          pairing.phase = scenario == "pairing-code" ? "invitation" : pairing.active ? "approval" : "idle"
          pairing.status = pairing.active ? "Approve this pairing on both devices." : "Choose how to pair your Android device."
          pairing.pin = scenario == "pairing-code" ? "123456" : nil
          pairing.peer = pairing.phase == "approval" ? peer : nil
          let navigation = ConnectionNavigation()
          navigation.show(destination, route: scenario?.hasPrefix("pairing") == true ? .pairing : .overview)
          if let feature { navigation.openFeature(feature) }
          let view = MainWindowView(delegate: AppDelegate(), identity: IdentityViewModel(service: service),
            discovery: discovery, pairing: pairing, session: session, lan: lan, privateListening: MacPrivateListeningModel(preferences: nil), connectionPause: MacConnectionPauseModel(), playback: playback,
            transfer: transfer, edgeDrop: MacEdgeDropController(model: transfer),
            clipboard: MacClipboardModel(native: ClipboardNativeFake()), findDevice: find, findNotifier: nil,
            sms: MacSmsModel(notifier: VisualSmsNotifier()), keyboardTrackpad: keyboardTrackpad,
            phoneInput: MacPhoneInputModel(), smsPreferences: SmsPreferences(storage: nil),
            onInitialRender: {}, dndSync: MacDndSyncModel(defaults: preferences), deskDeck: MacDeskDeckModel(), phonePower: MacPhonePowerModel(), navigation: navigation)
            .defaultAppStorage(preferences)
            .environment(\.colorScheme, appearance == "Light" ? .light : .dark)
            .frame(width: width, height: height)
          let host = NSHostingView(rootView: view)
          let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
          window.appearance = NSAppearance(named: appearance == "Light" ? .aqua : .darkAqua)
          window.contentView = host
          host.frame = NSRect(x: 0, y: 0, width: width, height: height)
          try await Task.sleep(for: .milliseconds(50))
          host.layoutSubtreeIfNeeded()
          XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
          let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          host.cacheDisplay(in: host.bounds, to: bitmap)
          let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          XCTAssertGreaterThan(bytes.count, 1000)
          try bytes.write(to: folder.appendingPathComponent("window-\(scenario ?? feature?.rawValue ?? destination.rawValue.lowercased())-\(Int(width))-\(appearance.lowercased()).png"))
          renders += 1
          XCTAssertFalse(navigation.details, "Changing sections must not open a modal")
        }
      }
    }
    XCTAssertEqual(renders, 2 * widths.count * (AppDestination.primary.count + AppFeature.allCases.count + 9))
    XCTAssertFalse(radio.started)
    XCTAssertTrue(radio.sent.isEmpty)
    XCTAssertFalse(lan.allowing)
    XCTAssertEqual(commands, 0)
    XCTAssertEqual(notifier.posts, 0)
    XCTAssertTrue(trust.list(localFingerprint: "fixture").isEmpty)
  }

  func testLatePairingCleanupRespectsDiscoveryPairingAndStop() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("trust.json")
    let trust = try PeerTrustStore(url: url), memory = PairingMemoryIdentity()
    let service = IdentityService(storage: memory, deviceName: "Mac test", tagPrefix: "radio.test.")
    _ = try await service.publicIdentity()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let savedIdentity = try encoder.encode(memory.record), savedTrust = try Data(contentsOf: url)
    let radio = SessionRadioFake(), discovery = MacDiscoveryModel(adapter: radio)
    let pairing = MacPairingModel(identity: service, discovery: discovery, makeStore: { trust })
    let session = MacSessionModel(identity: service, adapter: radio, store: { trust })
    AniCeApp.configureSessionLifecycle(session: session, pairing: pairing, discovery: discovery)
    defer {
      session.quit(); pairing.cancel(); discovery.stop()
      session.beforeAllow = {}; pairing.beforePairing = {}; pairing.trustRemoved = {}; discovery.beforeStart = {}
    }
    session.setAutomatic(true)
    pairing.start(.qr)
    let lateCleanup = pairing.afterPairing
    lateCleanup()
    XCTAssertTrue(pairing.active); XCTAssertFalse(session.allowing)
    pairing.cancel()
    discovery.start()
    XCTAssertTrue(discovery.session.active)
    let stopped = radio.stopped
    lateCleanup() // Deliver the old completion after discovery has acquired the shared radio.
    XCTAssertTrue(discovery.session.active); XCTAssertFalse(session.allowing)
    XCTAssertEqual(radio.stopped, stopped)
    discovery.stop()
    lateCleanup() // Positive control: idle radio still restores enabled automatic availability.
    XCTAssertTrue(session.allowing)
    session.disconnect()
    lateCleanup()
    XCTAssertFalse(session.allowing); XCTAssertFalse(session.automatic)
    XCTAssertEqual(try Data(contentsOf: url), savedTrust)
    XCTAssertEqual(try encoder.encode(memory.record), savedIdentity)
  }

  func testProductionModelReadinessAndAuthenticatedPeerFeedback() async throws {
    try await exerciseProductionModel(failReadyAck: false)
  }
  func testProductionModelReadinessFailurePreservesIdentityAndTrust() async throws {
    try await exerciseProductionModel(failReadyAck: true)
  }
  func testProductionModelRetiresFatalApplicationSendButNotBackpressure() async throws {
    try await exerciseProductionModel(failReadyAck: false, failApplicationSend: true)
  }
  private func exerciseProductionModel(failReadyAck: Bool, failApplicationSend: Bool = false) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("trust.json")
    let trust = try PeerTrustStore(url: url)
    let memory = PairingMemoryIdentity()
    let service = IdentityService(
      storage: memory, deviceName: "Mac test", tagPrefix: "session.test.")
    let mac = try await service.publicIdentity()
    let key = P256.Signing.PrivateKey()
    let android = try DeviceIdentity.decode(
      JSONSerialization.data(withJSONObject: [
        "identitySchemaVersion": 1, "algorithm": "ECDSA_P256_SHA256", "platform": "android",
        "deviceId": UUID().uuidString.lowercased(), "deviceName": "Phone test",
        "publicKey": key.publicKey.x963Representation.base64EncodedString(),
        "fingerprint": DeviceIdentity.fingerprint(key.publicKey.x963Representation),
      ]))
    let hash = Data(repeating: 7, count: 32)
    try trust.prepare(
      PeerTrustRecord(
        peer: android, localFingerprint: mac.fingerprint,
        method: .qr, pairedAt: Date(), transcriptHash: hash, active: false))
    try trust.activate(
      peerID: android.deviceId, hash: hash,
      receipt: key.signature(for: PairingCodec.receipt(hash, 1)).derRepresentation)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let savedIdentity = try encoder.encode(memory.record)
    let savedTrust = try Data(contentsOf: url)
    let radio = SessionRadioFake()
    radio.failReadyAck = failReadyAck
    let model = MacSessionModel(identity: service, adapter: radio, store: { trust })
    defer { model.cancel() }
    model.allow()
    try await waitFor { radio.started }
    try await waitFor { model.maintenanceDeadline != nil }
    XCTAssertGreaterThan(try XCTUnwrap(model.maintenanceDeadline) - ProcessInfo.processInfo.systemUptime, 100)
    XCTAssertTrue(radio.sessionAdmitted?() ?? false)
    XCTAssertFalse(radio.sessionAdmitted?() ?? true)
    let client = try SessionHandshakeEngine(
      local: android, responder: false,
      trusted: { [mac] }, currentIdentity: { android },
      signer: {
        SignedIdentityPayload(
          identity: android, signature: try key.signature(for: $0).derRepresentation)
      }, selectedPeer: mac)
    let message1 = try await client.initiate()
    XCTAssertTrue(radio.sessionWrite?(try SessionEnvelope.encode(1, message1)) ?? false)
    try await waitFor { !radio.sent.isEmpty }
    let message2 = try SessionEnvelope.decode(radio.sent.removeFirst())
    XCTAssertEqual(message2.0, 2)
    let message3 = try await client.authenticateResponder(message2.1)
    XCTAssertTrue(radio.sessionWrite?(try SessionEnvelope.encode(3, message3)) ?? false)
    try await waitFor { !radio.sent.isEmpty }
    let message4 = try SessionEnvelope.decode(radio.sent.removeFirst())
    XCTAssertEqual(message4.0, 4)
    try await client.confirmResponder(message4.1)
    XCTAssertEqual(model.state, "Connecting")
    XCTAssertEqual(model.receivedChecks, 0)
    let records = PairingBus()
    let channel = try await SecureSession.fromHandshake(
      client, responder: false,
      capacity: { _ in true }, submit: { await records.send($0) })
    try await channel.send(.ready)
    let readyRecords = await records.take()
    let ready = try XCTUnwrap(readyRecords.first)
    XCTAssertTrue(radio.sessionWrite?(try SessionEnvelope.encode(6, ready)) ?? false)
    if failReadyAck {
      try await waitFor { model.state == "Failed" }
      try await waitFor { model.maintenanceDeadline != nil }
      XCTAssertGreaterThan(try XCTUnwrap(model.maintenanceDeadline) - ProcessInfo.processInfo.systemUptime, 100)
      XCTAssertTrue(radio.sent.isEmpty)
      XCTAssertEqual(model.receivedChecks, 0)
      let stage = await channel.stage
      XCTAssertEqual(stage, .readySent)
    } else {
      try await waitFor { model.state == "Secured" }
      try await waitFor { model.maintenanceDeadline != nil }
      let wait = try XCTUnwrap(model.maintenanceDeadline) - ProcessInfo.processInfo.systemUptime
      XCTAssertGreaterThan(wait, 8) // Legacy control compatibility remains bounded at ten seconds.
      XCTAssertLessThanOrEqual(wait, 10.1)
      XCTAssertTrue(model.status.contains(android.deviceName))
      let ack = try SessionEnvelope.decode(try XCTUnwrap(radio.sent.first))
      XCTAssertEqual(ack.0, 6)
      _ = try await channel.receive(ack.1)
      model.applicationDataReceived = { _ in true }
      try await channel.send(.data, plaintext: Data("aniCe connection check".utf8))
      let dataRecords = await records.take()
      let data = try XCTUnwrap(dataRecords.first)
      XCTAssertTrue(radio.sessionWrite?(try SessionEnvelope.encode(6, data)) ?? false)
      try await waitFor { model.receivedChecks == 1 }
      try await waitFor { radio.sent.count == 2 }
      let reply = try SessionEnvelope.decode(radio.sent[1])
      let replyBody = try await channel.receive(reply.1)
      XCTAssertEqual(replyBody.0, .data)
      XCTAssertEqual(replyBody.1, SessionConnectionCheck.reply)
      model.checkConnection()
      try await waitFor { radio.sent.count == 3 }
      let response = try SessionEnvelope.decode(radio.sent[2])
      let received = try await channel.receive(response.1)
      XCTAssertEqual(received.0, .data)
      XCTAssertEqual(received.1, SessionConnectionCheck.request)
      try await channel.send(.data, plaintext: SessionConnectionCheck.reply)
      let confirmationRecords = await records.take()
      let confirmation = try XCTUnwrap(confirmationRecords.first)
      XCTAssertTrue(radio.sessionWrite?(try SessionEnvelope.encode(6, confirmation)) ?? false)
      try await waitFor { model.status == "Bluetooth check confirmed." }
      radio.hasCapacity = false
      do { try await model.sendData(Data([1])); XCTFail("Backpressure admitted a record") }
      catch is SessionBackpressure {}
      XCTAssertEqual(model.state, "Secured")
      radio.hasCapacity = true
      if failApplicationSend {
        radio.failReadyAck = true
        do { try await model.sendData(Data([1])); XCTFail("Failed encrypted submission reported success") }
        catch let error as SessionFailure { XCTAssertEqual(error, .authentication) }
        XCTAssertNotEqual(model.state, "Secured")
        XCTAssertNil(model.channelToken); XCTAssertNil(model.authenticatedPeer)
        radio.failReadyAck = false
      }
      model.cancel()
      XCTAssertNil(model.maintenanceDeadline)
      radio.started = false
      model.allow()
      try await waitFor { radio.started }
      try await waitFor { model.maintenanceDeadline != nil }
      XCTAssertGreaterThan(try XCTUnwrap(model.maintenanceDeadline) - ProcessInfo.processInfo.systemUptime, 100)
      XCTAssertEqual(model.state, "Disconnected")
    }
    XCTAssertEqual(try encoder.encode(memory.record), savedIdentity)
    XCTAssertEqual(try Data(contentsOf: url), savedTrust)
    await channel.close()
    await client.close()
  }
  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<2000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Production model transition did not complete")
    throw SessionFailure.expired
  }
  func testAutomaticAdmissionCooldownPauseSleepAndTrustBinding() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("trust.json")
    let trust = try PeerTrustStore(url: url)
    let memory = PairingMemoryIdentity()
    let service = IdentityService(storage: memory, deviceName: "Mac test", tagPrefix: "auto.test.")
    let mac = try await service.publicIdentity(), key = P256.Signing.PrivateKey()
    let android = try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: [
      "identitySchemaVersion": 1, "algorithm": "ECDSA_P256_SHA256", "platform": "android",
      "deviceId": UUID().uuidString.lowercased(), "deviceName": "Phone test",
      "publicKey": key.publicKey.x963Representation.base64EncodedString(),
      "fingerprint": DeviceIdentity.fingerprint(key.publicKey.x963Representation),
    ]))
    let hash = Data(repeating: 9, count: 32)
    try trust.prepare(PeerTrustRecord(peer: android, localFingerprint: mac.fingerprint,
      method: .qr, pairedAt: Date(), transcriptHash: hash, active: false))
    try trust.activate(peerID: android.deviceId, hash: hash,
      receipt: key.signature(for: PairingCodec.receipt(hash, 1)).derRepresentation)
    let savedTrust = try Data(contentsOf: url)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let savedIdentity = try encoder.encode(memory.record)
    let suite = "anice.auto.test.\(UUID().uuidString)"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let radio = SessionRadioFake(), cooldown = SessionRecoveryWait()
    var clock: TimeInterval = 0
    let model = MacSessionModel(identity: service, adapter: radio, store: { trust }, now: { clock },
      preferences: preferences, wait: { await cooldown.pause($0) })
    defer { model.cancel(); cooldown.release() }
    XCTAssertFalse(model.automatic)
    model.selectedPeer = android
    model.setAutomatic(true)
    try await waitFor { radio.started }
    let stale = radio.sessionAdmitted
    clock = 120; radio.started = false; model.tick()
    try await waitFor { radio.started }
    XCTAssertFalse(stale?() ?? true)
    XCTAssertTrue(model.automatic)
    for index in 1...5 {
      XCTAssertTrue(radio.sessionAdmitted?() ?? false)
      XCTAssertFalse(radio.sessionAdmitted?() ?? true)
      XCTAssertTrue(radio.sessionWrite?(Data([0])) ?? false)
      if index < 5 { try await waitFor { radio.resumes == index } }
      else { try await waitFor { !cooldown.delays.isEmpty } }
    }
    XCTAssertEqual(cooldown.delays, [120])
    model.allow() // A pending admission cooldown cannot be bypassed by a manual command.
    XCTAssertFalse(model.allowing)
    XCTAssertNil(radio.sessionAdmitted)
    // Stop wins even if the timer continuation is already queued for delivery.
    model.disconnect(); radio.started = false; cooldown.release()
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(radio.started); XCTAssertFalse(model.automatic)
    XCTAssertTrue(preferences.bool(forKey: "session.paused"))
    model.restoreAutomatic(); XCTAssertFalse(model.automatic)
    model.setAutomatic(true); try await waitFor { radio.started }
    let beforeSleep = radio.sessionAdmitted
    model.sleep(); XCTAssertFalse(model.allowing)
    XCTAssertFalse(beforeSleep?() ?? true)
    radio.started = false; model.wake(); try await waitFor { radio.started }
    model.suspendAutomatic(); XCTAssertFalse(model.allowing)
    radio.started = false; model.resumeAutomatic(); try await waitFor { radio.started }
    model.setAutomatic(false); radio.started = false
    model.resumeAutomatic(); XCTAssertFalse(radio.started)
    // Restored policy must not bind a remembered peer to a different local identity.
    preferences.set(true, forKey: "session.automatic")
    preferences.set(false, forKey: "session.paused")
    preferences.set("changed", forKey: "session.local")
    model.restoreAutomatic()
    try await waitFor { model.state == "Failed" }
    XCTAssertFalse(radio.started); XCTAssertFalse(model.automatic)
    XCTAssertEqual(try Data(contentsOf: url), savedTrust)
    XCTAssertEqual(try encoder.encode(memory.record), savedIdentity)
    model.quit(); model.wake(); XCTAssertFalse(model.allowing)
  }
  func testServiceRevocationClosesPendingBleOwnerAndIgnoresOtherJournals() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    let identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Mac test", tagPrefix: "revocation.test.")
    let mac = try await identity.publicIdentity(), key = P256.Signing.PrivateKey()
    let phone = try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: [
      "identitySchemaVersion": 1, "algorithm": "ECDSA_P256_SHA256", "platform": "android",
      "deviceId": UUID().uuidString.lowercased(), "deviceName": "Phone test",
      "publicKey": key.publicKey.x963Representation.base64EncodedString(),
      "fingerprint": DeviceIdentity.fingerprint(key.publicKey.x963Representation),
    ]))
    let hash = Data(repeating: 9, count: 32)
    try trust.prepare(PeerTrustRecord(peer: phone, localFingerprint: mac.fingerprint,
      method: .qr, pairedAt: Date(), transcriptHash: hash, active: false))
    try trust.activate(peerID: phone.deviceId, hash: hash,
      receipt: key.signature(for: PairingCodec.receipt(hash, 1)).derRepresentation)
    let radio = SessionRadioFake(), peers = SessionPeerReservation()
    let ble = MacSessionModel(identity: identity, adapter: radio, store: { trust }, peers: peers)
    ble.selectedPeer = phone
    ble.allow()
    try await waitFor { radio.started }
    XCTAssertTrue(ble.allowing)
    XCTAssertEqual(peers.peer, phone)
    let stale = try XCTUnwrap(radio.sessionAdmitted)
    let unrelated = try PeerTrustStore(url: directory.appendingPathComponent("other.json"))
    try unrelated.remove(phone.deviceId)
    XCTAssertTrue(ble.allowing)
    // A distinct instance of the owning journal still invalidates admission before its durable write.
    let sameJournal = try PeerTrustStore(url: trust.location)
    try sameJournal.remove(phone.deviceId)
    XCTAssertTrue(sameJournal.list(localFingerprint: mac.fingerprint).isEmpty)
    XCTAssertFalse(ble.allowing)
    XCTAssertFalse(stale())
    XCTAssertNil(peers.peer)
  }

  func testExpiryCancellationStaleCallbacksAndDurableState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("trust.json")
    let trust = try PeerTrustStore(url: url)
    let memory = PairingMemoryIdentity()
    let identity = IdentityService(
      storage: memory, deviceName: "Mac test", tagPrefix: "session.test.")
    _ = try await identity.publicIdentity()
    let identityEncoder = JSONEncoder()
    identityEncoder.outputFormatting = [.sortedKeys]
    let savedIdentity = try identityEncoder.encode(memory.record)
    let savedTrust = try Data(contentsOf: url)
    let radio = SessionRadioFake()
    var clock: TimeInterval = 0
    let model = MacSessionModel(
      identity: identity, adapter: radio, store: { trust }, now: { clock })
    model.allow()
    for _ in 0..<200 {
      if radio.started { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertTrue(radio.started)
    XCTAssertTrue(model.allowing)
    let staleAdmission = radio.sessionAdmitted
    let staleEvent = radio.event
    clock = 120
    model.tick()
    XCTAssertFalse(model.allowing)
    XCTAssertEqual(model.state, "Disconnected")
    XCTAssertFalse(staleAdmission?() ?? true)
    staleEvent?(.advertising)
    XCTAssertFalse(model.allowing)
    XCTAssertEqual(try Data(contentsOf: url), savedTrust)
    XCTAssertEqual(try identityEncoder.encode(memory.record), savedIdentity)
    clock = 200
    radio.started = false
    model.allow()
    for _ in 0..<200 {
      if radio.started { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertTrue(radio.sessionAdmitted?() ?? false)
    XCTAssertFalse(radio.sessionAdmitted?() ?? true)
    clock = 230
    model.tick()
    XCTAssertEqual(model.state, "Failed")
    XCTAssertTrue(model.allowing)
    try await waitFor { radio.resumes == 1 }
    XCTAssertGreaterThan(radio.retirement, 0)
    model.cancel()
    XCTAssertNil(radio.sessionWrite)
    XCTAssertNil(radio.sessionAdmitted)
    XCTAssertEqual(try Data(contentsOf: url), savedTrust)
    XCTAssertEqual(try identityEncoder.encode(memory.record), savedIdentity)
  }
}

@MainActor private final class PauseSessionFixture {
  let directory: URL
  let domain: String
  let preferences: UserDefaults
  let trust: PeerTrustStore
  let identity: IdentityService
  let peer: DeviceIdentity
  let peerKey = P256.Signing.PrivateKey()
  let reservation = SessionPeerReservation()
  let radio = SessionRadioFake()
  let model: MacSessionModel
  private var peerHandshake: SessionHandshakeEngine?
  private var peerChannel: SecureSession?

  init() async throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    trust = try PeerTrustStore(url: directory.appendingPathComponent("trust.json"))
    identity = IdentityService(storage: PairingMemoryIdentity(), deviceName: "Mac", tagPrefix: "pause.connection.test.")
    let local = try await identity.publicIdentity(), key = peerKey
    peer = try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: [
      "identitySchemaVersion": 1, "algorithm": "ECDSA_P256_SHA256", "platform": "android",
      "deviceId": UUID().uuidString.lowercased(), "deviceName": "Phone",
      "publicKey": key.publicKey.x963Representation.base64EncodedString(),
      "fingerprint": DeviceIdentity.fingerprint(key.publicKey.x963Representation)]))
    let hash = Data(repeating: 11, count: 32)
    try trust.prepare(PeerTrustRecord(peer: peer, localFingerprint: local.fingerprint,
      method: .qr, pairedAt: Date(), transcriptHash: hash, active: false))
    try trust.activate(peerID: peer.deviceId, hash: hash,
      receipt: key.signature(for: PairingCodec.receipt(hash, 1)).derRepresentation)
    domain = "aniCe.PauseConnectionTests." + UUID().uuidString
    preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
    model = MacSessionModel(identity: identity, adapter: radio, store: { [trust] in trust },
      preferences: preferences, peers: reservation)
    model.selectedPeer = peer
  }

  func secureBluetooth() async throws {
    func waitFor(_ condition: () -> Bool) async throws {
      for _ in 0..<3000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
      }
      throw SessionFailure.expired
    }
    try await waitFor { radio.sessionAdmitted != nil }
    let local = try await identity.publicIdentity(), peer = peer, key = peerKey
    let client = try SessionHandshakeEngine(local: peer, responder: false,
      trusted: { [local] }, currentIdentity: { peer },
      signer: { SignedIdentityPayload(identity: peer, signature: try key.signature(for: $0).derRepresentation) },
      selectedPeer: local)
    peerHandshake = client
    XCTAssertTrue(radio.sessionAdmitted?() ?? false)
    let message1 = try await client.initiate()
    XCTAssertTrue(radio.sessionWrite?(try SessionEnvelope.encode(1, message1)) ?? false)
    try await waitFor { !radio.sent.isEmpty }
    let message2 = try SessionEnvelope.decode(radio.sent.removeFirst())
    let message3 = try await client.authenticateResponder(message2.1)
    XCTAssertTrue(radio.sessionWrite?(try SessionEnvelope.encode(3, message3)) ?? false)
    try await waitFor { !radio.sent.isEmpty }
    let message4 = try SessionEnvelope.decode(radio.sent.removeFirst())
    try await client.confirmResponder(message4.1)
    let records = PairingBus()
    let channel = try await SecureSession.fromHandshake(client, responder: false,
      capacity: { _ in true }, submit: { await records.send($0) })
    peerChannel = channel
    try await channel.send(.ready)
    let ready = await records.take()
    XCTAssertTrue(radio.sessionWrite?(try SessionEnvelope.encode(6, XCTUnwrap(ready.first))) ?? false)
    try await waitFor { model.state == "Secured" && !radio.sent.isEmpty }
    let ack = try SessionEnvelope.decode(radio.sent.removeFirst())
    _ = try await channel.receive(ack.1)
  }

  func close() {
    model.setAutomatic(false)
    let channel = peerChannel, handshake = peerHandshake
    Task { await channel?.close(); await handshake?.close() }
    preferences.removePersistentDomain(forName: domain)
    try? FileManager.default.removeItem(at: directory)
  }
}

@MainActor final class ConnectionPauseTests: XCTestCase {
  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<3000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Pause transition did not complete")
    throw SessionFailure.expired
  }

  func testIndependentPauseFixturesRoundTripAndRejectEveryInvalidNotice() throws {
    let helper = SessionFixtures(), rows = try helper.root("connection-pause/vectors")
    let valid = try XCTUnwrap(rows["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(rows["invalid"] as? [[String: Any]])
    let unknown = try XCTUnwrap(rows["unrecognized"] as? [[String: Any]])
    XCTAssertEqual(valid.count, 5); XCTAssertEqual(invalid.count, 23); XCTAssertEqual(unknown.count, 1)
    for row in valid {
      let bytes = try helper.b(row, "payload")
      let decoded = try XCTUnwrap(MacConnectionPauseMessage.decode(bytes))
      XCTAssertEqual(decoded.kind, (row["kind"] as? NSNumber)?.int64Value)
      XCTAssertEqual(decoded.until, (row["untilMillis"] as? NSNumber)?.int64Value)
      XCTAssertEqual(try decoded.encode(), bytes)
    }
    for row in invalid {
      let name = row["name"] as? String ?? ""
      do {
        let decoded = try MacConnectionPauseMessage.decode(helper.b(row, "payload"))
        XCTAssertNil(decoded, name)
      } catch { XCTAssertEqual(error as? SessionFailure, .malformed, name) }
    }
    XCTAssertNil(try MacConnectionPauseMessage.decode(helper.b(unknown[0], "payload")))
    for notice in [MacConnectionPauseMessage(kind: 0, until: 0),
                   MacConnectionPauseMessage(kind: 1, until: -1),
                   MacConnectionPauseMessage(kind: 1, until: MacConnectionPauseMessage.maximumUntilMillis + 1),
                   MacConnectionPauseMessage(kind: 2, until: 1)] {
      XCTAssertThrowsError(try notice.encode())
    }
  }

  func testPeerNoticeSurvivesRetirementButFreshReadinessRejectsStaleTraffic() async throws {
    let model = MacConnectionPauseModel()
    let first = MockSecuredChannel(instance: "first", transport: "ble", deviceName: "Phone")
    defer { model.clear() }
    model.available(first)
    let handled = await model.handle(try MacConnectionPauseMessage(kind: 1, until: 0).encode(), on: first.descriptor)
    XCTAssertTrue(handled == .handled)
    XCTAssertEqual(model.status(for: first.descriptor.peer), "Paused on Phone")
    XCTAssertTrue(first.sentData.isEmpty, "Receiving a notice must not echo it")
    model.retired(first.descriptor)
    XCTAssertEqual(model.status(for: first.descriptor.peer), "Paused on Phone")
    let replacement = MockSecuredChannel(instance: "new", transport: "ble", peer: first.descriptor.peer)
    model.available(replacement)
    model.retired(first.descriptor)
    let stale = await model.handle(try MacConnectionPauseMessage(kind: 1, until: 0).encode(), on: first.descriptor)
    XCTAssertTrue(stale == .discarded)
    XCTAssertNil(model.status(for: replacement.descriptor.peer))
    _ = await model.handle(try MacConnectionPauseMessage(kind: 1, until: 0).encode(), on: replacement.descriptor)
    XCTAssertNotNil(model.status(for: replacement.descriptor.peer))
    _ = await model.handle(try MacConnectionPauseMessage(kind: 2, until: 0).encode(), on: replacement.descriptor)
    XCTAssertNil(model.status(for: replacement.descriptor.peer))
  }

  func testPeerDeadlineIsCredentialScopedAndClockCatchupDoesNotExtendIt() async throws {
    var wall = Date(timeIntervalSince1970: 1_800_000_000)
    let deadline = wall.addingTimeInterval(60), model = MacConnectionPauseModel(now: { wall })
    let channel = MockSecuredChannel(deviceName: "Phone")
    defer { model.clear() }
    model.available(channel)
    let notice = try MacConnectionPauseMessage(kind: 1, until: Int64(deadline.timeIntervalSince1970 * 1000)).encode()
    for _ in 0..<5 { _ = await model.handle(notice, on: channel.descriptor) }
    XCTAssertTrue(model.status(for: channel.descriptor.peer)?.hasPrefix("Paused on Phone until ") == true)
    let other = try DeviceIdentity(deviceId: UUID().uuidString.lowercased(), deviceName: "Phone",
      publicKey: XCTUnwrap(Data(base64Encoded: channel.descriptor.peer.publicKey)))
    XCTAssertEqual(other.fingerprint, channel.descriptor.peer.fingerprint)
    XCTAssertNil(model.status(for: other))
    wall = wall.addingTimeInterval(-3600)
    model.reconcileTime()
    XCTAssertNotNil(model.status(for: channel.descriptor.peer))
    wall = deadline
    model.reconcileTime()
    XCTAssertNil(model.status(for: channel.descriptor.peer))
    _ = await model.handle(notice, on: channel.descriptor)
    XCTAssertNil(model.status(for: channel.descriptor.peer))
  }

  func testAnnouncementsPreferLanAndFallbackWithoutDuplicateOrRetiredReplay() async throws {
    let model = MacConnectionPauseModel(), lan = MockSecuredChannel(instance: "lan", deviceName: "Phone")
    let ble = MockSecuredChannel(instance: "ble", transport: "ble", peer: lan.descriptor.peer)
    model.available(ble); model.available(lan)
    await model.announcePause(until: nil)
    XCTAssertEqual(lan.sentData.count, 1); XCTAssertTrue(ble.sentData.isEmpty)
    lan.onSendData = { _ in throw SessionBackpressure() }
    await model.announceResume()
    XCTAssertEqual(try MacConnectionPauseMessage.decode(XCTUnwrap(ble.sentData.first)),
      MacConnectionPauseMessage(kind: 2, until: 0))
    model.retired(lan.descriptor); model.retired(ble.descriptor)
    model.capacityAvailable(ble.descriptor)
    await model.announcePause(until: nil)
    XCTAssertEqual(lan.sentData.count, 2); XCTAssertEqual(ble.sentData.count, 1)
  }

  func testInMemoryNoticeRetentionIsBoundedAndLocalClearDropsAllPeers() async throws {
    let model = MacConnectionPauseModel()
    var peers = [DeviceIdentity]()
    for index in 0..<17 {
      let channel = MockSecuredChannel(instance: "\(index)", deviceName: "Phone \(index)")
      peers.append(channel.descriptor.peer)
      model.available(channel)
      _ = await model.handle(try MacConnectionPauseMessage(kind: 1, until: 0).encode(), on: channel.descriptor)
      model.retired(channel.descriptor)
    }
    XCTAssertEqual(peers.filter { model.status(for: $0) != nil }.count, 16)
    model.clear()
    XCTAssertTrue(peers.allSatisfy { model.status(for: $0) == nil })
  }

  func testExplicitConnectResumesSavedPauseAndCancelDoesNotDisableAutomaticChoice() async throws {
    let fixture = try await PauseSessionFixture()
    defer { fixture.close() }
    let model = fixture.model
    fixture.preferences.set(true, forKey: "session.automatic")
    fixture.preferences.set(true, forKey: "session.paused")
    fixture.preferences.set(0.0, forKey: "session.pausedUntil")
    model.restoreAutomatic()
    XCTAssertFalse(model.automaticArmed)
    model.allow()
    XCTAssertFalse(model.allowing, "Automatic work must still respect the pause")
    model.allowExplicit()
    try await waitFor { fixture.radio.started }
    XCTAssertTrue(model.automaticArmed)
    XCTAssertNil(model.connectionPauseStatus)
    XCTAssertFalse(fixture.preferences.bool(forKey: "session.paused"))
    let stopped = fixture.radio.stopped
    for _ in 0..<10 { model.allowExplicit() }
    XCTAssertEqual(fixture.radio.stopped, stopped, "Repeated Connect must not restart a live owner")
    let stale = fixture.radio.sessionAdmitted
    model.cancelAttempt()
    XCTAssertFalse(model.allowing)
    XCTAssertTrue(model.automaticArmed)
    XCTAssertFalse(model.waitingAutomatically)
    XCTAssertFalse(fixture.preferences.bool(forKey: "session.paused"))
    XCTAssertTrue(fixture.preferences.bool(forKey: "session.automatic"))
    XCTAssertFalse(stale?() ?? true)
    fixture.radio.started = false
    model.allowExplicit()
    try await waitFor { fixture.radio.started }
  }

  func testExplicitPausedConnectPublishesExactlyOneResumeNotice() async throws {
    for overdue in [false, true] {
      let fixture = try await PauseSessionFixture()
      defer { fixture.close() }
      fixture.preferences.set(true, forKey: "session.automatic")
      fixture.preferences.set(true, forKey: "session.paused")
      fixture.preferences.set(0.0, forKey: "session.pausedUntil")
      fixture.model.restoreAutomatic()
      if overdue {
        fixture.preferences.set(Date().addingTimeInterval(-60).timeIntervalSince1970, forKey: "session.pausedUntil")
      }
      var resumes = 0
      fixture.model.pauseResumed = { resumes += 1 }
      fixture.model.allowExplicit()
      XCTAssertEqual(resumes, 1)
      XCTAssertNil(fixture.model.connectionPauseStatus)
      XCTAssertFalse(fixture.preferences.bool(forKey: "session.paused"))
      try await waitFor { fixture.radio.started }
    }
  }

  func testPauseRetiresUnfinishedBleAdmissionBeforeTheNoticeAndFencesQueuedCallbacks() async throws {
    for admitted in [false, true] {
      let fixture = try await PauseSessionFixture(), gate = SessionRecoveryWait()
      defer { gate.release(); fixture.close() }
      fixture.model.setAutomatic(true)
      try await waitFor { fixture.radio.sessionAdmitted != nil }
      let oldAdmission = try XCTUnwrap(fixture.radio.sessionAdmitted)
      let oldWrite = try XCTUnwrap(fixture.radio.sessionWrite)
      if admitted { XCTAssertTrue(oldAdmission()) }
      fixture.model.pauseNotice = { _ in await gate.pause(0) }
      fixture.model.pauseAutomatic(for: nil)
      XCTAssertFalse(fixture.model.allowing, "Unfinished setup must stop before any notice await")
      XCTAssertFalse(oldAdmission())
      XCTAssertFalse(oldWrite(Data([1])))
      try await waitFor { !gate.delays.isEmpty }
      XCTAssertNotEqual(fixture.model.state, "Secured")
      XCTAssertNil(fixture.reservation.peer)
      fixture.model.allowExplicit()
      try await waitFor { fixture.radio.sessionAdmitted != nil }
      let stops = fixture.radio.stopped
      gate.release()
      try await Task.sleep(for: .milliseconds(30))
      XCTAssertTrue(fixture.model.allowing)
      XCTAssertEqual(fixture.radio.stopped, stops)
    }
  }

  func testPauseRetiresManualLanAdmissionAndRejectsQueuedAccepts() async throws {
    let fixture = try await PauseSessionFixture(), gate = SessionRecoveryWait()
    let endpoint = try LanDirectEndpoint(ip: "192.0.2.10", port: 51234, profile: .lanTransfer512)
    let lan = MacLanSessionModel(identity: fixture.identity, peers: fixture.reservation,
      startListener: { _ in }, endpointProvider: { _, _ in endpoint }, store: { fixture.trust })
    defer { gate.release(); lan.cancel(); fixture.close() }
    fixture.model.setAutomatic(true)
    try await fixture.secureBluetooth()
    lan.allow(selected: fixture.peer, bluetoothAllowing: false)
    try await waitFor { lan.listener?.newConnectionHandler != nil }
    let listener = try XCTUnwrap(lan.listener)
    let oldAccept = try XCTUnwrap(listener.newConnectionHandler)
    let oldReady = try XCTUnwrap(listener.stateUpdateHandler)
    oldReady(.ready)
    try await waitFor { lan.state == "Disconnected" }
    fixture.model.prepareLinkedPause = { lan.preparePause() }
    fixture.model.pauseNotice = { _ in await gate.pause(0) }
    fixture.model.pauseAutomatic(for: nil)
    XCTAssertFalse(lan.allowing)
    XCTAssertNil(lan.listener)
    XCTAssertTrue(fixture.model.allowing, "Only the already-secured BLE link remains for metadata")
    let socket = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    oldAccept(socket)
    oldReady(.ready)
    try await waitFor { !gate.delays.isEmpty }
    XCTAssertFalse(lan.allowing)
    XCTAssertNotEqual(lan.state, "Connecting")
    gate.release()
    try await waitFor { !fixture.model.allowing }
  }

  func testPauseGatesLinkedWorkAndSubmitsNoticeBeforeEitherTeardown() async throws {
    let fixture = try await PauseSessionFixture(), gate = SessionRecoveryWait()
    defer { gate.release(); fixture.close() }
    fixture.model.setAutomatic(true)
    try await fixture.secureBluetooth()
    var events = [String]()
    fixture.model.prepareLinkedPause = { events.append("gated"); return { events.append("LAN closed") } }
    fixture.model.pauseNotice = { until in
      XCTAssertNil(until)
      events.append("notice")
      do { try await fixture.model.sendData(MacConnectionPauseMessage(kind: 1, until: 0).encode()) }
      catch { XCTFail("Secured pause metadata could not be sent: \(error)") }
      await gate.pause(0)
      events.append("sent")
    }
    fixture.model.pauseAutomatic(for: nil)
    XCTAssertEqual(events, ["gated"])
    XCTAssertFalse(fixture.model.automaticArmed)
    try await waitFor { !gate.delays.isEmpty }
    XCTAssertTrue(fixture.model.allowing)
    XCTAssertEqual(events, ["gated", "notice"])
    gate.release()
    try await waitFor { !fixture.model.allowing }
    XCTAssertEqual(events, ["gated", "notice", "sent", "LAN closed"])
  }

  func testResumeSupersedesDelayedNoticeCompletionAndKeepsCurrentOwner() async throws {
    let fixture = try await PauseSessionFixture(), gate = SessionRecoveryWait()
    defer { gate.release(); fixture.close() }
    fixture.model.setAutomatic(true)
    try await fixture.secureBluetooth()
    var closed = 0
    fixture.model.prepareLinkedPause = { { closed += 1 } }
    fixture.model.pauseNotice = { _ in await gate.pause(0) }
    fixture.model.pauseAutomatic(for: 3600)
    try await waitFor { !gate.delays.isEmpty }
    fixture.model.allowExplicit()
    let stops = fixture.radio.stopped
    gate.release()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(closed, 0)
    XCTAssertEqual(fixture.radio.stopped, stops)
    XCTAssertTrue(fixture.model.allowing)
    XCTAssertTrue(fixture.model.automaticArmed)
    XCTAssertNil(fixture.model.connectionPauseStatus)
  }

  func testNoticeBudgetClosesEvenWhenAProducerIgnoresCancellation() async throws {
    let fixture = try await PauseSessionFixture(), gate = SessionRecoveryWait()
    defer { gate.release(); fixture.close() }
    fixture.model.setAutomatic(true)
    try await fixture.secureBluetooth()
    var closed = 0
    fixture.model.prepareLinkedPause = { { closed += 1 } }
    fixture.model.pauseNotice = { _ in await gate.pause(0) }
    fixture.model.pauseAutomatic(for: nil)
    try await waitFor { !gate.delays.isEmpty }
    try await waitFor { closed == 1 }
    XCTAssertFalse(fixture.model.allowing)
    gate.release()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(closed, 1)
    XCTAssertEqual(fixture.model.connectionPauseStatus, "Paused")
  }

  func testDeviceConnectStartsBothOwnersAndLinkedCloseCannotRetireReplacementLan() async throws {
    let fixture = try await PauseSessionFixture()
    fixture.preferences.set(true, forKey: "lan.automatic")
    var starts = 0
    let lan = MacLanSessionModel(identity: fixture.identity, peers: fixture.reservation,
      preferences: fixture.preferences, startListener: { _ in starts += 1 }, store: { fixture.trust })
    defer { lan.cancel(); fixture.close() }
    let savedTrust = try Data(contentsOf: fixture.trust.location)
    fixture.model.connectDevice(fixture.peer, alongside: lan)
    try await waitFor { fixture.radio.started && starts == 1 }
    XCTAssertTrue(fixture.model.allowing); XCTAssertTrue(lan.allowing)
    XCTAssertEqual(fixture.reservation.peer, fixture.peer)
    XCTAssertEqual(lan.selectedPeer, fixture.peer)
    let listener = try XCTUnwrap(lan.listener)
    for _ in 0..<10 { fixture.model.connectDevice(fixture.peer, alongside: lan) }
    XCTAssertEqual(starts, 1)
    XCTAssertTrue(lan.listener === listener)
    let oldClose = lan.preparePause()
    lan.allow(selected: fixture.peer, bluetoothAllowing: false)
    try await waitFor { lan.listener?.stateUpdateHandler != nil }
    oldClose()
    XCTAssertTrue(lan.allowing, "Delayed Pause must not close a new LAN admission")
    XCTAssertTrue(lan.automatic)
    fixture.model.setAutomatic(true)
    fixture.model.cancelAttempt(); lan.cancelAttempt()
    XCTAssertTrue(fixture.model.automaticArmed)
    XCTAssertTrue(lan.automatic)
    XCTAssertFalse(fixture.model.allowing); XCTAssertFalse(lan.allowing)
    XCTAssertEqual(try Data(contentsOf: fixture.trust.location), savedTrust)
  }

  func testPausedConnectionControlsRenderAcrossThemesWidthsAndTextScalesWithoutStartingWork() async throws {
    let fixture = try await PauseSessionFixture()
    defer { fixture.close() }
    fixture.preferences.set(true, forKey: "session.automatic")
    fixture.preferences.set(true, forKey: "session.paused")
    fixture.preferences.set(0.0, forKey: "session.pausedUntil")
    fixture.model.restoreAutomatic()
    let local = try await fixture.identity.publicIdentity()
    let records = fixture.trust.list(localFingerprint: local.fingerprint)
    let lan = MacLanSessionModel(identity: fixture.identity, peers: fixture.reservation, store: { fixture.trust })
    defer { lan.cancel() }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let folder = root.appendingPathComponent("build/connection-ux-validation/macos-renders")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for scheme: ColorScheme in [.light, .dark] {
      for width in [400.0, 720.0] {
        for scale in [0.8, 1.2] {
          fixture.preferences.set(scale, forKey: "ui.fontScale")
          let view = MacSessionView(peers: records, model: fixture.model, lan: lan,
            connectionPause: MacConnectionPauseModel(), phonePower: MacPhonePowerModel(),
            details: .constant(false), diagnostics: .constant(false), onManageDevices: {})
            .defaultAppStorage(fixture.preferences).environment(\.colorScheme, scheme)
            .font(.system(size: 13 * scale)).frame(width: width)
          let host = NSHostingView(rootView: view), size = host.fittingSize
          XCTAssertEqual(size.width, width, accuracy: 1)
          XCTAssertGreaterThan(size.height, 100); XCTAssertLessThan(size.height, 1000)
          host.frame = NSRect(origin: .zero, size: size)
          host.layoutSubtreeIfNeeded()
          let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          host.cacheDisplay(in: host.bounds, to: bitmap)
          let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          try bytes.write(to: folder.appendingPathComponent("pause-\(scheme == .light ? "light" : "dark")-\(Int(width))-\(Int(scale * 100)).png"))
        }
      }
    }
    XCTAssertFalse(fixture.radio.started)
    XCTAssertFalse(lan.allowing)
    XCTAssertFalse(fixture.model.automaticArmed)
  }
}

@MainActor final class FeatureDispatchTests: XCTestCase {
  func testActivityRequiresLiveSuccessfulSendOrHandledReceive() async throws {
    let dispatch = FeatureDispatch(), handler = Handler(), peer = MockSecuredChannel().descriptor.peer
    dispatch.register(handler)
    var activity: [Data] = []
    dispatch.applicationActivity = { descriptor, bytes in
      XCTAssertEqual(descriptor.instance, "live")
      activity.append(bytes)
    }
    dispatch.available(ChannelDescriptor(instance: "live", transport: "ble", peer: peer)) { _ in }
    try await XCTUnwrap(handler.channel).sendData(Data([1]))
    handler.result = .handled
    let result = await dispatch.handle(Data([2]), transport: "ble", instance: "live")
    XCTAssertEqual(result, .handled)
    handler.result = .discarded
    _ = await dispatch.handle(Data([3]), transport: "ble", instance: "live")
    handler.result = .unrecognized
    _ = await dispatch.handle(Data([4]), transport: "ble", instance: "live")
    _ = await dispatch.handle(Data([5]), transport: "ble", instance: "stale")
    XCTAssertEqual(activity, [Data([1]), Data([2])])
    dispatch.available(ChannelDescriptor(instance: "failed", transport: "ble", peer: peer)) { _ in throw SessionBackpressure() }
    do { try await XCTUnwrap(handler.channel).sendData(Data([6])); XCTFail("Refused submission succeeded") }
    catch is SessionBackpressure {}
    XCTAssertEqual(activity.count, 2)
  }
  private final class Handler: FeatureHandler {
    var channel: (any SecuredChannel)?
    var retirement = 0, capacity = 0, received = 0
    var result = DataHandling.unrecognized
    var receive: (() async -> Void)?
    func available(_ channel: any SecuredChannel) { self.channel=channel }
    func retired(_ descriptor: ChannelDescriptor) { retirement += 1 }
    func capacityAvailable(_ descriptor: ChannelDescriptor) { capacity += 1 }
    func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling { received += 1; await receive?(); return result }
  }
  func testSuspendedDeliveryAllowsUIAndRejectsRetiredFallthrough() async throws {
    let fixture = SessionFixtures(), root = try fixture.root()
    let row = try XCTUnwrap((root["valid"] as? [[String: Any]])?.first)
    let peer = try fixture.identity(row, "initiator")
    let dispatch = FeatureDispatch(), first = Handler(), next = Handler()
    dispatch.register(first); dispatch.register(next)
    dispatch.available(ChannelDescriptor(instance: "old", transport: "ble", peer: peer)) { _ in }
    var entered = false
    var resume: CheckedContinuation<Void, Never>?
    first.receive = { entered = true; await withCheckedContinuation { resume = $0 } }
    let delivery = Task { await dispatch.handle(Data([1]), transport: "ble", instance: "old") }
    for _ in 0..<200 {
      if entered { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(entered, "Awaited delivery blocked the presentation owner")
    dispatch.available(ChannelDescriptor(instance: "new", transport: "ble", peer: peer)) { _ in }
    resume?.resume()
    let result = await delivery.value
    XCTAssertEqual(result, .discarded)
    XCTAssertEqual(next.received, 0)
  }

  func testRetiredChannelsBoundsAndConnectionCheckFallback() async throws {
    let fixture=SessionFixtures(), root=try fixture.root()
    let row=try XCTUnwrap((root["valid"] as? [[String:Any]])?.first)
    let peer=try fixture.identity(row,"initiator")
    let dispatch=FeatureDispatch(), handler=Handler(); dispatch.register(handler)
    var sends=0
    dispatch.available(ChannelDescriptor(instance:"first",transport:"ble",peer:peer)) { _ in sends += 1 }
    let old=try XCTUnwrap(handler.channel)
    let handlingResult1 = await dispatch.handle(Data([1]),transport:"ble",instance:"first")
    XCTAssertEqual(handlingResult1,.unrecognized)
    handler.result = .discarded
    let handlingResult2 = await dispatch.handle(Data([1]),transport:"ble",instance:"first")
    XCTAssertEqual(handlingResult2,.discarded)
    dispatch.capacityAvailable("ble"); XCTAssertEqual(handler.capacity,1)
    dispatch.available(ChannelDescriptor(instance:"second",transport:"ble",peer:peer)) { _ in sends += 1 }
    XCTAssertEqual(handler.retirement,1)
    let handlingResult3 = await dispatch.handle(Data([1]),transport:"ble",instance:"first")
    XCTAssertEqual(handlingResult3,.discarded)
    XCTAssertEqual(handler.received,2)
    do { try await old.sendData(Data([1])); XCTFail("Retired channel sent DATA") } catch let error as SessionFailure { XCTAssertEqual(error,.cancelled) }
    XCTAssertEqual(sends,0)
    let current=try XCTUnwrap(handler.channel)
    try await current.sendData(Data(count:4000)); XCTAssertEqual(sends,1)
    do { try await current.sendData(Data(count:4001)); XCTFail("Oversized DATA sent") } catch let error as SessionFailure { XCTAssertEqual(error,.malformed) }
    XCTAssertEqual(sends,1)
    dispatch.retired("ble"); dispatch.capacityAvailable("ble"); XCTAssertEqual(handler.capacity,1)
  }
}
