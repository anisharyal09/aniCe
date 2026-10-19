// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies SMS notification content privacy, inline reply routing and reserved cleanup.
import XCTest
import CryptoKit
import UserNotifications
@testable import aniCe

private final class SpySmsNotificationCenter: SmsNotificationCenter, @unchecked Sendable {
  var added: [UNNotificationRequest] = []
  var delivered: [String] = []
  var pending: [String] = []
  var removedDelivered: [[String]] = []
  var removedPending: [[String]] = []
  var access: SmsNotificationAccess = .authorized
  var error: Error?
  var authRequests = 0
  func settings(completionHandler: @escaping @Sendable (SmsNotificationAccess) -> Void) { completionHandler(access) }
  func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, Error?) -> Void) {
    authRequests += 1
    completionHandler(true, nil)
  }
  func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
    added.append(request)
    completionHandler?(error)
  }
  func removeDeliveredNotifications(withIdentifiers identifiers: [String]) { removedDelivered.append(identifiers) }
  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) { removedPending.append(identifiers) }
  func deliveredIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void) { completionHandler(delivered) }
  func pendingIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void) { completionHandler(pending) }
}

@MainActor
final class SmsNotifierTests: XCTestCase {
  private func preferences() -> SmsPreferences { SmsPreferences(storage: nil) }

  private func until(_ label: String, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(2)
    while !condition() && Date() < deadline {
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertTrue(condition(), "timed out waiting for \(label)")
  }

  private func phone(_ name: String = "Pixel 9") -> DeviceIdentity {
    MockSecuredChannel(deviceName: name).descriptor.peer
  }

  private func note(_ peer: DeviceIdentity, address: String = "+15551234567", body: String = "Dinner at 8?",
    identifier: String = smsNotificationPrefix + "sms:1") -> SmsNotification {
    SmsNotification(identifier: identifier, peerKey: peer.deviceId + ":" + peer.fingerprint,
      peerName: peer.deviceName, address: address, threadId: "sms:42",
      threadIdentifier: smsNormalizedAddress(address), body: body, failure: false)
  }

  @MainActor func testNotificationContentHidesBodyUntilPreviewIsEnabledForThatPeer() async throws {
    let center = SpySmsNotificationCenter(), prefs = preferences(), peer = phone()
    let notifier = MacSmsNotifier(preferences: prefs, center: center)
    await notifier.post(note(peer))
    await notifier.post(note(peer, body: "Secret", identifier: smsNotificationPrefix + "sms:2"))
    XCTAssertEqual(center.added.count, 2)
    XCTAssertEqual(center.added[0].content.categoryIdentifier, "ANICE_SMS")
    XCTAssertEqual(center.added[0].content.body, "New message")
    XCTAssertEqual(center.added[0].content.title, "+15551234567")
    XCTAssertEqual(center.added[0].content.threadIdentifier, "+15551234567")
    XCTAssertEqual(center.authRequests, 1)
    prefs.set(peer, true)
    await notifier.post(note(peer, body: "Dinner at 8?", identifier: smsNotificationPrefix + "sms:3"))
    XCTAssertEqual(center.added[2].content.body, "Dinner at 8?")
    // Preview is per peer: another phone stays generic.
    let other = phone("Tablet")
    XCTAssertFalse(prefs.preview(other))
    XCTAssertTrue(prefs.preview(peer))
    prefs.prune([other])
    XCTAssertFalse(prefs.preview(peer))
  }

  @MainActor func testFailedSubmissionCanBeRetriedAndDeniedAlertsAreVisible() async throws {
    let center = SpySmsNotificationCenter(), peer = phone()
    let notifier = MacSmsNotifier(preferences: preferences(), center: center)
    center.error = NSError(domain: "sms-test", code: 1)
    let failed = await notifier.post(note(peer))
    XCTAssertEqual(failed, .failed)
    XCTAssertFalse(notifier.status.isEmpty)
    center.error = nil
    let retried = await notifier.post(note(peer))
    XCTAssertEqual(retried, .submitted)
    XCTAssertEqual(center.added.count, 2)
    center.access = .denied
    let denied = await notifier.post(note(peer, identifier: "anice-sms-denied"))
    XCTAssertEqual(denied, .denied)
    XCTAssertTrue(notifier.status.contains("turned off"))
    center.access = .alertsDisabled
    let disabled = await notifier.post(note(peer, identifier: "anice-sms-disabled"))
    XCTAssertEqual(disabled, .alertsDisabled)
    XCTAssertEqual(center.added.count, 2)
    notifier.clear(peerKey: peer.deviceId + ":" + peer.fingerprint)
    XCTAssertFalse(notifier.handleAction(category: "other", action: "ANICE_SMS_REPLY", identifier: "anice-sms-denied"))
    XCTAssertTrue(center.removedDelivered.flatMap { $0 }.contains(note(peer).identifier))
  }

  @MainActor func testStartupCleanupOnlyRemovesReservedIdentifiers() async throws {
    let center = SpySmsNotificationCenter()
    center.pending = [smsNotificationPrefix + "one", "transfer-offer-1"]
    center.delivered = [smsNotificationPrefix + "two", "find-device-1"]
    let notifier = MacSmsNotifier(preferences: preferences(), center: center)
    await until("startup cleanup") { !center.removedPending.isEmpty && !center.removedDelivered.isEmpty }
    XCTAssertNotNil(notifier)
    XCTAssertEqual(center.removedPending, [[smsNotificationPrefix + "one"]])
    XCTAssertEqual(center.removedDelivered, [[smsNotificationPrefix + "two"]])
  }

  @MainActor func testAuthorizationIsRequestedAtLaunchNotOnTheFirstMessage() async throws {
    let center = SpySmsNotificationCenter(), peer = phone()
    let notifier = MacSmsNotifier(preferences: preferences(), center: center)
    XCTAssertEqual(center.authRequests, 1)
    await notifier.post(note(peer))
    await notifier.post(note(peer, identifier: smsNotificationPrefix + "sms:2"))
    XCTAssertEqual(center.added.count, 2)
    XCTAssertEqual(center.authRequests, 1)
  }

  @MainActor func testDuplicateIdentifiersNeverPostTwice() async throws {
    let center = SpySmsNotificationCenter()
    let notifier = MacSmsNotifier(preferences: preferences(), center: center)
    let peer = phone()
    await notifier.post(note(peer))
    await notifier.post(note(peer, body: "changed"))
    XCTAssertEqual(center.added.count, 1)
    XCTAssertEqual(center.added[0].content.body, "New message")
    notifier.clear(identifier: smsNotificationPrefix + "sms:1")
    XCTAssertEqual(center.removedDelivered.last, [smsNotificationPrefix + "sms:1"])
    notifier.clearAll()
    await notifier.post(note(peer))
    XCTAssertEqual(center.added.count, 2)
  }

  @MainActor func testReplyActionRoutesClampedTextAndUnknownIdentifiersAreIgnored() async throws {
    let center = SpySmsNotificationCenter(), prefs = preferences(), peer = phone()
    let notifier = MacSmsNotifier(preferences: prefs, center: center)
    var replies: [SmsReplyRequest] = []
    var opened = 0
    notifier.onReply = { replies.append($0) }
    notifier.onOpenMessages = { opened += 1 }
    await notifier.post(note(peer))
    let identifier = smsNotificationPrefix + "sms:1"
    XCTAssertFalse(notifier.handleAction(category: "other", action: "ANICE_SMS_REPLY", identifier: identifier, userText: "no"))
    XCTAssertFalse(notifier.handleAction(category: "ANICE_SMS", action: "unrelated", identifier: identifier, userText: "no"))
    XCTAssertTrue(notifier.handleAction(category: "ANICE_SMS", action: "ANICE_SMS_REPLY", identifier: identifier, userText: "  "))
    XCTAssertTrue(replies.isEmpty)
    XCTAssertTrue(notifier.handleAction(category: "ANICE_SMS", action: "ANICE_SMS_REPLY", identifier: identifier, userText: "on my way"))
    XCTAssertEqual(replies.count, 1)
    XCTAssertEqual(replies[0].address, "+15551234567")
    XCTAssertEqual(replies[0].threadId, "sms:42")
    XCTAssertEqual(replies[0].peerKey, peer.deviceId + ":" + peer.fingerprint)
    XCTAssertEqual(replies[0].text, "on my way")
    XCTAssertTrue(notifier.handleAction(category: "ANICE_SMS", action: "ANICE_SMS_REPLY", identifier: smsNotificationPrefix + "unknown", userText: "hi"))
    XCTAssertEqual(replies.count, 1)
    XCTAssertTrue(notifier.handleAction(category: "ANICE_SMS", action: UNNotificationDefaultActionIdentifier, identifier: identifier))
    XCTAssertEqual(opened, 1)
    XCTAssertTrue(notifier.handleAction(category: "ANICE_SMS", action: UNNotificationDismissActionIdentifier, identifier: identifier))
    XCTAssertEqual(opened, 1)
  }

  @MainActor func testReplyTextClampsOnCodepointBoundaries() async throws {
    let center = SpySmsNotificationCenter(), prefs = preferences(), peer = phone()
    let notifier = MacSmsNotifier(preferences: prefs, center: center)
    var replies: [SmsReplyRequest] = []
    notifier.onReply = { replies.append($0) }
    await notifier.post(note(peer))
    let identifier = smsNotificationPrefix + "sms:1"
    _ = notifier.handleAction(category: "ANICE_SMS", action: "ANICE_SMS_REPLY", identifier: identifier, userText: String(repeating: "a", count: 30_000))
    XCTAssertEqual(replies[0].text.utf8.count, 24576)
    replies.removeAll()
    _ = notifier.handleAction(category: "ANICE_SMS", action: "ANICE_SMS_REPLY", identifier: identifier, userText: String(repeating: "😀", count: 7000))
    XCTAssertEqual(replies[0].text.utf8.count, 24576)
    XCTAssertEqual(replies[0].text, String(repeating: "😀", count: 6144))
    replies.removeAll()
    _ = notifier.handleAction(category: "ANICE_SMS", action: "ANICE_SMS_REPLY", identifier: identifier, userText: "a\u{0}b")
    XCTAssertEqual(replies[0].text, "a\u{FFFD}b")
  }

  @MainActor func testFailedReplyAlertCarriesOnlyTheAddress() async throws {
    let center = SpySmsNotificationCenter()
    let notifier = MacSmsNotifier(preferences: preferences(), center: center)
    let peer = phone()
    await notifier.post(SmsNotification(identifier: smsNotificationPrefix + "failed-1", peerKey: peer.deviceId + ":" + peer.fingerprint,
      peerName: peer.deviceName, address: "+15551234567", threadId: "sms:42",
      threadIdentifier: "+15551234567", body: "", failure: true))
    XCTAssertEqual(center.added.count, 1)
    XCTAssertEqual(center.added[0].content.title, "Reply not confirmed")
    XCTAssertEqual(center.added[0].content.body, "Message to +15551234567 was not confirmed; it may have been sent")
    XCTAssertEqual(center.added[0].content.categoryIdentifier, "ANICE_SMS")
  }

  @MainActor func testPerPhoneNotificationControlsMuteBannersAndSound() async throws {
    let center = SpySmsNotificationCenter(), prefs = preferences(), peer = phone()
    let notifier = MacSmsNotifier(preferences: prefs, center: center)
    // Defaults: delivery on and sound on, so the first banner carries the default sound.
    XCTAssertTrue(prefs.notifications(peer))
    XCTAssertTrue(prefs.sound(peer))
    await notifier.post(note(peer))
    XCTAssertEqual(center.added.count, 1)
    XCTAssertNotNil(center.added[0].content.sound)
    // Sound off keeps the banner but drops its sound.
    prefs.setSound(peer, false)
    XCTAssertTrue(prefs.notifications(peer))
    XCTAssertFalse(prefs.sound(peer))
    await notifier.post(note(peer, identifier: smsNotificationPrefix + "sms:2"))
    XCTAssertEqual(center.added.count, 2)
    XCTAssertNil(center.added[1].content.sound)
    // Notifications off posts nothing at all, and the sound control has no effect while it is off.
    prefs.setNotifications(peer, false)
    XCTAssertFalse(prefs.sound(peer))
    let muted = await notifier.post(note(peer, identifier: smsNotificationPrefix + "sms:3"))
    XCTAssertEqual(muted, .muted)
    let failure = SmsNotification(identifier: smsNotificationPrefix + "failed-9", peerKey: peer.deviceId + ":" + peer.fingerprint,
      peerName: peer.deviceName, address: "+15551234567", threadId: "sms:42", threadIdentifier: "+15551234567", body: "", failure: true)
    let mutedFailure = await notifier.post(failure)
    XCTAssertEqual(mutedFailure, .muted)
    XCTAssertEqual(center.added.count, 2)
    // Delivery back on resumes banners; the sound stays off until it is re-enabled.
    prefs.setNotifications(peer, true)
    XCTAssertFalse(prefs.sound(peer))
    let resumed = await notifier.post(note(peer, identifier: smsNotificationPrefix + "sms:3"))
    XCTAssertEqual(resumed, .submitted)
    XCTAssertNil(center.added.last?.content.sound)
    prefs.setSound(peer, true)
    XCTAssertTrue(prefs.sound(peer))
    // The controls are per phone and are pruned with the peer.
    let other = phone("Tablet")
    XCTAssertTrue(prefs.notifications(other))
    prefs.prune([other])
    XCTAssertTrue(prefs.notifications(peer))
    prefs.clear()
    XCTAssertTrue(prefs.notifications(peer))
    XCTAssertTrue(prefs.sound(peer))
  }

  @MainActor func testCategoryRegistersInlineReplyAndDefaultTap() {
    let category = MacSmsNotifier.notificationCategory
    XCTAssertEqual(category.identifier, "ANICE_SMS")
    let reply = category.actions.compactMap { $0 as? UNTextInputNotificationAction }
    XCTAssertEqual(reply.map(\.identifier), ["ANICE_SMS_REPLY"])
    XCTAssertTrue(category.options.contains(.customDismissAction))
    XCTAssertTrue(AppDelegate.notificationCategories.contains { $0.identifier == "ANICE_SMS" })
  }

  @MainActor func testDelegateRoutesSmsActionsIncludingTextInput() async throws {
    let center = SpySmsNotificationCenter()
    let notifier = MacSmsNotifier(preferences: preferences(), center: center)
    var replies: [SmsReplyRequest] = []
    notifier.onReply = { replies.append($0) }
    let peer = phone()
    await notifier.post(note(peer))
    let delegate = AppDelegate()
    delegate.configureNotifications(findDevice: MacFindDeviceNotifier(), transfer: MacTransferNotifier(model: MacTransferModel(), openMainWindow: {}), sms: notifier)
    delegate.handleNotificationAction(category: "ANICE_SMS", action: "ANICE_SMS_REPLY",
      identifier: smsNotificationPrefix + "sms:1", userText: "from the delegate")
    XCTAssertEqual(replies.count, 1)
    XCTAssertEqual(replies[0].text, "from the delegate")
    let categories = AppDelegate.notificationCategories
    XCTAssertEqual(Set(categories.map(\.identifier)), [MacFindDeviceNotifier.category, MacSmsNotifier.category,
      MacTransferNotifier.Category.offer, MacTransferNotifier.Category.result,
      MacTransferNotifier.Category.paused, MacTransferNotifier.Category.pausedSender])
    delegate.handleNotificationAction(category: "unknown", action: UNNotificationDefaultActionIdentifier, identifier: "unrelated")
    XCTAssertEqual(replies.count, 1)
  }
}
