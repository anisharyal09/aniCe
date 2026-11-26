// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies notification wire compatibility, snapshot reconciliation and native action routing.
import XCTest
import CryptoKit
import UserNotifications
@testable import aniCe

private final class MirrorNotificationCenterSpy: MacMirrorNotificationCenter, @unchecked Sendable {
  var pending: [UNNotificationRequest] = []
  var delivered: [UNNotification] = []
  var registered: Set<UNNotificationCategory> = []
  var added: [UNNotificationRequest] = []
  var removedPending: [[String]] = []
  var removedDelivered: [[String]] = []
  var addError: Error?
  var delayNextCategoryRead = false
  var pendingCategoryRead: (@Sendable (MacMirrorCategorySnapshot) -> Void)?
  var holdAdds = false
  var pendingAdds: [@Sendable (Error?) -> Void] = []

  func mirrorPendingIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void) { completionHandler(pending.map(\.identifier)) }
  func mirrorDeliveredIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void) { completionHandler(delivered.map { $0.request.identifier }) }
  func mirrorCategories(completionHandler: @escaping @Sendable (MacMirrorCategorySnapshot) -> Void) {
    if delayNextCategoryRead {
      delayNextCategoryRead = false
      pendingCategoryRead = completionHandler
    } else {
      completionHandler(MacMirrorCategorySnapshot(values: registered))
    }
  }
  func resumeCategoryRead() {
    let completion = pendingCategoryRead
    pendingCategoryRead = nil
    completion?(MacMirrorCategorySnapshot(values: registered))
  }
  func setMirrorCategories(_ categories: Set<UNNotificationCategory>) { registered = categories }
  func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
    added.append(request)
    if holdAdds, let completionHandler { pendingAdds.append(completionHandler) }
    else { completionHandler?(addError) }
  }
  func removeDeliveredNotifications(withIdentifiers identifiers: [String]) { removedDelivered.append(identifiers) }
  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) { removedPending.append(identifiers) }
}

@MainActor
final class NotificationMirrorTests: XCTestCase {
  private let epoch = "01234567-89ab-4cde-8fab-0123456789ab"
  private let id = String(repeating: "a", count: 64)

  private func androidPeer() throws -> DeviceIdentity {
    let key = P256.Signing.PrivateKey()
    let macIdentity = try DeviceIdentity(deviceId: UUID().uuidString.lowercased(), deviceName: "Phone",
      publicKey: key.publicKey.x963Representation)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(macIdentity)) as? [String: Any])
    object["platform"] = "android"
    return try DeviceIdentity.decode(JSONSerialization.data(withJSONObject: object))
  }

  private func wire(_ kind: Int64, _ fields: [SessionCBOR]) throws -> Data {
    try NotificationWireMessage(kind: kind, fields: fields).encode()
  }

  private func notification(_ id: String? = nil, epoch: String? = nil, sequence: Int64,
    title: String, token: String = "", actions: [[SessionCBOR]] = []) throws -> Data {
    let rows = actions.map { SessionCBOR.array($0) }
    return try wire(2, [
      .text(token), .text(id ?? self.id), .text(epoch ?? self.epoch), .integer(sequence),
      .text("com.example.chat"), .text("Chat"), .text(title), .text("Message body"), .array(rows),
    ])
  }

  private func ready(_ model: MacNotificationMirrorModel, _ channel: MockSecuredChannel) async throws {
    model.available(channel)
    let result = await model.handle(try wire(1, [.integer(8)]), on: channel.descriptor)
    if case .handled = result {} else { XCTFail("capability should be handled") }
    for _ in 0..<8 { await Task.yield() }
  }

  private func waitFor(_ name: String, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(2)
    while !condition() && Date() < deadline {
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertTrue(condition(), "timed out waiting for \(name)")
  }

  private func incoming(_ model: MacNotificationMirrorModel, channel: MockSecuredChannel,
    id: String, sequence: Int64, token: String, title: String) async throws {
    _ = await model.handle(try wire(2, [
      .text(token), .text(id), .text(epoch), .integer(sequence), .text("com.example.chat"),
      .text("Chat"), .text(title), .text("Message body"), .array([]),
    ]), on: channel.descriptor)
  }

  func testSharedFixturesCoverKindsBoundsAndMalformedEncodings() throws {
    let root = try SessionFixtures().root("notification-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(valid.count, 12)
    XCTAssertGreaterThanOrEqual(invalid.count, 15)
    var kinds = Set<Int64>()
    for row in valid {
      let bytes = try SessionFixtures().b(row, "bytes")
      let message = try XCTUnwrap(NotificationWireMessage.decode(bytes), row["name"] as? String ?? "")
      XCTAssertEqual(try message.encode(), bytes)
      if let kind = row["kind"] as? Int64 { kinds.insert(kind) }
    }
    XCTAssertEqual(kinds, Set<Int64>(1...9))
    for row in invalid {
      let bytes = try SessionFixtures().b(row, "bytes")
      let name = row["name"] as? String ?? ""
      if name == "wrong-tag" || name == "record-over-limit" {
        XCTAssertNil(try NotificationWireMessage.decode(bytes), name)
      } else {
        XCTAssertThrowsError(try NotificationWireMessage.decode(bytes), name)
      }
    }
    XCTAssertNil(try NotificationWireMessage.decode(Data(repeating: 0, count: 4001)))
  }

  func testSnapshotReconciliationAndDuplicateUpdatesAreIdempotent() async throws {
    let center = MirrorNotificationCenterSpy()
    let existing = UNNotificationCategory(identifier: "ANICE_SMS", actions: [], intentIdentifiers: [])
    center.registered = [existing]
    let notifier = MacNotificationMirrorNotifier(center: center)
    let model = MacNotificationMirrorModel(notifier: notifier)
    let channel = MockSecuredChannel(transport: "ble", peer: try androidPeer())
    try await ready(model, channel)
    let token = UUID().uuidString.lowercased()
    _ = await model.handle(try wire(4, [.text(token), .text(epoch), .integer(1)]), on: channel.descriptor)
    try await incoming(model, channel: channel, id: id, sequence: 1, token: token, title: "First")
    _ = await model.handle(try wire(5, [.text(token)]), on: channel.descriptor)
    await waitFor("first notification") { center.added.count == 1 }
    XCTAssertNil(center.added.first?.content.sound, "reconnect snapshots must be silent")
    XCTAssertTrue(center.registered.contains(existing), "mirror categories must preserve other feature categories")

    try await incoming(model, channel: channel, id: id, sequence: 1, token: "", title: "Duplicate")
    XCTAssertEqual(center.added.count, 1)
    let removalsBeforeUpdate = center.removedDelivered.flatMap { $0 }.count
    try await incoming(model, channel: channel, id: id, sequence: 2, token: "", title: "Updated")
    XCTAssertEqual(center.added.count, 2)
    XCTAssertEqual(center.added.last?.content.title, "Updated")
    XCTAssertNil(center.added.last?.content.sound, "a later live revision must update silently")
    XCTAssertEqual(center.added.last?.content.interruptionLevel, .passive)
    XCTAssertEqual(center.removedDelivered.flatMap { $0 }.count, removalsBeforeUpdate,
      "an update must not remove the delivered alert before replacing it")

    let stale = center.added[0]
    XCTAssertFalse(notifier.handleAction(category: stale.content.categoryIdentifier,
      action: UNNotificationDefaultActionIdentifier, identifier: stale.identifier, userText: "",
      sourceEpoch: epoch, sourceSequence: 1), "an action from an old revision must be rejected")

    let nextToken = UUID().uuidString.lowercased()
    _ = await model.handle(try wire(4, [.text(nextToken), .text(epoch), .integer(3)]), on: channel.descriptor)
    _ = await model.handle(try wire(5, [.text(nextToken)]), on: channel.descriptor)
    XCTAssertTrue(center.removedDelivered.flatMap { $0 }.contains(center.added[1].identifier))
  }

  func testSourceAppIconIsAttachedToMirroredNotification() async throws {
    let center = MirrorNotificationCenterSpy()
    let notifier = MacNotificationMirrorNotifier(center: center)
    let model = MacNotificationMirrorModel(notifier: notifier)
    let channel = MockSecuredChannel(transport: "lan", peer: try androidPeer())
    try await ready(model, channel)

    let root = try SessionFixtures().root("notification-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let iconRow = try XCTUnwrap(valid.first { ($0["kind"] as? Int) == 9 })
    let iconMessage = try XCTUnwrap(NotificationWireMessage.decode(SessionFixtures().b(iconRow, "bytes")))
    _ = await model.handle(try wire(9, [.text("com.example.chat"), .bytes(iconMessage.bytes(1))]), on: channel.descriptor)
    try await incoming(model, channel: channel, id: id, sequence: 1, token: "", title: "With source icon")

    await waitFor("notification with source icon") { center.added.count == 1 }
    let request = try XCTUnwrap(center.added.first)
    XCTAssertEqual(request.content.attachments.map(\.identifier), ["source-app-icon"])
  }

  func testNativeForegroundPresentationKeepsPassiveUpdatesQuietAcrossFeatures() {
    for category in [MacSmsNotifier.category, MacSmsNotifier.resultCategory,
      MacTransferNotifier.Category.offer, MacTransferNotifier.Category.result,
      MacNotificationMirrorNotifier.categoryPrefix + "test"] {
      let content = UNMutableNotificationContent()
      content.categoryIdentifier = category
      content.interruptionLevel = .active
      content.sound = .default
      XCTAssertEqual(AppDelegate.presentationOptions(for: content), [.banner, .list, .sound])
      content.sound = nil
      XCTAssertEqual(AppDelegate.presentationOptions(for: content), [.banner, .list])
      content.interruptionLevel = .passive
      content.sound = .default
      XCTAssertEqual(AppDelegate.presentationOptions(for: content), [.list])
    }
    let unrelated = UNMutableNotificationContent()
    unrelated.categoryIdentifier = "unrelated"
    XCTAssertTrue(AppDelegate.presentationOptions(for: unrelated).isEmpty)
  }

  func testMirroredSourceAndDeviceAttributionUsesIndependentNativeGroups() async throws {
    let center = MirrorNotificationCenterSpy()
    let notifier = MacNotificationMirrorNotifier(center: center)
    let value = MirroredNotification(snapshotToken: "", id: id, epoch: epoch, sequence: 1,
      packageName: "com.example.chat", appName: "Chat", title: "Review alert", body: "Disposable content",
      sourceIcon: nil, actions: [])
    await notifier.post(peerKey: "first", peerName: "Phone A", value: value)
    await notifier.post(peerKey: "second", peerName: "Phone B", value: value)
    XCTAssertEqual(center.added.map(\.content.subtitle), ["Chat · Phone A", "Chat · Phone B"])
    XCTAssertNotEqual(center.added[0].content.threadIdentifier, center.added[1].content.threadIdentifier)
    XCTAssertNotEqual(center.added[0].identifier, center.added[1].identifier)
    XCTAssertEqual(center.added[0].content.body, "Disposable content")
  }

  func testSameRevisionIconEnrichmentCannotReenableAnAlreadyConsumedAction() async throws {
    let center = MirrorNotificationCenterSpy()
    let notifier = MacNotificationMirrorNotifier(center: center)
    func value(_ token: String) -> MirroredNotification {
      MirroredNotification(snapshotToken: token, id: id, epoch: epoch, sequence: 1,
        packageName: "com.example.chat", appName: "Chat", title: "Review", body: "",
        sourceIcon: nil, actions: [.init(index: 0, title: "Reply", replyPlaceholder: "Message")])
    }
    await notifier.post(peerKey: "peer", value: value(""))
    let first = try XCTUnwrap(center.added.last)
    let category = try XCTUnwrap(center.registered.first { $0.identifier == first.content.categoryIdentifier })
    try exportNotificationReview(first, category: category, name: "mirror-live")
    var replies = 0
    notifier.onAction = { _, _, _, _, action in if case .invoke = action { replies += 1 } }
    XCTAssertTrue(notifier.handleAction(category: first.content.categoryIdentifier, action: "ANICE_MIRROR_ACTION_0",
      identifier: first.identifier, userText: "One reply", sourceEpoch: epoch, sourceSequence: 1))
    await notifier.post(peerKey: "peer", value: value("icon-refresh"))
    let enriched = try XCTUnwrap(center.added.last)
    try exportNotificationReview(enriched, category: category, name: "mirror-passive")
    XCTAssertFalse(notifier.handleAction(category: enriched.content.categoryIdentifier, action: "ANICE_MIRROR_ACTION_0",
      identifier: enriched.identifier, userText: "Duplicate", sourceEpoch: epoch, sourceSequence: 1))
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(enriched.content.interruptionLevel, .passive)
  }

  func testLateSuccessfulNativeAddCannotReviveADismissedOrRetiredAlert() async throws {
    let center = MirrorNotificationCenterSpy()
    center.holdAdds = true
    let notifier = MacNotificationMirrorNotifier(center: center)
    let value = MirroredNotification(snapshotToken: "", id: id, epoch: epoch, sequence: 1,
      packageName: "com.example.chat", appName: "Chat", title: "Disposable review", body: "",
      sourceIcon: nil, actions: [])
    await notifier.post(peerKey: "peer", value: value)
    let request = try XCTUnwrap(center.added.last)
    notifier.clear(peerKey: "peer")
    let clears = center.removedDelivered.count
    center.pendingAdds[0](nil)
    await waitFor("late submission cleanup") { center.removedDelivered.count > clears }
    XCTAssertFalse(notifier.handleAction(category: request.content.categoryIdentifier, action: UNNotificationDefaultActionIdentifier,
      identifier: request.identifier, userText: "", sourceEpoch: epoch, sourceSequence: 1))
  }

  func testSourceAppIconsAreRejectedOverBluetooth() async throws {
    let center = MirrorNotificationCenterSpy()
    let notifier = MacNotificationMirrorNotifier(center: center)
    let model = MacNotificationMirrorModel(notifier: notifier)
    let channel = MockSecuredChannel(transport: "ble", peer: try androidPeer())
    try await ready(model, channel)

    let root = try SessionFixtures().root("notification-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let iconRow = try XCTUnwrap(valid.first { ($0["kind"] as? Int) == 9 })
    let iconMessage = try XCTUnwrap(NotificationWireMessage.decode(SessionFixtures().b(iconRow, "bytes")))
    let result = await model.handle(try wire(9, [.text("com.example.chat"), .bytes(iconMessage.bytes(1))]),
      on: channel.descriptor)
    if case .discarded = result {} else { XCTFail("source icons must be LAN-only") }
  }

  func testLanIconEnrichesBleNotificationWithoutAlertingAgain() async throws {
    let center = MirrorNotificationCenterSpy()
    let notifier = MacNotificationMirrorNotifier(center: center)
    let model = MacNotificationMirrorModel(notifier: notifier)
    let peer = try androidPeer()
    let bluetooth = MockSecuredChannel(transport: "ble", peer: peer)
    let localNetwork = MockSecuredChannel(transport: "lan", peer: peer)
    try await ready(model, bluetooth)
    try await ready(model, localNetwork)
    try await incoming(model, channel: bluetooth, id: id, sequence: 1, token: "", title: "Live call")
    await waitFor("Bluetooth notification") { center.added.count == 1 }
    XCTAssertEqual(center.added[0].content.interruptionLevel, .active)

    let bluetoothSnapshot = UUID().uuidString.lowercased()
    _ = await model.handle(try wire(4, [.text(bluetoothSnapshot), .text(epoch), .integer(1)]),
      on: bluetooth.descriptor)
    try await incoming(model, channel: bluetooth, id: id, sequence: 1, token: bluetoothSnapshot, title: "Live call")
    _ = await model.handle(try wire(5, [.text(bluetoothSnapshot)]), on: bluetooth.descriptor)

    let root = try SessionFixtures().root("notification-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let iconRow = try XCTUnwrap(valid.first { ($0["kind"] as? Int) == 9 })
    let iconMessage = try XCTUnwrap(NotificationWireMessage.decode(SessionFixtures().b(iconRow, "bytes")))
    let lanSnapshot = UUID().uuidString.lowercased()
    _ = await model.handle(try wire(4, [.text(lanSnapshot), .text(epoch), .integer(1)]),
      on: localNetwork.descriptor)
    _ = await model.handle(try wire(9, [.text("com.example.chat"), .bytes(iconMessage.bytes(1))]),
      on: localNetwork.descriptor)
    try await incoming(model, channel: localNetwork, id: id, sequence: 1, token: lanSnapshot, title: "Live call")
    _ = await model.handle(try wire(5, [.text(lanSnapshot)]), on: localNetwork.descriptor)

    await waitFor("silently enriched notification") { center.added.count == 2 }
    XCTAssertEqual(center.added[1].content.interruptionLevel, .passive)
    XCTAssertEqual(center.added[1].content.attachments.map(\.identifier), ["source-app-icon"])
  }

  func testSnapshotFinishPreservesLiveUpdatesAboveItsHighWaterSequence() async throws {
    let center = MirrorNotificationCenterSpy()
    let notifier = MacNotificationMirrorNotifier(center: center)
    let model = MacNotificationMirrorModel(notifier: notifier)
    let channel = MockSecuredChannel(transport: "ble", peer: try androidPeer())
    try await ready(model, channel)
    try await incoming(model, channel: channel, id: id, sequence: 2, token: "", title: "Live update")
    await waitFor("live update") { center.added.count == 1 }
    let request = try XCTUnwrap(center.added.first)
    XCTAssertEqual(request.content.interruptionLevel, .active)
    XCTAssertNotNil(request.content.sound, "the first live revision must alert")
    let removalsBeforeSnapshot = center.removedDelivered.flatMap { $0 }.count

    let token = UUID().uuidString.lowercased()
    _ = await model.handle(try wire(4, [.text(token), .text(epoch), .integer(1)]), on: channel.descriptor)
    _ = await model.handle(try wire(5, [.text(token)]), on: channel.descriptor)

    XCTAssertEqual(center.removedDelivered.flatMap { $0 }.count, removalsBeforeSnapshot)
    XCTAssertTrue(notifier.handleAction(category: request.content.categoryIdentifier,
      action: UNNotificationDefaultActionIdentifier, identifier: request.identifier, userText: "",
      sourceEpoch: epoch, sourceSequence: 2), "a live update newer than the snapshot high-water must remain active")
    await waitFor("retained live tap") {
      channel.sentData.contains {
        guard let message = try? NotificationWireMessage.decode($0), message.kind == 6 else { return false }
        return (try? message.number(3)) == 2
      }
    }
  }

  func testRemovalAndCompletedSnapshotRejectDelayedNotificationCopies() async throws {
    let center = MirrorNotificationCenterSpy()
    let model = MacNotificationMirrorModel(notifier: MacNotificationMirrorNotifier(center: center))
    let channel = MockSecuredChannel(transport: "ble", peer: try androidPeer())
    try await ready(model, channel)
    let original = try notification(sequence: 1, title: "Original")
    _ = await model.handle(original, on: channel.descriptor)
    _ = await model.handle(try wire(3, [.text(id), .text(epoch), .integer(1)]), on: channel.descriptor)
    _ = await model.handle(original, on: channel.descriptor)
    XCTAssertEqual(center.added.count, 1, "a removed revision must not be recreated by the other transport")

    let token = UUID().uuidString.lowercased()
    _ = await model.handle(try wire(4, [.text(token), .text(epoch), .integer(1)]), on: channel.descriptor)
    _ = await model.handle(try wire(5, [.text(token)]), on: channel.descriptor)
    _ = await model.handle(original, on: channel.descriptor)
    XCTAssertEqual(center.added.count, 1, "snapshot compaction must preserve rejection of stale revisions")
    _ = await model.handle(try notification(sequence: 2, title: "New revision"), on: channel.descriptor)
    XCTAssertEqual(center.added.count, 2, "a newer revision must still be delivered")
  }

  func testReplyDismissalAndDuplicateResponseAreBoundToCurrentRevision() async throws {
    let center = MirrorNotificationCenterSpy()
    let notifier = MacNotificationMirrorNotifier(center: center)
    let model = MacNotificationMirrorModel(notifier: notifier)
    let channel = MockSecuredChannel(transport: "lan", peer: try androidPeer())
    try await ready(model, channel)
    let token = UUID().uuidString.lowercased()
    _ = await model.handle(try wire(4, [.text(token), .text(epoch), .integer(1)]), on: channel.descriptor)
    let actionRows: [[SessionCBOR]] = [[.integer(0), .text("Reply"), .text("Message")]]
    _ = await model.handle(try notification(sequence: 1, title: "Incoming", token: token, actions: actionRows), on: channel.descriptor)
    _ = await model.handle(try wire(5, [.text(token)]), on: channel.descriptor)
    await waitFor("reply notification") { center.added.count == 1 }
    let request = try XCTUnwrap(center.added.first)
    XCTAssertTrue(notifier.handleAction(category: request.content.categoryIdentifier, action: "ANICE_MIRROR_ACTION_0",
      identifier: request.identifier, userText: "Thanks", sourceEpoch: epoch, sourceSequence: 1))
    XCTAssertFalse(notifier.handleAction(category: request.content.categoryIdentifier, action: "ANICE_MIRROR_ACTION_0",
      identifier: request.identifier, userText: "Thanks", sourceEpoch: epoch, sourceSequence: 1), "duplicate OS callbacks must not send the action twice")
    await waitFor("reply action record") {
      channel.sentData.contains { (try? NotificationWireMessage.decode($0)?.kind) == 6 }
    }
    let reply = try XCTUnwrap(channel.sentData.compactMap { try? NotificationWireMessage.decode($0) }.first { $0.kind == 6 })
    XCTAssertEqual(try reply.text(5), "Thanks")

    let dismissToken = UUID().uuidString.lowercased()
    _ = await model.handle(try wire(4, [.text(dismissToken), .text(epoch), .integer(2)]), on: channel.descriptor)
    _ = await model.handle(try notification(sequence: 2, title: "Second", token: dismissToken), on: channel.descriptor)
    _ = await model.handle(try wire(5, [.text(dismissToken)]), on: channel.descriptor)
    await waitFor("second notification") { center.added.count == 2 }
    let second = try XCTUnwrap(center.added.last)
    XCTAssertTrue(notifier.handleAction(category: second.content.categoryIdentifier, action: UNNotificationDismissActionIdentifier,
      identifier: second.identifier, userText: "", sourceEpoch: epoch, sourceSequence: 2))
    XCTAssertFalse(notifier.handleAction(category: second.content.categoryIdentifier, action: UNNotificationDismissActionIdentifier,
      identifier: second.identifier, userText: "", sourceEpoch: epoch, sourceSequence: 2))
    await waitFor("dismiss request") {
      channel.sentData.contains { (try? NotificationWireMessage.decode($0)?.kind) == 8 }
    }

    let tapToken = UUID().uuidString.lowercased()
    _ = await model.handle(try wire(4, [.text(tapToken), .text(epoch), .integer(3)]), on: channel.descriptor)
    _ = await model.handle(try notification(sequence: 3, title: "Open source", token: tapToken), on: channel.descriptor)
    _ = await model.handle(try wire(5, [.text(tapToken)]), on: channel.descriptor)
    await waitFor("tap notification") { center.added.count == 3 }
    let tapRequest = try XCTUnwrap(center.added.last)
    XCTAssertTrue(notifier.handleAction(category: tapRequest.content.categoryIdentifier,
      action: UNNotificationDefaultActionIdentifier, identifier: tapRequest.identifier, userText: "",
      sourceEpoch: epoch, sourceSequence: 3))
    await waitFor("source tap record") {
      channel.sentData.compactMap { try? NotificationWireMessage.decode($0) }
        .last(where: { $0.kind == 6 }).flatMap { try? $0.number(4) } == -1
    }
  }

  func testDistinctActionsRemainAvailableAfterAnotherAction() async throws {
    let center = MirrorNotificationCenterSpy()
    let notifier = MacNotificationMirrorNotifier(center: center)
    let value = MirroredNotification(snapshotToken: "", id: id, epoch: epoch, sequence: 1,
      packageName: "com.example.phone", appName: "Phone", title: "Missed call", body: "",
      sourceIcon: nil,
      actions: [.init(index: 0, title: "Reminder", replyPlaceholder: ""),
        .init(index: 1, title: "Call back", replyPlaceholder: "")])
    var invoked: [Int] = []
    notifier.onAction = { _, _, _, _, action in
      if case .invoke(let index, _) = action { invoked.append(index) }
    }
    await notifier.post(peerKey: "phone", value: value)
    let request = try XCTUnwrap(center.added.last)
    for index in [0, 1] {
      XCTAssertTrue(notifier.handleAction(category: request.content.categoryIdentifier,
        action: "ANICE_MIRROR_ACTION_\(index)", identifier: request.identifier, userText: "",
        sourceEpoch: epoch, sourceSequence: 1))
      XCTAssertFalse(notifier.handleAction(category: request.content.categoryIdentifier,
        action: "ANICE_MIRROR_ACTION_\(index)", identifier: request.identifier, userText: "",
        sourceEpoch: epoch, sourceSequence: 1))
    }
    XCTAssertEqual(invoked, [0, 1])
    XCTAssertTrue(notifier.handleAction(category: request.content.categoryIdentifier,
      action: UNNotificationDismissActionIdentifier, identifier: request.identifier, userText: "",
      sourceEpoch: epoch, sourceSequence: 1))
  }

  func testQueuedActionCannotTargetANewerNotificationRevision() async throws {
    let center = MirrorNotificationCenterSpy()
    let notifier = MacNotificationMirrorNotifier(center: center)
    let model = MacNotificationMirrorModel(notifier: notifier)
    let channel = MockSecuredChannel(transport: "lan", peer: try androidPeer())
    try await ready(model, channel)

    let token = UUID().uuidString.lowercased()
    _ = await model.handle(try wire(4, [.text(token), .text(epoch), .integer(1)]), on: channel.descriptor)
    let firstAction: [[SessionCBOR]] = [[.integer(0), .text("Open"), .text("")]]
    _ = await model.handle(try notification(sequence: 1, title: "First", token: token, actions: firstAction), on: channel.descriptor)
    _ = await model.handle(try wire(5, [.text(token)]), on: channel.descriptor)
    await waitFor("first revision") { center.added.count == 1 }
    let first = try XCTUnwrap(center.added.first)

    // Hold category registration while the old system banner remains visible.
    center.delayNextCategoryRead = true
    let secondAction: [[SessionCBOR]] = [[.integer(0), .text("Reply"), .text("Message")]]
    let update = try notification(sequence: 2, title: "Second", actions: secondAction)
    let updateTask = Task { await model.handle(update, on: channel.descriptor) }
    await waitFor("category registration pause") { center.pendingCategoryRead != nil }

    XCTAssertFalse(notifier.handleAction(category: first.content.categoryIdentifier,
      action: UNNotificationDefaultActionIdentifier, identifier: first.identifier, userText: "",
      sourceEpoch: epoch, sourceSequence: 1))
    let feedback = try XCTUnwrap(center.added.last)
    XCTAssertEqual(feedback.content.title, "Notification out of date")
    XCTAssertNil(feedback.content.sound)
    XCTAssertFalse(channel.sentData.contains { (try? NotificationWireMessage.decode($0)?.kind) == 6 },
      "a queued action from the old alert must not target the newer revision")

    center.resumeCategoryRead()
    await updateTask.value
    await waitFor("second revision") { center.added.last?.content.userInfo["anice.mirror.sequence"] as? Int64 == 2 }
  }

  func testDisconnectCancelsPresentationWaitingForCategoryRegistration() async throws {
    let center = MirrorNotificationCenterSpy()
    let notifier = MacNotificationMirrorNotifier(center: center)
    let model = MacNotificationMirrorModel(notifier: notifier)
    let channel = MockSecuredChannel(transport: "lan", peer: try androidPeer())
    try await ready(model, channel)
    center.delayNextCategoryRead = true
    let bytes = try notification(sequence: 1, title: "Pending")
    let pending = Task { await model.handle(bytes, on: channel.descriptor) }
    await waitFor("pending registration") { center.pendingCategoryRead != nil }
    model.retired(channel.descriptor)
    center.resumeCategoryRead()
    await pending.value
    XCTAssertTrue(center.added.isEmpty, "disconnect must invalidate posts that have not reached Notification Center")
    XCTAssertFalse(center.registered.contains { $0.identifier.hasPrefix(MacNotificationMirrorNotifier.categoryPrefix) })
  }

  func testCategoryChurnPrunesUnusedShapesButPreservesSharedAndOtherFeatureCategories() async throws {
    let center = MirrorNotificationCenterSpy()
    let sms = MacSmsNotifier.notificationCategory
    center.registered = [sms]
    let notifier = MacNotificationMirrorNotifier(center: center)
    let peer = "peer"
    for revision in 1...256 {
      let value = MirroredNotification(snapshotToken: "", id: id, epoch: epoch, sequence: Int64(revision),
        packageName: "com.example.chat", appName: "Chat", title: "Alert", body: "",
        sourceIcon: nil, actions: [.init(index: 0, title: "Open \(revision)", replyPlaceholder: "")])
      await notifier.post(peerKey: peer, value: value)
      XCTAssertEqual(center.registered.filter { $0.identifier.hasPrefix(MacNotificationMirrorNotifier.categoryPrefix) }.count, 1)
      XCTAssertTrue(center.registered.contains(sms))
    }
    let second = String(repeating: "b", count: 64)
    await notifier.post(peerKey: peer, value: MirroredNotification(snapshotToken: "", id: second,
      epoch: epoch, sequence: 257, packageName: "com.example.chat", appName: "Chat", title: "", body: "",
      sourceIcon: nil, actions: [.init(index: 0, title: "Open 256", replyPlaceholder: "")]))
    notifier.clear(peerKey: peer, sourceId: id)
    await waitFor("shared category retained") { center.registered.count == 2 }
    notifier.clear(peerKey: peer, sourceId: second)
    await waitFor("unused mirror categories removed") { center.registered == [sms] }
  }

  func testPendingFirstAlertDoesNotSilenceItsNewerReplacement() async throws {
    let center = MirrorNotificationCenterSpy()
    let notifier = MacNotificationMirrorNotifier(center: center)
    center.delayNextCategoryRead = true
    func value(_ revision: Int64) -> MirroredNotification {
      MirroredNotification(snapshotToken: "", id: id, epoch: epoch, sequence: revision,
        packageName: "com.example.chat", appName: "Chat", title: "Revision \(revision)", body: "",
        sourceIcon: nil, actions: [])
    }
    let first = Task { await notifier.post(peerKey: "peer", value: value(1)) }
    await waitFor("first pending category") { center.pendingCategoryRead != nil }
    let second = Task { await notifier.post(peerKey: "peer", value: value(2)) }
    for _ in 0..<8 { await Task.yield() }
    center.resumeCategoryRead()
    await first.value; await second.value
    XCTAssertEqual(center.added.count, 1)
    XCTAssertEqual(center.added.first?.content.title, "Revision 2")
    XCTAssertEqual(center.added.first?.content.interruptionLevel, .active)
    XCTAssertNotNil(center.added.first?.content.sound)
  }

  func testRemovalChurnCompactsWithoutResurrectingOldRevisions() async throws {
    let center = MirrorNotificationCenterSpy()
    let model = MacNotificationMirrorModel(notifier: MacNotificationMirrorNotifier(center: center))
    let channel = MockSecuredChannel(peer: try androidPeer())
    try await ready(model, channel)
    try await incoming(model, channel: channel, id: id, sequence: 1, token: "", title: "Old")
    _ = await model.handle(try wire(3, [.text(id), .text(epoch), .integer(2)]), on: channel.descriptor)
    for revision in 3...512 {
      let removedId = String(format: "%064x", revision)
      _ = await model.handle(try wire(3, [.text(removedId), .text(epoch), .integer(Int64(revision))]), on: channel.descriptor)
      XCTAssertLessThanOrEqual(model.removals.count, 128)
    }
    try await incoming(model, channel: channel, id: id, sequence: 1, token: "", title: "Stale")
    XCTAssertEqual(center.added.count, 1)
    try await incoming(model, channel: channel, id: id, sequence: 513, token: "", title: "New")
    XCTAssertEqual(center.added.count, 2)
    let token = UUID().uuidString.lowercased()
    _ = await model.handle(try wire(4, [.text(token), .text(epoch), .integer(514)]), on: channel.descriptor)
    _ = await model.handle(try wire(5, [.text(token)]), on: channel.descriptor)
    XCTAssertTrue(model.removals.isEmpty)
  }

  func testActiveInventoryKeepsNewestAlertsWhenRemovalDeliveryLags() async throws {
    let center = MirrorNotificationCenterSpy()
    let notifier = MacNotificationMirrorNotifier(center: center)
    let model = MacNotificationMirrorModel(notifier: notifier)
    let channel = MockSecuredChannel(peer: try androidPeer())
    try await ready(model, channel)
    for revision in 1...128 {
      try await incoming(model, channel: channel, id: String(format: "%064x", revision),
        sequence: Int64(revision), token: "", title: "Current")
    }
    XCTAssertEqual(center.added.count, 128)
    let overflow = await model.handle(try notification(String(format: "%064x", 129),
      sequence: 129, title: "Overflow"), on: channel.descriptor)
    XCTAssertEqual(overflow, .handled)
    XCTAssertEqual(center.added.count, 129)
    let first = try XCTUnwrap(center.added.first)
    XCTAssertTrue(center.removedDelivered.flatMap { $0 }.contains(first.identifier))
    XCTAssertFalse(notifier.handleAction(category: first.content.categoryIdentifier,
      action: UNNotificationDefaultActionIdentifier, identifier: first.identifier, userText: "",
      sourceEpoch: epoch, sourceSequence: 1))
    let countAfterFeedback = center.added.count
    try await incoming(model, channel: channel, id: String(format: "%064x", 1), sequence: 1, token: "", title: "Late")
    XCTAssertEqual(center.added.count, countAfterFeedback)
  }

  func testProgrammaticCleanupDoesNotDismissAndDeniedSubmissionHasNoActionTarget() async throws {
    let center = MirrorNotificationCenterSpy()
    let notifier = MacNotificationMirrorNotifier(center: center)
    let model = MacNotificationMirrorModel(notifier: notifier)
    let channel = MockSecuredChannel(transport: "ble", peer: try androidPeer())
    try await ready(model, channel)
    let token = UUID().uuidString.lowercased()
    _ = await model.handle(try wire(4, [.text(token), .text(epoch), .integer(1)]), on: channel.descriptor)
    _ = await model.handle(try notification(sequence: 1, title: "Secret", token: token), on: channel.descriptor)
    _ = await model.handle(try wire(5, [.text(token)]), on: channel.descriptor)
    await waitFor("cleanup notification") { center.added.count == 1 }
    let request = try XCTUnwrap(center.added.first)
    let peerKey = channel.descriptor.peer.deviceId + ":" + channel.descriptor.peer.fingerprint
    notifier.clear(peerKey: peerKey)
    model.retired(channel.descriptor)
    XCTAssertFalse(channel.sentData.contains { (try? NotificationWireMessage.decode($0)?.kind) == 8 })

    let deniedCenter = MirrorNotificationCenterSpy()
    deniedCenter.addError = NSError(domain: "notification-permission", code: 1)
    let deniedNotifier = MacNotificationMirrorNotifier(center: deniedCenter)
    let deniedValue = MirroredNotification(snapshotToken: "", id: id, epoch: epoch, sequence: 1,
      packageName: "com.example.chat", appName: "Chat", title: "Secret", body: "private",
      sourceIcon: nil,
      actions: [.init(index: 0, title: "Reply", replyPlaceholder: "Message")])
    await deniedNotifier.post(peerKey: peerKey, value: deniedValue)
    let deniedRequest = try XCTUnwrap(deniedCenter.added.first)
    for _ in 0..<8 { await Task.yield() }
    XCTAssertFalse(deniedNotifier.handleAction(category: deniedRequest.content.categoryIdentifier,
      action: "ANICE_MIRROR_ACTION_0", identifier: deniedRequest.identifier, userText: "x",
      sourceEpoch: epoch, sourceSequence: 1), "failed OS submission must not leave an actionable target")
    XCTAssertTrue(center.removedDelivered.flatMap { $0 }.contains(request.identifier))
  }

  func testBleLanHandoffKeepsOneAlertUntilTheFinalLinkAndRejectsUnsupportedPeer() async throws {
    let center = MirrorNotificationCenterSpy()
    let notifier = MacNotificationMirrorNotifier(center: center)
    let model = MacNotificationMirrorModel(notifier: notifier)
    let ble = MockSecuredChannel(transport: "ble", peer: try androidPeer())
    let lan = MockSecuredChannel(transport: "lan", peer: ble.descriptor.peer)
    try await ready(model, ble)
    let firstToken = UUID().uuidString.lowercased()
    _ = await model.handle(try wire(4, [.text(firstToken), .text(epoch), .integer(1)]), on: ble.descriptor)
    try await incoming(model, channel: ble, id: id, sequence: 1, token: firstToken, title: "Same alert")
    _ = await model.handle(try wire(5, [.text(firstToken)]), on: ble.descriptor)
    await waitFor("BLE alert") { center.added.count == 1 }

    try await ready(model, lan)
    let secondToken = UUID().uuidString.lowercased()
    _ = await model.handle(try wire(4, [.text(secondToken), .text(epoch), .integer(1)]), on: lan.descriptor)
    try await incoming(model, channel: lan, id: id, sequence: 1, token: secondToken, title: "Same alert")
    _ = await model.handle(try wire(5, [.text(secondToken)]), on: lan.descriptor)
    XCTAssertEqual(center.added.count, 1, "a BLE/LAN snapshot must not post a duplicate alert")

    let removalsBeforeHandoff = center.removedDelivered.flatMap { $0 }.count
    model.retired(ble.descriptor)
    XCTAssertEqual(center.removedDelivered.flatMap { $0 }.count, removalsBeforeHandoff)
    model.retired(lan.descriptor)
    XCTAssertGreaterThan(center.removedDelivered.flatMap { $0 }.count, removalsBeforeHandoff)

    let unsupportedModel = MacNotificationMirrorModel(notifier: MacNotificationMirrorNotifier(center: MirrorNotificationCenterSpy()))
    let macPeerChannel = MockSecuredChannel(transport: "ble")
    unsupportedModel.available(macPeerChannel)
    for _ in 0..<8 { await Task.yield() }
    XCTAssertTrue(macPeerChannel.sentData.isEmpty, "Mac must not start mirroring to another Mac peer")
  }

  func testCallActionResultFeedbackHandlesSuccessStaleUnsupportedDuplicatesDisconnectAndTimeout() async throws {
    let center = MirrorNotificationCenterSpy()
    let notifier = MacNotificationMirrorNotifier(center: center)
    let model = MacNotificationMirrorModel(notifier: notifier, actionTimeout: .milliseconds(300))
    let channel = MockSecuredChannel(transport: "lan", peer: try androidPeer())
    let otherPhone = MockSecuredChannel(transport: "ble", peer: try androidPeer())
    try await ready(model, otherPhone)
    try await ready(model, channel)

    func postCall(sequence: Int64, actionTitle: String = "Answer") async throws -> String {
      let actions: [SessionCBOR] = [.array([.integer(0), .text(actionTitle), .text("")])]
      _ = await model.handle(try wire(2, [
        .text(""), .text(id), .text(epoch), .integer(sequence),
        .text("com.whatsapp"), .text("WhatsApp"), .text("Incoming call"), .text("Caller"), .array(actions),
      ]), on: channel.descriptor)
      let added = try XCTUnwrap(center.added.last)
      XCTAssertEqual(added.content.userInfo["anice.mirror.sequence"] as? Int64, sequence)
      XCTAssertTrue(notifier.handleAction(
        category: added.content.categoryIdentifier,
        action: "ANICE_MIRROR_ACTION_0",
        identifier: added.identifier,
        userText: "",
        sourceEpoch: epoch,
        sourceSequence: sequence))
      func sentAction() -> NotificationWireMessage? {
        channel.sentData.compactMap { try? NotificationWireMessage.decode($0) }.first {
          $0.kind == 6 && (try? $0.number(3)) == sequence
        }
      }
      await waitFor("kind 6 sent for revision \(sequence)") { sentAction() != nil }
      let sent = try XCTUnwrap(sentAction())
      return try sent.text(0)
    }

    let req0 = try await postCall(sequence: 1)
    let beforeFeedback0 = center.added.count
    let accepted = try wire(7, [.text(req0), .integer(0)])
    _ = await model.handle(accepted, on: otherPhone.descriptor)
    XCTAssertEqual(center.added.count, beforeFeedback0, "another peer cannot consume the original request")
    _ = await model.handle(accepted, on: channel.descriptor)
    XCTAssertEqual(center.added.count, beforeFeedback0 + 1)
    let feedback = try XCTUnwrap(center.added.last)
    XCTAssertEqual(feedback.content.title, "Request sent to phone")
    XCTAssertNil(feedback.content.sound)
    _ = await model.handle(accepted, on: channel.descriptor)
    XCTAssertEqual(center.added.count, beforeFeedback0 + 1, "duplicate kind 7 must be ignored")

    let req1 = try await postCall(sequence: 2)
    _ = await model.handle(try wire(7, [.text(req1), .integer(1)]), on: channel.descriptor)
    XCTAssertEqual(center.added.last?.content.title, "Notification out of date")
    XCTAssertEqual(center.added.last?.identifier, feedback.identifier, "feedback replaces the previous notice")

    let req2 = try await postCall(sequence: 3)
    _ = await model.handle(try wire(7, [.text(req2), .integer(2)]), on: channel.descriptor)
    XCTAssertEqual(center.added.last?.content.title, "Action unavailable")

    let reqQuiet = try await postCall(sequence: 4, actionTitle: "Decline invitation")
    let beforeQuiet = center.added.count
    _ = await model.handle(try wire(7, [.text(reqQuiet), .integer(0)]), on: channel.descriptor)
    XCTAssertEqual(center.added.count, beforeQuiet)

    let reqTimeout = try await postCall(sequence: 5)
    let beforeTimeout = center.added.count
    await waitFor("timeout feedback") { center.added.count > beforeTimeout }
    XCTAssertEqual(center.added.last?.content.title, "Couldn’t confirm the action")
    _ = await model.handle(try wire(7, [.text(reqTimeout), .integer(0)]), on: channel.descriptor)
    XCTAssertEqual(center.added.count, beforeTimeout + 1, "late results cannot replace timeout feedback")

    _ = try await postCall(sequence: 6)
    let beforeDisconnect = center.added.count
    model.retired(channel.descriptor)
    XCTAssertEqual(center.added.count, beforeDisconnect + 1)
    XCTAssertEqual(center.added.last?.content.title, "Couldn’t confirm the action")
  }

  func testActionUsesReadyBluetoothWhileLanIsNegotiatingAndReportsSendFailure() async throws {
    let center = MirrorNotificationCenterSpy()
    let notifier = MacNotificationMirrorNotifier(center: center)
    let model = MacNotificationMirrorModel(notifier: notifier)
    let ble = MockSecuredChannel(transport: "ble", peer: try androidPeer())
    let lan = MockSecuredChannel(transport: "lan", peer: ble.descriptor.peer)
    try await ready(model, ble)
    model.available(lan)
    ble.onSendData = { bytes in
      if try NotificationWireMessage.decode(bytes)?.kind == 6 { throw SessionBackpressure() }
    }
    _ = await model.handle(try notification(sequence: 1, title: "Incoming call",
      actions: [[.integer(0), .text("Answer"), .text("")]]), on: ble.descriptor)
    let request = try XCTUnwrap(center.added.last)
    XCTAssertTrue(notifier.handleAction(category: request.content.categoryIdentifier,
      action: "ANICE_MIRROR_ACTION_0", identifier: request.identifier, userText: "",
      sourceEpoch: epoch, sourceSequence: 1))
    await waitFor("send failure feedback") { center.added.last?.content.title == "Couldn’t confirm the action" }
    XCTAssertEqual(ble.sentData.compactMap { try? NotificationWireMessage.decode($0) }.filter { $0.kind == 6 }.count, 1)
    XCTAssertFalse(lan.sentData.contains { (try? NotificationWireMessage.decode($0)?.kind) == 6 })
  }
}
