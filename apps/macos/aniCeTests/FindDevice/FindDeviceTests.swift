// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises independent wire bytes, dismissal replay, generation races and bounded Find Device state.
import XCTest
import UserNotifications
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

}
