// SPDX-License-Identifier: GPL-3.0-or-later
// Submits localizable native Find Device notifications and routes identifier-bound dismissal.
import AppKit
import UserNotifications

@MainActor final class MacFindDeviceNotifier: NSObject, FindDeviceNotifying {
  nonisolated static let category = "ANICE_FIND_DEVICE"
  nonisolated static let dismissAction = "ANICE_FIND_DISMISS"
  var dismissed: (String) -> Void = { _ in }
  private let center: UNUserNotificationCenter
  private var setup: Task<Void, Never>?
  private var identifiers = Set<String>()
  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
    super.init()
    setup = Task { [weak self] in
      guard let self else { return }
      let pending = await center.pendingNotificationRequests()
      center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("find-device-") })
      let old = await center.deliveredNotifications()
      center.removeDeliveredNotifications(withIdentifiers: old.map { $0.request.identifier }.filter { $0.hasPrefix("find-device-") })
    }
  }
  static var notificationCategory: UNNotificationCategory {
    UNNotificationCategory(identifier: category,
      actions: [UNNotificationAction(identifier: dismissAction, title: text("find_dismiss"), options: [])],
      intentIdentifiers: [], options: [.customDismissAction])
  }
  static func text(_ key: String) -> String { NSLocalizedString(key, tableName: "FindDevice", bundle: .main, comment: "Find Device") }
  func requestPermission() async -> String {
    do { _ = try await center.requestAuthorization(options: [.alert, .sound]); return await localStatus() }
    catch { return "find_local_error" }
  }
  private static func permits(_ settings: UNNotificationSettings) -> Bool {
    (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional) &&
      (settings.alertSetting == .enabled || settings.notificationCenterSetting == .enabled)
  }
  func localStatus() async -> String {
    Self.permits(await center.notificationSettings()) ? "find_local_allowed" : "find_local_blocked"
  }
  func post(identifier: String, peerName: String) async -> FindResult {
    identifiers.insert(identifier)
    await setup?.value
    let settings = await center.notificationSettings()
    guard identifiers.contains(identifier) else { return .stale }
    guard Self.permits(settings) else { return .blocked }
    let content = UNMutableNotificationContent()
    content.title = Self.text("find_title")
    content.body = String(format: Self.text("find_notification_body"), peerName)
    content.categoryIdentifier = Self.category
    content.sound = .default
    do {
      try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
      if !identifiers.contains(identifier) { clear(identifier: identifier); return .stale }
      return .submitted
    } catch { return .failed }
  }
  func clear(identifier: String) {
    identifiers.remove(identifier)
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
  }
  func clearAll() { for identifier in Array(identifiers) { clear(identifier: identifier) } }
  func handleAction(_ action: String, identifier: String) {
    if action == Self.dismissAction || action == UNNotificationDismissActionIdentifier || action == UNNotificationDefaultActionIdentifier {
      dismissed(identifier)
    }
  }
}
