// SPDX-License-Identifier: GPL-3.0-or-later
// Delivers native SMS notifications with an inline reply and per-peer text preview control.
import AppKit
import Foundation
import UserNotifications

// Narrow seam over UNUserNotificationCenter so SMS delivery and startup cleanup are testable.
protocol SmsNotificationCenter: AnyObject {
  func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, Error?) -> Void)
  func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?)
  func deliveredIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void)
  func pendingIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void)
  func removeDeliveredNotifications(withIdentifiers identifiers: [String])
  func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: SmsNotificationCenter {
  func deliveredIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void) {
    getDeliveredNotifications { completionHandler($0.map(\.request.identifier)) }
  }
  func pendingIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void) {
    getPendingNotificationRequests { completionHandler($0.map(\.identifier)) }
  }
}

// Per-peer opt-in for message text in banners; bodies stay hidden until the user enables preview.
@MainActor final class SmsPreferences {
  private let storage: UserDefaults?
  private var values: [String: Bool]
  init(storage: UserDefaults? = nil) {
    self.storage = storage
    values = storage?.dictionary(forKey: "sms.preview") as? [String: Bool] ?? [:]
  }
  func key(_ peer: DeviceIdentity) -> String { peer.deviceId + ":" + peer.fingerprint }
  func preview(_ key: String) -> Bool { values[key] ?? false }
  func preview(_ peer: DeviceIdentity) -> Bool { preview(key(peer)) }
  func set(_ peer: DeviceIdentity, _ enabled: Bool) { values[key(peer)] = enabled; persist() }
  func prune(_ peers: [DeviceIdentity]) { let keep = Set(peers.map(key)); values = values.filter { keep.contains($0.key) }; persist() }
  func clear() { values.removeAll(); persist() }
  private func persist() { storage?.set(values, forKey: "sms.preview") }
}

@MainActor final class MacSmsNotifier: NSObject, SmsNotifying {
  nonisolated static let category = "ANICE_SMS"
  nonisolated static let replyAction = "ANICE_SMS_REPLY"
  var onReply: (SmsReplyRequest) -> Void = { _ in }
  var onOpenMessages: () -> Void = {}
  private struct Target {
    let peerKey: String
    let peerName: String
    let address: String
    let threadId: String
  }
  private let center: any SmsNotificationCenter
  private let preferences: SmsPreferences
  private var hasRequestedAuth = false
  private var identifiers = Set<String>()
  private var targets: [String: Target] = [:]

  init(preferences: SmsPreferences, center: any SmsNotificationCenter = UNUserNotificationCenter.current()) {
    self.preferences = preferences
    self.center = center
    super.init()
    // Startup leftovers are process-local artifacts of a previous run; they are cleared by their reserved prefix.
    center.pendingIdentifiers { [weak self] identifiers in
      let reserved = identifiers.filter { $0.hasPrefix(smsNotificationPrefix) }
      Task { @MainActor in self?.center.removePendingNotificationRequests(withIdentifiers: reserved) }
    }
    center.deliveredIdentifiers { [weak self] identifiers in
      let reserved = identifiers.filter { $0.hasPrefix(smsNotificationPrefix) }
      Task { @MainActor in self?.center.removeDeliveredNotifications(withIdentifiers: reserved) }
    }
  }

  // Inline reply plus the system default tap that opens the Messages panel.
  static var notificationCategory: UNNotificationCategory {
    UNNotificationCategory(identifier: category,
      actions: [UNTextInputNotificationAction(identifier: replyAction, title: "Reply", options: [],
        textInputButtonTitle: "Send", textInputPlaceholder: "Message")],
      intentIdentifiers: [], options: [.customDismissAction])
  }

  func post(_ note: SmsNotification) async {
    guard !identifiers.contains(note.identifier) else { return }
    requestAuthIfNeeded()
    let content = UNMutableNotificationContent()
    content.title = note.failure ? "Message not sent" : note.address
    content.body = note.failure
      ? "Message to \(note.address) failed to send"
      : preferences.preview(note.peerKey) ? note.body : "New message"
    content.categoryIdentifier = Self.category
    content.threadIdentifier = note.threadIdentifier
    content.sound = .default
    identifiers.insert(note.identifier)
    targets[note.identifier] = Target(peerKey: note.peerKey, peerName: note.peerName, address: note.address, threadId: note.threadId)
    center.add(UNNotificationRequest(identifier: note.identifier, content: content, trigger: nil)) { error in
      if let error { NSLog("SMS notification delivery failed: %@", error.localizedDescription) }
    }
  }

  // Reply text is clamped on codepoint boundaries; the composer enforces the same bound inline.
  func handleAction(category: String, action: String, identifier: String, userText: String = "") -> Bool {
    guard category == Self.category else { return false }
    switch action {
    case Self.replyAction:
      guard let target = targets[identifier] else { return true }
      let text = smsTruncate(smsSanitizeText(userText), maxBytes: Int(SmsMessage.maxBodyBytes))
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
      onReply(SmsReplyRequest(peerKey: target.peerKey, peerName: target.peerName, address: target.address, threadId: target.threadId, text: text))
      return true
    case UNNotificationDefaultActionIdentifier:
      onOpenMessages()
      return true
    case UNNotificationDismissActionIdentifier:
      return true
    default:
      return false
    }
  }

  func clear(identifier: String) {
    identifiers.remove(identifier)
    targets[identifier] = nil
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
  }

  func clearAll() { for identifier in Array(identifiers) { clear(identifier: identifier) } }

  private func requestAuthIfNeeded() {
    guard !hasRequestedAuth else { return }
    hasRequestedAuth = true
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }
}
