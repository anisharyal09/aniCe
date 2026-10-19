// SPDX-License-Identifier: GPL-3.0-or-later
// Delivers native SMS notifications with an inline reply and per-peer text preview control.
import AppKit
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

// Per-peer opt-in for message text in banners; bodies stay hidden until the user enables preview.
@Observable @MainActor final class SmsPreferences {
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

@Observable @MainActor final class MacSmsNotifier: NSObject, SmsNotifying {
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
  private(set) var status = ""
  private var access: SmsNotificationAccess = .notDetermined
  private var startupCleanup: Task<Void, Never>?
  private var authorizationPending = false
  private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
  private var generations: [String: Int] = [:]
  private var inFlight: [String: UUID] = [:]
  private var completions: [String: CheckedContinuation<Bool, Never>] = [:]
  private var pendingPeers: [String: String] = [:]
  private var hasRequestedAuth = false
  private var identifiers = Set<String>()
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
    for (identifier, target) in targets where target.peerKey == peerKey { clear(identifier: identifier) }
    for identifier in pendingPeers.filter({ $0.value == peerKey }).map(\.key) { clear(identifier: identifier) }
  }

  func post(_ note: SmsNotification) async -> SmsPostOutcome {
    guard !identifiers.contains(note.identifier) else { return .duplicate }
    guard inFlight[note.identifier] == nil else { return .cancelled }
    let token = UUID(), generation = generations[note.peerKey, default: 0]
    inFlight[note.identifier] = token
    pendingPeers[note.identifier] = note.peerKey
    defer {
      if inFlight[note.identifier] == token { inFlight[note.identifier] = nil; pendingPeers[note.identifier] = nil }
    }
    await startupCleanup?.value
    requestAuthIfNeeded()
    if authorizationPending { await withCheckedContinuation { authorizationWaiters.append($0) } }
    await refreshSettings()
    guard generations[note.peerKey, default: 0] == generation, inFlight[note.identifier] == token else { return .cancelled }
    switch access {
    case .authorized: break
    case .denied: return .denied
    case .alertsDisabled: return .alertsDisabled
    case .notDetermined: return .failed
    }
    let content = UNMutableNotificationContent()
    content.title = note.failure ? "Reply not confirmed" : note.address
    content.body = note.failure
      ? "Message to \(note.address) was not confirmed; it may have been sent"
      : preferences.preview(note.peerKey) ? note.body : "New message"
    content.categoryIdentifier = Self.category
    content.threadIdentifier = note.threadIdentifier
    content.sound = .default
    let accepted = await withCheckedContinuation { continuation in
      completions[note.identifier] = continuation
      center.add(UNNotificationRequest(identifier: note.identifier, content: content, trigger: nil)) { [weak self] error in
        let accepted = error == nil
        Task { @MainActor in
          guard let self else { return }
          if self.inFlight[note.identifier] == token {
            self.completions.removeValue(forKey: note.identifier)?.resume(returning: accepted)
          } else if accepted {
            self.center.removeDeliveredNotifications(withIdentifiers: [note.identifier])
            self.center.removePendingNotificationRequests(withIdentifiers: [note.identifier])
          }
        }
      }
      Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        guard let self, self.inFlight[note.identifier] == token else { return }
        self.completions.removeValue(forKey: note.identifier)?.resume(returning: false)
      }
    }
    guard generations[note.peerKey, default: 0] == generation, inFlight[note.identifier] == token else { return .cancelled }
    guard accepted else { status = "macOS did not accept the SMS notification"; return .failed }
    identifiers.insert(note.identifier)
    targets[note.identifier] = Target(peerKey: note.peerKey, peerName: note.peerName, address: note.address, threadId: note.threadId)
    return .submitted
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
    inFlight[identifier] = nil
    pendingPeers[identifier] = nil
    completions.removeValue(forKey: identifier)?.resume(returning: false)
    identifiers.remove(identifier)
    targets[identifier] = nil
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
  }

  func clearAll() { for identifier in Set(identifiers).union(inFlight.keys) { clear(identifier: identifier) } }

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
