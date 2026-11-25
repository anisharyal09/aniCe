// SPDX-License-Identifier: GPL-3.0-or-later
// Delivers native SMS notifications with an inline reply and per-peer text preview control.
import AppKit
import CryptoKit
import Foundation
import Observation
import UserNotifications

// Narrow seam over UNUserNotificationCenter so SMS delivery and startup cleanup are testable.
protocol SmsNotificationCenter: AnyObject {
  func settings(completionHandler: @escaping @Sendable (SmsNotificationAccess) -> Void)
  func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, Error?) -> Void)
  func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?)
  func deliveredIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void)
  func pendingIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void)
  func removeDeliveredNotifications(withIdentifiers identifiers: [String])
  func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: SmsNotificationCenter {
  func settings(completionHandler: @escaping @Sendable (SmsNotificationAccess) -> Void) {
    getNotificationSettings { settings in
      if settings.authorizationStatus == .denied { completionHandler(.denied) }
      else if settings.authorizationStatus == .notDetermined { completionHandler(.notDetermined) }
      else if settings.alertSetting != .enabled || settings.alertStyle == .none { completionHandler(.alertsDisabled) }
      else { completionHandler(.authorized) }
    }
  }
  func deliveredIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void) {
    getDeliveredNotifications { completionHandler($0.map(\.request.identifier)) }
  }
  func pendingIdentifiers(completionHandler: @escaping @Sendable ([String]) -> Void) {
    getPendingNotificationRequests { completionHandler($0.map(\.identifier)) }
  }
}

// Per-peer delivery, sound and message-text preview; explicit opt-outs survive app updates.
@Observable @MainActor final class SmsPreferences {
  private let storage: UserDefaults?
  private var previews: [String: Bool]
  private var sounds: [String: Bool]
  private var delivery: [String: Bool]
  init(storage: UserDefaults? = nil) {
    self.storage = storage
    previews = storage?.dictionary(forKey: "sms.preview") as? [String: Bool] ?? [:]
    sounds = storage?.dictionary(forKey: "sms.sound") as? [String: Bool] ?? [:]
    delivery = storage?.dictionary(forKey: "sms.enabled") as? [String: Bool] ?? [:]
  }
  func key(_ peer: DeviceIdentity) -> String { peer.deviceId + ":" + peer.fingerprint }
  func preview(_ key: String) -> Bool { previews[key] ?? true }
  func preview(_ peer: DeviceIdentity) -> Bool { preview(key(peer)) }
  /** Notifications default to on; sound defaults to off and is muted with the notifications themselves. */
  func notifications(_ key: String) -> Bool { delivery[key] ?? true }
  func notifications(_ peer: DeviceIdentity) -> Bool { notifications(key(peer)) }
  func sound(_ key: String) -> Bool { notifications(key) && (sounds[key] ?? false) }
  func sound(_ peer: DeviceIdentity) -> Bool { sound(key(peer)) }
  func set(_ peer: DeviceIdentity, _ enabled: Bool) { previews[key(peer)] = enabled; persist() }
  func setNotifications(_ peer: DeviceIdentity, _ on: Bool) { delivery[key(peer)] = on; persist() }
  func setSound(_ peer: DeviceIdentity, _ on: Bool) { sounds[key(peer)] = on; persist() }
  func prune(_ peers: [DeviceIdentity]) {
    let keep = Set(peers.map(key))
    previews = previews.filter { keep.contains($0.key) }
    sounds = sounds.filter { keep.contains($0.key) }
    delivery = delivery.filter { keep.contains($0.key) }
    persist()
  }
  func clear() { previews.removeAll(); sounds.removeAll(); delivery.removeAll(); persist() }
  private func persist() {
    storage?.set(previews, forKey: "sms.preview")
    storage?.set(sounds, forKey: "sms.sound")
    storage?.set(delivery, forKey: "sms.enabled")
  }
}

@Observable @MainActor final class MacSmsNotifier: NSObject, SmsNotifying {
  nonisolated static let category = "ANICE_SMS"
  nonisolated static let resultCategory = "ANICE_SMS_RESULT"
  nonisolated static let replyAction = "ANICE_SMS_REPLY"
  var onReply: (SmsReplyRequest) -> Void = { _ in }
  var onOpenConversation: (SmsConversationTarget) -> Void = { _ in }
  private struct Target {
    let conversation: SmsConversationTarget
    let category: String
    let token: UUID
    var consumedActions = Set<String>()
  }
  private let center: any SmsNotificationCenter
  private let preferences: SmsPreferences
  private(set) var status = ""
  private var access: SmsNotificationAccess = .notDetermined
  private var startupCleanup: Task<Void, Never>?
  private var authorizationPending = false
  private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
  private var generations: [String: Int] = [:]
  private var inFlight: [String: UUID] = [:]
  private var completions: [String: CheckedContinuation<Bool, Never>] = [:]
  private var addTimeouts: [String: Task<Void, Never>] = [:]
  private var pendingPeers: [String: String] = [:]
  private var hasRequestedAuth = false
  private var identifiers: [String: String] = [:]
  private var targets: [String: Target] = [:]

  init(preferences: SmsPreferences, center: any SmsNotificationCenter = UNUserNotificationCenter.current()) {
    self.preferences = preferences
    self.center = center
    super.init()
    // Ask at launch so the first live message is never swallowed by the authorization prompt.
    requestAuthIfNeeded()
    Task { await refreshSettings() }
    // Finish the previous process's cleanup before admitting any new notification identifier.
    startupCleanup = Task { @MainActor in
      let pending = await withCheckedContinuation { continuation in
        center.pendingIdentifiers { continuation.resume(returning: $0) }
      }
      let delivered = await withCheckedContinuation { continuation in
        center.deliveredIdentifiers { continuation.resume(returning: $0) }
      }
      center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.hasPrefix(smsNotificationPrefix) })
      center.removeDeliveredNotifications(withIdentifiers: delivered.filter { $0.hasPrefix(smsNotificationPrefix) })
    }
  }

  // Inline reply plus the system default tap that opens the Messages panel.
  static var notificationCategory: UNNotificationCategory {
    UNNotificationCategory(identifier: category,
      actions: [UNTextInputNotificationAction(identifier: replyAction, title: "Reply", options: [],
        textInputButtonTitle: "Send", textInputPlaceholder: "Message")],
      intentIdentifiers: [], options: [.customDismissAction])
  }
  // An uncertain send offers review only, not another inline send action.
  static var resultNotificationCategory: UNNotificationCategory {
    UNNotificationCategory(identifier: resultCategory, actions: [], intentIdentifiers: [], options: [.customDismissAction])
  }

  func refreshSettings() async {
    let access = await withCheckedContinuation { continuation in
      center.settings { continuation.resume(returning: $0) }
    }
    self.access = access
    switch access {
    case .authorized: status = ""
    case .denied: status = "Notifications are turned off for aniCe in System Settings"
    case .alertsDisabled: status = "Notification alerts are disabled for aniCe in System Settings"
    case .notDetermined: status = "Allow notifications to receive SMS alerts"
    }
  }

  func clear(peerKey: String) {
    generations[peerKey, default: 0] += 1
    for identifier in identifiers.filter({ $0.value == peerKey }).map(\.key) { clear(identifier: identifier) }
    for identifier in pendingPeers.filter({ $0.value == peerKey }).map(\.key) { clear(identifier: identifier) }
  }

  func post(_ note: SmsNotification) async -> SmsPostOutcome {
    // A phone the user silenced posts nothing; the panel keeps its counts and the relay keeps running.
    guard preferences.notifications(note.peerKey) else { return .muted }
    guard identifiers[note.identifier] == nil else { return .duplicate }
    guard inFlight[note.identifier] == nil else { return .cancelled }
    let token = UUID(), generation = generations[note.peerKey, default: 0]
    inFlight[note.identifier] = token
    pendingPeers[note.identifier] = note.peerKey
    defer {
      if inFlight[note.identifier] == token {
        inFlight[note.identifier] = nil; pendingPeers[note.identifier] = nil
        addTimeouts.removeValue(forKey: note.identifier)?.cancel()
      }
    }
    await startupCleanup?.value
    requestAuthIfNeeded()
    if authorizationPending { await withCheckedContinuation { authorizationWaiters.append($0) } }
    await refreshSettings()
    guard generations[note.peerKey, default: 0] == generation, inFlight[note.identifier] == token else { return .cancelled }
    guard preferences.notifications(note.peerKey) else { return .muted }
    switch access {
    case .authorized: break
    case .denied: return .denied
    case .alertsDisabled: return .alertsDisabled
    case .notDetermined: return .failed
    }
    let content = UNMutableNotificationContent()
    content.title = note.failure ? "Reply not confirmed" : note.address
    content.subtitle = note.peerName
    content.body = note.failure
      ? "Message to \(note.address) was not confirmed; it may have been sent"
      : preferences.preview(note.peerKey) ? note.body : "New message"
    content.categoryIdentifier = note.failure ? Self.resultCategory : Self.category
    content.userInfo = ["anice.sms.token": token.uuidString.lowercased()]
    let group = Data((note.peerKey + "\u{0}" + note.threadIdentifier).utf8)
    content.threadIdentifier = "anice-sms-thread-" + SHA256.hash(data: group).map { String(format: "%02x", $0) }.joined()
    content.sound = preferences.sound(note.peerKey) ? .default : nil
    let accepted = await withCheckedContinuation { continuation in
      completions[note.identifier] = continuation
      center.add(UNNotificationRequest(identifier: note.identifier, content: content, trigger: nil)) { [weak self] error in
        let accepted = error == nil
        Task { @MainActor in
          guard let self else { return }
          if self.inFlight[note.identifier] == token {
            self.completions.removeValue(forKey: note.identifier)?.resume(returning: accepted)
          } else if accepted, self.inFlight[note.identifier] == nil, self.identifiers[note.identifier] == nil {
            self.center.removeDeliveredNotifications(withIdentifiers: [note.identifier])
            self.center.removePendingNotificationRequests(withIdentifiers: [note.identifier])
          }
        }
      }
      addTimeouts[note.identifier] = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        guard let self, self.inFlight[note.identifier] == token else { return }
        self.completions.removeValue(forKey: note.identifier)?.resume(returning: false)
      }
    }
    guard generations[note.peerKey, default: 0] == generation, inFlight[note.identifier] == token else { return .cancelled }
    guard preferences.notifications(note.peerKey) else {
      center.removeDeliveredNotifications(withIdentifiers: [note.identifier])
      center.removePendingNotificationRequests(withIdentifiers: [note.identifier])
      return .muted
    }
    guard accepted else { status = "macOS did not accept the SMS notification"; return .failed }
    identifiers[note.identifier] = note.peerKey
    targets[note.identifier] = Target(conversation: SmsConversationTarget(peerKey: note.peerKey,
      peerName: note.peerName, address: note.address, threadId: note.threadId), category: content.categoryIdentifier, token: token)
    return .submitted
  }

  // Oversized replies go to the existing composer without sending a truncated prefix.
  func handleAction(category: String, action: String, identifier: String, userText: String = "", sourceToken: String? = nil) -> Bool {
    guard category == Self.category || category == Self.resultCategory else { return false }
    guard var target = targets[identifier], target.category == category else { return true }
    guard target.token.uuidString.lowercased() == sourceToken else { return true }
    switch action {
    case Self.replyAction:
      guard category == Self.category else { return false }
      let text = smsSanitizeText(userText)
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
      guard target.consumedActions.insert(action).inserted else { return true }
      targets[identifier] = target
      let conversation = target.conversation
      onReply(SmsReplyRequest(peerKey: conversation.peerKey, peerName: conversation.peerName,
        address: conversation.address, threadId: conversation.threadId, text: text))
      if text.utf8.count > Int(SmsMessage.maxBodyBytes) { onOpenConversation(conversation) }
      return true
    case UNNotificationDefaultActionIdentifier:
      guard target.consumedActions.insert(action).inserted else { return true }
      targets[identifier] = target
      onOpenConversation(target.conversation)
      return true
    case UNNotificationDismissActionIdentifier:
      // Keep successful-submission deduplication while revoking the dismissed alert's action target.
      targets[identifier] = nil
      return true
    default:
      return false
    }
  }

  func clear(identifier: String) {
    inFlight[identifier] = nil
    pendingPeers[identifier] = nil
    completions.removeValue(forKey: identifier)?.resume(returning: false)
    addTimeouts.removeValue(forKey: identifier)?.cancel()
    identifiers[identifier] = nil
    targets[identifier] = nil
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
  }

  func clearAll() { for identifier in Set(identifiers.keys).union(inFlight.keys) { clear(identifier: identifier) } }

  private func requestAuthIfNeeded() {
    guard !hasRequestedAuth else { return }
    hasRequestedAuth = true
    authorizationPending = true
    center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
      Task { @MainActor in
        guard let self else { return }
        self.authorizationPending = false
        let waiting = self.authorizationWaiters; self.authorizationWaiters.removeAll()
        waiting.forEach { $0.resume() }
        await self.refreshSettings()
      }
    }
  }
}
