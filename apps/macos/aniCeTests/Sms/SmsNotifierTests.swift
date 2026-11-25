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
  var holdAdd = false
  var pendingAdds: [(@Sendable (Error?) -> Void)] = []
  func settings(completionHandler: @escaping @Sendable (SmsNotificationAccess) -> Void) { completionHandler(access) }
  func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, Error?) -> Void) {
    authRequests += 1
    completionHandler(true, nil)
  }
  func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
    added.append(request)
    if holdAdd, let completionHandler { pendingAdds.append(completionHandler) }
    else { completionHandler?(error) }
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
    identifier: String? = nil) -> SmsNotification {
    let key = peer.deviceId + ":" + peer.fingerprint
    return SmsNotification(identifier: identifier ?? smsNotificationIdentifier(peerKey: key, messageId: "sms:1"), peerKey: key,
      peerName: peer.deviceName, address: address, threadId: "sms:42",
      threadIdentifier: smsNormalizedAddress(address), body: body, failure: false)
  }

  private func action(_ notifier: MacSmsNotifier, _ center: SpySmsNotificationCenter,
    category: String, action: String, identifier: String, userText: String = "") -> Bool {
    notifier.handleAction(category: category, action: action, identifier: identifier, userText: userText,
      sourceToken: center.added.last { $0.identifier == identifier }?.content.userInfo["anice.sms.token"] as? String)
  }

  @MainActor func testNotificationContentShowsBodyByDefaultAndRespectsPeerPreviewOptOut() async throws {
    let center = SpySmsNotificationCenter(), prefs = preferences(), peer = phone()
    let notifier = MacSmsNotifier(preferences: prefs, center: center)
    await notifier.post(note(peer, body: "Dinner at 8?"))
    XCTAssertEqual(center.added.count, 1)
    XCTAssertEqual(center.added[0].content.categoryIdentifier, "ANICE_SMS")
    XCTAssertEqual(center.added[0].content.body, "Dinner at 8?")
    XCTAssertEqual(center.added[0].content.title, "+15551234567")
    XCTAssertEqual(center.added[0].content.subtitle, "Pixel 9")
    XCTAssertTrue(center.added[0].content.threadIdentifier.hasPrefix("anice-sms-thread-"))
    XCTAssertFalse(center.added[0].content.threadIdentifier.contains("+15551234567"))
    XCTAssertEqual(center.authRequests, 1)
    try exportNotificationReview(center.added[0], category: MacSmsNotifier.notificationCategory, name: "sms-live")
    prefs.set(peer, false)
    await notifier.post(note(peer, body: "Secret", identifier: smsNotificationPrefix + "sms:2"))
    XCTAssertEqual(center.added[1].content.body, "New message")
    // Preview is per peer: another phone stays at default true.
    let other = phone("Tablet")
    XCTAssertTrue(prefs.preview(other))
    XCTAssertFalse(prefs.preview(peer))
    prefs.prune([other])
    XCTAssertTrue(prefs.preview(peer))
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
    XCTAssertEqual(center.added[0].content.body, "Dinner at 8?")
    notifier.clear(identifier: note(peer).identifier)
    XCTAssertEqual(center.removedDelivered.last, [note(peer).identifier])
    notifier.clearAll()
    await notifier.post(note(peer))
    XCTAssertEqual(center.added.count, 2)
  }

  @MainActor func testReplyActionRoutesTextAndUnknownIdentifiersAreIgnored() async throws {
    let center = SpySmsNotificationCenter(), prefs = preferences(), peer = phone()
    let notifier = MacSmsNotifier(preferences: prefs, center: center)
    var replies: [SmsReplyRequest] = []
    var opened = 0
    notifier.onReply = { replies.append($0) }
    var openedTargets: [SmsConversationTarget] = []
    notifier.onOpenConversation = { opened += 1; openedTargets.append($0) }
    await notifier.post(note(peer))
    let identifier = note(peer).identifier
    XCTAssertFalse(action(notifier, center, category: "other", action: "ANICE_SMS_REPLY", identifier: identifier, userText: "no"))
    XCTAssertFalse(action(notifier, center, category: "ANICE_SMS", action: "unrelated", identifier: identifier, userText: "no"))
    XCTAssertTrue(action(notifier, center, category: "ANICE_SMS", action: "ANICE_SMS_REPLY", identifier: identifier, userText: "  "))
    XCTAssertTrue(replies.isEmpty)
    XCTAssertTrue(action(notifier, center, category: "ANICE_SMS", action: "ANICE_SMS_REPLY", identifier: identifier, userText: "on my way"))
    XCTAssertEqual(replies.count, 1)
    XCTAssertEqual(replies[0].address, "+15551234567")
    XCTAssertEqual(replies[0].threadId, "sms:42")
    XCTAssertEqual(replies[0].peerKey, peer.deviceId + ":" + peer.fingerprint)
    XCTAssertEqual(replies[0].text, "on my way")
    XCTAssertTrue(notifier.handleAction(category: "ANICE_SMS", action: "ANICE_SMS_REPLY", identifier: smsNotificationPrefix + "unknown", userText: "hi"))
    XCTAssertEqual(replies.count, 1)
    XCTAssertTrue(action(notifier, center, category: "ANICE_SMS", action: UNNotificationDefaultActionIdentifier, identifier: identifier))
    XCTAssertEqual(opened, 1)
    XCTAssertEqual(openedTargets.map(\.peerKey), [prefs.key(peer)])
    XCTAssertEqual(openedTargets.map(\.address), ["+15551234567"])
    XCTAssertTrue(action(notifier, center, category: "ANICE_SMS", action: UNNotificationDismissActionIdentifier, identifier: identifier))
    XCTAssertEqual(opened, 1)
  }

  @MainActor func testOversizedReplyPreservesTextAndOpensMessagesForReview() async throws {
    let center = SpySmsNotificationCenter(), prefs = preferences(), peer = phone()
    let notifier = MacSmsNotifier(preferences: prefs, center: center)
    var replies: [SmsReplyRequest] = []
    var opened = 0
    notifier.onReply = { replies.append($0) }
    notifier.onOpenConversation = { _ in opened += 1 }
    let identifier = note(peer).identifier
    for (index, text) in [String(repeating: "a", count: 24577), String(repeating: "😀", count: 6145)].enumerated() {
      let identifier = identifier + "-\(index)"
      await notifier.post(note(peer, identifier: identifier))
      _ = action(notifier, center, category: "ANICE_SMS", action: "ANICE_SMS_REPLY", identifier: identifier, userText: text)
      XCTAssertEqual(replies.last?.text, text)
    }
    XCTAssertEqual(opened, 2)
    let maximum = String(repeating: "😀", count: 6144)
    await notifier.post(note(peer, identifier: identifier + "-maximum"))
    _ = action(notifier, center, category: "ANICE_SMS", action: "ANICE_SMS_REPLY", identifier: identifier + "-maximum", userText: maximum)
    XCTAssertEqual(replies.last?.text, maximum)
    XCTAssertEqual(opened, 2)
    await notifier.post(note(peer, identifier: identifier + "-sanitized"))
    _ = action(notifier, center, category: "ANICE_SMS", action: "ANICE_SMS_REPLY", identifier: identifier + "-sanitized", userText: "a\u{0}b")
    XCTAssertEqual(replies.last?.text, "a\u{FFFD}b")
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
    XCTAssertEqual(center.added[0].content.categoryIdentifier, MacSmsNotifier.resultCategory)
    XCTAssertTrue(MacSmsNotifier.resultNotificationCategory.actions.isEmpty)
    try exportNotificationReview(center.added[0], category: MacSmsNotifier.resultNotificationCategory, name: "sms-result")
  }

  @MainActor func testPerPhoneNotificationControlsMuteBannersAndSound() async throws {
    let center = SpySmsNotificationCenter(), prefs = preferences(), peer = phone()
    let notifier = MacSmsNotifier(preferences: prefs, center: center)
    // Defaults: delivery on and sound off.
    XCTAssertTrue(prefs.notifications(peer))
    XCTAssertFalse(prefs.sound(peer))
    await notifier.post(note(peer))
    XCTAssertEqual(center.added.count, 1)
    XCTAssertNil(center.added[0].content.sound)
    // Sound on keeps the banner and adds its sound.
    prefs.setSound(peer, true)
    XCTAssertTrue(prefs.notifications(peer))
    XCTAssertTrue(prefs.sound(peer))
    await notifier.post(note(peer, identifier: smsNotificationPrefix + "sms:2"))
    XCTAssertEqual(center.added.count, 2)
    XCTAssertNotNil(center.added[1].content.sound)
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
    // Delivery back on resumes banners; sound remains on as configured.
    prefs.setNotifications(peer, true)
    XCTAssertTrue(prefs.sound(peer))
    let resumed = await notifier.post(note(peer, identifier: smsNotificationPrefix + "sms:3"))
    XCTAssertEqual(resumed, .submitted)
    XCTAssertNotNil(center.added.last?.content.sound)
    prefs.setSound(peer, false)
    XCTAssertFalse(prefs.sound(peer))
    // The controls are per phone and are pruned with the peer.
    let other = phone("Tablet")
    XCTAssertTrue(prefs.notifications(other))
    prefs.prune([other])
    XCTAssertTrue(prefs.notifications(peer))
    prefs.clear()
    XCTAssertTrue(prefs.notifications(peer))
    XCTAssertFalse(prefs.sound(peer))
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
      identifier: note(peer).identifier, userText: "from the delegate",
      smsToken: center.added.last?.content.userInfo["anice.sms.token"] as? String)
    XCTAssertEqual(replies.count, 1)
    XCTAssertEqual(replies[0].text, "from the delegate")
    let categories = AppDelegate.notificationCategories
    XCTAssertEqual(Set(categories.map(\.identifier)), [MacFindDeviceNotifier.category, MacSmsNotifier.category, MacSmsNotifier.resultCategory,
      MacUpdateModel.notificationCategory, MacTransferNotifier.Category.offer, MacTransferNotifier.Category.result,
      MacTransferNotifier.Category.paused, MacTransferNotifier.Category.pausedSender])
    delegate.handleNotificationAction(category: "unknown", action: UNNotificationDefaultActionIdentifier, identifier: "unrelated")
    XCTAssertEqual(replies.count, 1)
  }

  func testReplyAndOpenAreEachOneShotAndDismissalKeepsSuccessfulDeduplication() async {
    let center = SpySmsNotificationCenter(), prefs = preferences(), peer = phone()
    let notifier = MacSmsNotifier(preferences: prefs, center: center)
    var replies: [SmsReplyRequest] = []
    var opens: [SmsConversationTarget] = []
    notifier.onReply = { replies.append($0) }
    notifier.onOpenConversation = { opens.append($0) }
    let note = note(peer)
    _ = await notifier.post(note)
    for _ in 0..<3 {
      _ = action(notifier, center, category: MacSmsNotifier.category, action: MacSmsNotifier.replyAction,
        identifier: note.identifier, userText: "Thanks")
      _ = action(notifier, center, category: MacSmsNotifier.category, action: UNNotificationDefaultActionIdentifier,
        identifier: note.identifier)
    }
    XCTAssertEqual(replies.count, 1)
    XCTAssertEqual(opens.count, 1)
    _ = action(notifier, center, category: MacSmsNotifier.category, action: UNNotificationDismissActionIdentifier, identifier: note.identifier)
    _ = action(notifier, center, category: MacSmsNotifier.category, action: MacSmsNotifier.replyAction,
      identifier: note.identifier, userText: "Late")
    _ = action(notifier, center, category: MacSmsNotifier.category, action: UNNotificationDefaultActionIdentifier, identifier: note.identifier)
    XCTAssertEqual(replies.count, 1)
    XCTAssertEqual(opens.count, 1)
    let repeated = await notifier.post(note)
    XCTAssertEqual(repeated, .duplicate)
    notifier.clear(peerKey: prefs.key(peer))
    XCTAssertEqual(center.removedDelivered.last, [note.identifier])
  }

  func testSameSenderOnTwoPhonesUsesDistinctIdentifiersAndNativeGroups() async throws {
    let center = SpySmsNotificationCenter(), prefs = preferences(), first = phone(), second = phone("Other phone")
    let notifier = MacSmsNotifier(preferences: prefs, center: center)
    _ = await notifier.post(note(first))
    _ = await notifier.post(note(second))
    XCTAssertEqual(center.added.count, 2)
    XCTAssertNotEqual(center.added[0].identifier, center.added[1].identifier)
    XCTAssertNotEqual(center.added[0].content.threadIdentifier, center.added[1].content.threadIdentifier)
    var opened: [SmsConversationTarget] = []
    notifier.onOpenConversation = { opened.append($0) }
    notifier.clear(peerKey: prefs.key(first))
    _ = action(notifier, center, category: MacSmsNotifier.category, action: UNNotificationDefaultActionIdentifier,
      identifier: center.added[0].identifier)
    _ = action(notifier, center, category: MacSmsNotifier.category, action: UNNotificationDefaultActionIdentifier,
      identifier: center.added[1].identifier)
    XCTAssertEqual(opened.map(\.peerKey), [prefs.key(second)])
  }

  func testUncertainReplyAlertCanOnlyOpenItsOriginalConversation() async {
    let center = SpySmsNotificationCenter(), prefs = preferences(), peer = phone()
    let notifier = MacSmsNotifier(preferences: prefs, center: center)
    var replies = 0
    var opens: [SmsConversationTarget] = []
    notifier.onReply = { _ in replies += 1 }
    notifier.onOpenConversation = { opens.append($0) }
    let failure = SmsNotification(identifier: smsNotificationPrefix + "failure", peerKey: prefs.key(peer),
      peerName: peer.deviceName, address: "+15550001111", threadId: "42", threadIdentifier: "+15550001111", body: "", failure: true)
    _ = await notifier.post(failure)
    XCTAssertFalse(action(notifier, center, category: MacSmsNotifier.resultCategory, action: MacSmsNotifier.replyAction,
      identifier: failure.identifier, userText: "Don't repeat"))
    _ = action(notifier, center, category: MacSmsNotifier.resultCategory, action: UNNotificationDefaultActionIdentifier,
      identifier: failure.identifier)
    XCTAssertEqual(replies, 0)
    XCTAssertEqual(opens.map(\.address), ["+15550001111"])
  }

  func testLateNativeAddCannotRestoreRetiredAlertOrEraseAReplacement() async {
    let center = SpySmsNotificationCenter(), prefs = preferences(), peer = phone()
    center.holdAdd = true
    let notifier = MacSmsNotifier(preferences: prefs, center: center)
    let note = note(peer)
    let first = Task { await notifier.post(note) }
    await until("first add") { center.pendingAdds.count == 1 }
    notifier.clear(peerKey: prefs.key(peer))
    let firstOutcome = await first.value
    XCTAssertEqual(firstOutcome, .cancelled)
    let second = Task { await notifier.post(note) }
    await until("replacement add") { center.pendingAdds.count == 2 }
    center.pendingAdds[1](nil)
    let secondOutcome = await second.value
    XCTAssertEqual(secondOutcome, .submitted)
    let before = center.removedDelivered.count
    center.pendingAdds[0](nil)
    for _ in 0..<8 { await Task.yield() }
    XCTAssertEqual(center.removedDelivered.count, before)
    var opened = 0
    notifier.onOpenConversation = { _ in opened += 1 }
    _ = action(notifier, center, category: MacSmsNotifier.category, action: UNNotificationDefaultActionIdentifier, identifier: note.identifier)
    XCTAssertEqual(opened, 1)
  }

  func testNotificationOptOutDuringNativeSubmissionRemovesItsActionTarget() async {
    let center = SpySmsNotificationCenter(), prefs = preferences(), peer = phone()
    center.holdAdd = true
    let notifier = MacSmsNotifier(preferences: prefs, center: center)
    let note = note(peer)
    let work = Task { await notifier.post(note) }
    await until("pending add") { center.pendingAdds.count == 1 }
    prefs.setNotifications(peer, false)
    center.pendingAdds[0](nil)
    let outcome = await work.value
    XCTAssertEqual(outcome, .muted)
    XCTAssertTrue(center.removedDelivered.flatMap { $0 }.contains(note.identifier))
    var opened = 0
    notifier.onOpenConversation = { _ in opened += 1 }
    _ = action(notifier, center, category: MacSmsNotifier.category, action: UNNotificationDefaultActionIdentifier, identifier: note.identifier)
    XCTAssertEqual(opened, 0)
  }

  func testAnObsoleteNativeTokenCannotReplyToAReusedNotificationIdentifier() async {
    let center = SpySmsNotificationCenter(), peer = phone()
    let notifier = MacSmsNotifier(preferences: preferences(), center: center)
    let note = note(peer)
    _ = await notifier.post(note)
    let obsolete = center.added.last?.content.userInfo["anice.sms.token"] as? String
    notifier.clear(identifier: note.identifier)
    _ = await notifier.post(note)
    var replies = 0
    notifier.onReply = { _ in replies += 1 }
    _ = notifier.handleAction(category: MacSmsNotifier.category, action: MacSmsNotifier.replyAction,
      identifier: note.identifier, userText: "Old callback", sourceToken: obsolete)
    XCTAssertEqual(replies, 0)
    _ = action(notifier, center, category: MacSmsNotifier.category, action: MacSmsNotifier.replyAction,
      identifier: note.identifier, userText: "Current callback")
    XCTAssertEqual(replies, 1)
  }
}

/// Private, opt-in native preview evidence made only from disposable fixture content.
@MainActor func exportNotificationReview(_ request: UNNotificationRequest, category: UNNotificationCategory, name: String) throws {
  guard let path = ProcessInfo.processInfo.environment["ANICE_REVIEW_RENDER_DIR"] else { return }
  let directory = URL(fileURLWithPath: path, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try NSKeyedArchiver.archivedData(withRootObject: request, requiringSecureCoding: true)
    .write(to: directory.appendingPathComponent(name + ".request"))
  try NSKeyedArchiver.archivedData(withRootObject: category, requiringSecureCoding: true)
    .write(to: directory.appendingPathComponent(name + ".category"))
}
