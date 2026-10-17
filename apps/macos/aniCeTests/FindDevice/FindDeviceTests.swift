// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises independent wire bytes, dismissal replay, generation races and bounded Find Device state.
import XCTest
import UserNotifications
import CryptoKit
import SwiftUI
@testable import aniCe

@MainActor private final class FindNotifierFake: FindDeviceNotifying {
  var posts: [String] = []
  var cleared: [String] = []
  var result: FindResult = .submitted
  var gate: CheckedContinuation<FindResult, Never>?
  var suspend = false
  func post(identifier: String, peerName: String) async -> FindResult {
    posts.append(identifier)
    if suspend { return await withCheckedContinuation { gate = $0 } }
    return result
  }
  func clear(identifier: String) { cleared.append(identifier) }
}
final class FindDeviceTests: XCTestCase {
  func testIndependentFixturesAndMalformedInventory() throws {
    let root = try SessionFixtures().root("find-device-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(valid.count, 8); XCTAssertGreaterThanOrEqual(invalid.count, 24)
    for row in valid {
      let data = try SessionFixtures().b(row, "bytes"), message = try XCTUnwrap(FindDeviceMessage.decode(data))
      XCTAssertEqual(try message.encode(), data)
    }
    for row in invalid { XCTAssertThrowsError(try FindDeviceMessage.decode(SessionFixtures().b(row, "bytes")), row["name"] as? String ?? "") }
    XCTAssertNil(try FindDeviceMessage.decode(SessionCbor.encode(.array([.text("other")]))))
  }
  @MainActor private func ready(_ owner: MacFindDeviceModel, _ channel: MockSecuredChannel) async throws {
    owner.available(channel)
    let result = await owner.handle(try FindDeviceMessage(kind: 1).encode(), on: channel.descriptor)
    XCTAssertEqual(result, .handled)
    await Task.yield()
  }
  @MainActor func testPrimaryPeersHideDisconnectedDevicesUntilAllConnectionsRetire() {
    let owner = MacFindDeviceModel(notifier: FindNotifierFake())
    let lan = MockSecuredChannel(transport: "lan")
    let ble = MockSecuredChannel(transport: "ble")
    let peers = [ble.descriptor.peer, lan.descriptor.peer]
    func displayed() -> [DeviceIdentity] {
      ConnectionPresentation.primaryPeers(peers, connected: { owner.connected($0) })
    }
    XCTAssertEqual(displayed(), peers)
    XCTAssertTrue(ConnectionPresentation.primaryPeers([DeviceIdentity](), connected: { owner.connected($0) }).isEmpty)
    owner.available(lan)
    XCTAssertFalse(owner.canFind(lan.descriptor.peer))
    XCTAssertEqual(displayed(), [lan.descriptor.peer])
    owner.available(ble)
    XCTAssertEqual(displayed(), peers)
    let replacement = MockSecuredChannel(instance: "replacement", transport: "lan", peer: lan.descriptor.peer)
    owner.available(replacement)
    owner.retired(lan.descriptor)
    XCTAssertEqual(displayed(), peers)
    owner.retired(replacement.descriptor)
    XCTAssertEqual(displayed(), [ble.descriptor.peer])
    owner.retired(ble.descriptor)
    XCTAssertEqual(displayed(), peers)
  }
  @MainActor func testConnectionPresenceDoesNotImplyAdvertisedSupportAndIgnoresStaleRetirement() async throws {
    let owner = MacFindDeviceModel(notifier: FindNotifierFake())
    let first = MockSecuredChannel(instance: "first")
    let peer = first.descriptor.peer
    XCTAssertFalse(owner.connected(peer))
    owner.available(first)
    XCTAssertTrue(owner.connected(peer))
    XCTAssertFalse(owner.supports(peer))
    XCTAssertFalse(owner.connected(MockSecuredChannel().descriptor.peer))
    let replacement = MockSecuredChannel(instance: "replacement", peer: peer)
    owner.available(replacement)
    owner.retired(first.descriptor)
    XCTAssertTrue(owner.connected(peer))
    try await ready(owner, replacement)
    XCTAssertTrue(owner.supports(peer))
    owner.retired(replacement.descriptor)
    XCTAssertFalse(owner.connected(peer))
    XCTAssertFalse(owner.supports(peer))
  }
  @MainActor func testDismissDuplicateCacheEvictionAndAbsoluteExpiry() async throws {
    var time = 0.0
    let notifier = FindNotifierFake(), channel = MockSecuredChannel()
    let owner = MacFindDeviceModel(notifier: notifier, now: { time })
    try await ready(owner, channel)
    let first = FindDeviceMessage(kind: 2, id: UUID().uuidString.lowercased(), sequence: 1)
    _ = await owner.handle(try first.encode(), on: channel.descriptor)
    let id = try XCTUnwrap(notifier.posts.first)
    owner.dismiss(identifier: id)
    _ = await owner.handle(try first.encode(), on: channel.descriptor)
    XCTAssertEqual(notifier.posts.count, 1)
    for i in 2...36 {
      _ = await owner.handle(try FindDeviceMessage(kind: 2, id: UUID().uuidString.lowercased(), sequence: Int64(i)).encode(), on: channel.descriptor)
      if let last = notifier.posts.last { owner.dismiss(identifier: last) }
      await Task.yield()
    }
    let count = notifier.posts.count
    _ = await owner.handle(try first.encode(), on: channel.descriptor)
    XCTAssertEqual(notifier.posts.count, count)
    _ = await owner.handle(try FindDeviceMessage(kind: 2, id: UUID().uuidString.lowercased(), sequence: 37).encode(), on: channel.descriptor)
    let last = try XCTUnwrap(notifier.posts.last)
    time = 59; owner.expire(); XCTAssertFalse(notifier.cleared.contains(last))
    time = 60; owner.expire(); XCTAssertTrue(notifier.cleared.contains(last))
    owner.retired(channel.descriptor)
  }
  @MainActor func testPermissionDenialAndDisconnectDuringSubmissionCannotRevive() async throws {
    let notifier = FindNotifierFake(), channel = MockSecuredChannel()
    let owner = MacFindDeviceModel(notifier: notifier)
    try await ready(owner, channel)
    notifier.result = .blocked
    let request = FindDeviceMessage(kind: 2, id: UUID().uuidString.lowercased(), sequence: 1)
    _ = await owner.handle(try request.encode(), on: channel.descriptor)
    await Task.yield()
    XCTAssertEqual(try channel.sentData.compactMap { try FindDeviceMessage.decode($0) }.last?.result, FindResult.blocked.rawValue)
    notifier.suspend = true
    let bytes = try FindDeviceMessage(kind: 2, id: UUID().uuidString.lowercased(), sequence: 2).encode()
    let task = Task { await owner.handle(bytes, on: channel.descriptor) }
    while notifier.gate == nil { await Task.yield() }
    _ = await owner.handle(bytes, on: channel.descriptor)
    XCTAssertEqual(notifier.posts.count, 2)
    owner.retired(channel.descriptor)
    notifier.gate?.resume(returning: .submitted)
    let result = await task.value
    XCTAssertEqual(result, .discarded)
    XCTAssertTrue(notifier.cleared.contains(notifier.posts.last!))
  }
  @MainActor func testLANSelectionCorrelatedResultsTimeoutAndNoFallbackReplay() async throws {
    var time = 0.0
    let notifier = FindNotifierFake(), lan = MockSecuredChannel(instance: "lan")
    let ble = MockSecuredChannel(instance: "ble", transport: "ble", peer: lan.descriptor.peer)
    let owner = MacFindDeviceModel(notifier: notifier, now: { time })
    try await ready(owner, ble); try await ready(owner, lan)
    owner.find(lan.descriptor.peer); await Task.yield()
    let request = try XCTUnwrap(lan.sentData.compactMap { try FindDeviceMessage.decode($0) }.last { $0.kind == 2 })
    XCTAssertFalse(try ble.sentData.compactMap { try FindDeviceMessage.decode($0) }.contains { $0.kind == 2 })
    let reply = try FindDeviceMessage(kind: 3, id: request.id, sequence: request.sequence, result: 0).encode()
    _ = await owner.handle(reply, on: ble.descriptor); XCTAssertTrue(owner.busy)
    time = 10; owner.expire(); XCTAssertFalse(owner.busy); XCTAssertEqual(owner.feedbackKey, "find_timeout")
    _ = await owner.handle(reply, on: lan.descriptor); XCTAssertEqual(owner.feedbackKey, "find_timeout")
    owner.find(lan.descriptor.peer); owner.retired(lan.descriptor); await Task.yield()
    XCTAssertFalse(owner.busy); XCTAssertEqual(owner.feedbackKey, "find_disconnected")
    XCTAssertFalse(try ble.sentData.compactMap { try FindDeviceMessage.decode($0) }.contains { $0.kind == 2 })
    owner.retired(ble.descriptor)
  }
  @MainActor func testIncompatibleLANDoesNotHideCompatibleBLE() async throws {
    let lan = MockSecuredChannel(instance: "lan")
    let ble = MockSecuredChannel(instance: "ble", transport: "ble", peer: lan.descriptor.peer)
    let owner = MacFindDeviceModel(notifier: FindNotifierFake())
    try await ready(owner, ble); owner.available(lan)
    owner.find(lan.descriptor.peer)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertTrue(try ble.sentData.compactMap { try FindDeviceMessage.decode($0) }.contains { $0.kind == 2 })
    XCTAssertFalse(try lan.sentData.compactMap { try FindDeviceMessage.decode($0) }.contains { $0.kind == 2 })
    owner.retired(ble.descriptor); owner.retired(lan.descriptor)
  }
  @MainActor func testFreshRequestReplacesFadedMacAlertWithoutRevivingDuplicatesOrExtendingExpiry() async throws {
    var time = 0.0
    let notifier = FindNotifierFake(), channel = MockSecuredChannel()
    let owner = MacFindDeviceModel(notifier: notifier, now: { time })
    try await ready(owner, channel)
    let first = FindDeviceMessage(kind: 2, id: UUID().uuidString.lowercased(), sequence: 1)
    _ = await owner.handle(try first.encode(), on: channel.descriptor)
    let old = try XCTUnwrap(notifier.posts.last)
    time = 15
    let second = FindDeviceMessage(kind: 2, id: UUID().uuidString.lowercased(), sequence: 2)
    _ = await owner.handle(try second.encode(), on: channel.descriptor)
    let replacement = try XCTUnwrap(notifier.posts.last)
    XCTAssertNotEqual(old, replacement)
    XCTAssertEqual(notifier.posts.count, 2)
    XCTAssertTrue(notifier.cleared.contains(old))
    await Task.yield()
    XCTAssertEqual(try channel.sentData.compactMap { try FindDeviceMessage.decode($0) }.last?.result, FindResult.submitted.rawValue)
    owner.dismiss(identifier: old)
    _ = await owner.handle(try first.encode(), on: channel.descriptor)
    _ = await owner.handle(try second.encode(), on: channel.descriptor)
    XCTAssertEqual(notifier.posts.count, 2)
    XCTAssertFalse(notifier.cleared.contains(replacement))
    time = 74.999; owner.expire()
    XCTAssertFalse(notifier.cleared.contains(replacement))
    time = 75; owner.expire()
    XCTAssertTrue(notifier.cleared.contains(replacement))
    _ = await owner.handle(try second.encode(), on: channel.descriptor)
    XCTAssertEqual(notifier.posts.count, 2)
    owner.retired(channel.descriptor)
  }
  @MainActor func testAppNotificationRoutingPreservesBothFeaturesAndIgnoresUnknownCategories() {
    let center = UNUserNotificationCenter.current()
    let previousDelegate = center.delegate
    defer { center.delegate = previousDelegate }
    let find = MacFindDeviceNotifier()
    var dismissed: [String] = []
    find.dismissed = { dismissed.append($0) }
    var opened = 0
    let transfer = MacTransferNotifier(model: MacTransferModel(), openMainWindow: { opened += 1 })
    let delegate = AppDelegate()
    delegate.configureNotifications(findDevice: find, transfer: transfer)
    XCTAssertTrue(center.delegate === delegate)
    let categories = AppDelegate.notificationCategories
    XCTAssertEqual(Set(categories.map(\.identifier)), [MacFindDeviceNotifier.category,
      MacTransferNotifier.Category.offer, MacTransferNotifier.Category.result,
      MacTransferNotifier.Category.paused, MacTransferNotifier.Category.pausedSender])
    XCTAssertTrue(categories.first { $0.identifier == MacFindDeviceNotifier.category }!.options.contains(.customDismissAction))
    delegate.handleNotificationAction(category: MacFindDeviceNotifier.category,
      action: UNNotificationDismissActionIdentifier, identifier: "find-exact-id")
    XCTAssertEqual(dismissed, ["find-exact-id"])
    XCTAssertEqual(opened, 0)
    delegate.handleNotificationAction(category: MacTransferNotifier.Category.offer,
      action: MacTransferNotifier.Action.choose, identifier: "transfer")
    XCTAssertEqual(opened, 1)
    delegate.handleNotificationAction(category: "unknown",
      action: UNNotificationDefaultActionIdentifier, identifier: "unrelated")
    delegate.handleNotificationAction(category: MacTransferNotifier.Category.result,
      action: MacFindDeviceNotifier.dismissAction, identifier: "wrong-feature")
    XCTAssertEqual(opened, 1)
    XCTAssertEqual(dismissed, ["find-exact-id"])
  }
  @MainActor func testNativeActionAndOrdinaryDismissalRouteExactIdentifiers() {
    let notifier = MacFindDeviceNotifier()
    var dismissed: [String] = []
    notifier.dismissed = { dismissed.append($0) }
    notifier.handleAction(MacFindDeviceNotifier.dismissAction, identifier: "explicit")
    notifier.handleAction(UNNotificationDismissActionIdentifier, identifier: "swipe")
    notifier.handleAction("unknown", identifier: "ignored")
    XCTAssertEqual(dismissed, ["explicit", "swipe"])
  }
  @MainActor func testDismissDuringNativeSubmissionAndStaleActionCannotRestoreOrClearReplacement() async throws {
    let notifier = FindNotifierFake(), channel = MockSecuredChannel()
    let owner = MacFindDeviceModel(notifier: notifier)
    try await ready(owner, channel)
    notifier.suspend = true
    let request = FindDeviceMessage(kind: 2, id: UUID().uuidString.lowercased(), sequence: 1)
    let bytes = try request.encode()
    let task = Task { await owner.handle(bytes, on: channel.descriptor) }
    while notifier.gate == nil { await Task.yield() }
    let old = try XCTUnwrap(notifier.posts.last)
    owner.dismiss(identifier: old)
    notifier.gate?.resume(returning: .submitted)
    let outcome = await task.value
    XCTAssertEqual(outcome, .discarded)
    notifier.suspend = false
    _ = await owner.handle(bytes, on: channel.descriptor)
    XCTAssertEqual(notifier.posts.count, 1)
    _ = await owner.handle(try FindDeviceMessage(kind: 2, id: UUID().uuidString.lowercased(), sequence: 2).encode(), on: channel.descriptor)
    let replacement = try XCTUnwrap(notifier.posts.last)
    owner.dismiss(identifier: old)
    XCTAssertFalse(notifier.cleared.contains(replacement))
    owner.retired(channel.descriptor)
  }
  @MainActor func testBackpressureExpiresUnsentRequestsAndPermissionResourcesArePackaged() async throws {
    var time = 0.0
    let notifier = FindNotifierFake(), channel = MockSecuredChannel()
    let owner = MacFindDeviceModel(notifier: notifier, now: { time })
    try await ready(owner, channel)
    channel.onSendData = { _ in throw SessionBackpressure() }
    owner.find(channel.descriptor.peer); await Task.yield()
    time = 10; owner.expire()
    let count = channel.sentData.count
    channel.onSendData = nil
    owner.capacityAvailable(channel.descriptor); await Task.yield()
    XCTAssertEqual(channel.sentData.count, count)
    XCTAssertEqual(owner.feedbackKey, "find_timeout")
    XCTAssertNotEqual(MacFindDeviceNotifier.text("find_title"), "find_title")
    XCTAssertNotEqual(MacFindDeviceNotifier.text("find_notification_body"), "find_notification_body")
    owner.retired(channel.descriptor)
  }

  @MainActor func testCrossTransportDismissalAndEvictedSequencesCannotRevive() async throws {
    let notifier = FindNotifierFake(), lan = MockSecuredChannel(instance: "lan")
    let ble = MockSecuredChannel(instance: "ble", transport: "ble", peer: lan.descriptor.peer)
    let owner = MacFindDeviceModel(notifier: notifier)
    try await ready(owner, lan); try await ready(owner, ble)
    let first = FindDeviceMessage(kind: 2, id: UUID().uuidString.lowercased(), sequence: 1)
    _ = await owner.handle(try first.encode(), on: lan.descriptor)
    owner.dismiss(identifier: notifier.posts.last!)
    _ = await owner.handle(try first.encode(), on: ble.descriptor)
    XCTAssertEqual(notifier.posts.count, 1)
    for i in 2...36 {
      _ = await owner.handle(try FindDeviceMessage(kind: 2, id: UUID().uuidString.lowercased(), sequence: Int64(i)).encode(), on: lan.descriptor)
      owner.dismiss(identifier: notifier.posts.last!)
      await Task.yield()
    }
    owner.retired(lan.descriptor)
    let count = notifier.posts.count
    _ = await owner.handle(try first.encode(), on: ble.descriptor)
    XCTAssertEqual(notifier.posts.count, count)
    owner.retired(ble.descriptor)
  }

  @MainActor func testResponseQueueSaturationDoesNotSubmitWithoutHeadroom() async throws {
    let notifier = FindNotifierFake(), channel = MockSecuredChannel()
    let owner = MacFindDeviceModel(notifier: notifier)
    try await ready(owner, channel)
    channel.onSendData = { _ in throw SessionBackpressure() }
    for i in 1...12 {
      _ = await owner.handle(try FindDeviceMessage(kind: 2, id: UUID().uuidString.lowercased(), sequence: Int64(i)).encode(), on: channel.descriptor)
      if let id = notifier.posts.last { owner.dismiss(identifier: id) }
      await Task.yield()
    }
    XCTAssertEqual(notifier.posts.count, 8)
    owner.retired(channel.descriptor)
  }

  // Tests presentation policy without requesting OS authorization or rendering permission controls.
  @MainActor func testFindDevicePermissionPresentationPolicy() {
    XCTAssertEqual(FindDeviceView.permissionPresentationPolicy(for: "find_local_allowed"), .allowed)
    XCTAssertEqual(FindDeviceView.permissionPresentationPolicy(for: "find_local_blocked"), .blocked)
    XCTAssertEqual(FindDeviceView.permissionPresentationPolicy(for: "find_local_unknown"), .unknown)
    XCTAssertEqual(FindDeviceView.permissionPresentationPolicy(for: "find_local_error"), .error)
    XCTAssertEqual(FindDeviceView.permissionPresentationPolicy(for: "unexpected_status"), .unknown)
  }

  @MainActor func testFindDeviceViewRendersNonemptyLayoutWithAndWithoutPeers() throws {
    let model = MacFindDeviceModel(notifier: FindNotifierFake())
    let peer = MockSecuredChannel().descriptor.peer
    let record = PeerTrustRecord(peer: peer, localFingerprint: "fedcba9876543210", method: .qr, pairedAt: Date(), transcriptHash: Data(), receipt: nil, active: true)

    let viewWithPeer = FindDeviceView(model: model, peers: [record], notifier: nil)
    let hostWithPeer = NSHostingView(rootView: viewWithPeer)
    let sizeWithPeer = hostWithPeer.fittingSize
    XCTAssertGreaterThan(sizeWithPeer.width, 0)
    XCTAssertGreaterThan(sizeWithPeer.height, 0)

    let viewEmpty = FindDeviceView(model: model, peers: [], notifier: nil)
    let hostEmpty = NSHostingView(rootView: viewEmpty)
    let sizeEmpty = hostEmpty.fittingSize
    XCTAssertGreaterThan(sizeEmpty.width, 0)
    XCTAssertGreaterThan(sizeEmpty.height, 0)

    XCTAssertEqual(model.feedbackKey, "find_idle")
  }

}
