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
    completionHandler?(addError)
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
    try await incoming(model, channel: channel, id: id, sequence: 2, token: "", title: "Updated")
    XCTAssertEqual(center.added.count, 2)
    XCTAssertEqual(center.added.last?.content.title, "Updated")

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

    // Hold category registration so the newer model record exists while the old OS target is still live.
    center.delayNextCategoryRead = true
    let secondAction: [[SessionCBOR]] = [[.integer(0), .text("Reply"), .text("Message")]]
    let update = try notification(sequence: 2, title: "Second", actions: secondAction)
    let updateTask = Task { await model.handle(update, on: channel.descriptor) }
    await waitFor("category registration pause") { center.pendingCategoryRead != nil }

    XCTAssertTrue(notifier.handleAction(category: first.content.categoryIdentifier,
      action: UNNotificationDefaultActionIdentifier, identifier: first.identifier, userText: "",
      sourceEpoch: epoch, sourceSequence: 1))
    XCTAssertFalse(channel.sentData.contains { (try? NotificationWireMessage.decode($0)?.kind) == 6 },
      "a queued action from the old alert must not target the newer revision")

    center.resumeCategoryRead()
    await updateTask.value
    await waitFor("second revision") { center.added.count == 2 }
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
}
