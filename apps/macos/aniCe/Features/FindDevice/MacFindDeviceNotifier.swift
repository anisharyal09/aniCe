// SPDX-License-Identifier: GPL-3.0-or-later
// Submits localizable native Find Device notifications and routes identifier-bound dismissal.
import AppKit
import UserNotifications

@MainActor final class MacFindDeviceNotifier: NSObject, FindDeviceNotifying, UNUserNotificationCenterDelegate {
  nonisolated static let category = "ANICE_FIND_DEVICE"
  nonisolated static let dismissAction = "ANICE_FIND_DISMISS"
  var dismissed: (String) -> Void = { _ in }
  private let center: UNUserNotificationCenter
  private var setup: Task<Void, Never>?
  private var identifiers = Set<String>()
  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
    super.init()
    center.delegate = self
    setup = Task { [weak self] in
      guard let self else { return }
      let pending = await center.pendingNotificationRequests()
      center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("find-device-") })
      let old = await center.deliveredNotifications()
      center.removeDeliveredNotifications(withIdentifiers: old.map { $0.request.identifier }.filter { $0.hasPrefix("find-device-") })
      var categories = await center.notificationCategories()
      categories = categories.filter { $0.identifier != Self.category }
      categories.insert(UNNotificationCategory(identifier: Self.category,
        actions: [UNNotificationAction(identifier: Self.dismissAction, title: Self.text("find_dismiss"), options: [])],
        intentIdentifiers: [], options: [.customDismissAction]))
      center.setNotificationCategories(categories)
    }
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
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler(notification.request.content.categoryIdentifier == Self.category ? [.banner, .list, .sound] : [])
  }
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
    let id = response.notification.request.identifier, action = response.actionIdentifier
    Task { @MainActor [weak self] in
      defer { completionHandler() }
      self?.handleAction(action, identifier: id)
    }
  }
  func handleAction(_ action: String, identifier: String) {
    if action == Self.dismissAction || action == UNNotificationDismissActionIdentifier || action == UNNotificationDefaultActionIdentifier {
      dismissed(identifier)
    }
  }
}
