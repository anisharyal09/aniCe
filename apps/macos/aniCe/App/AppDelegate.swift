// SPDX-License-Identifier: GPL-3.0-or-later
// Retains companion presentation, notification delegation and the main-window reopening action.
import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // Retain the scene action after its view disappears so Dock reopening still works.
    var reopenMainWindow: (@MainActor () -> Void)?
    private var notifier: MacTransferNotifier?
    private var findNotifier: MacFindDeviceNotifier?
    private var smsNotifier: MacSmsNotifier?
    private var companion: CompanionHost?
    var onTerminate: () -> Void = {}
    func applicationWillTerminate(_ notification: Notification) { onTerminate() }

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func configureNotifications(findDevice: MacFindDeviceNotifier, transfer: MacTransferNotifier, sms: MacSmsNotifier? = nil) {
        findNotifier = findDevice
        notifier = transfer
        smsNotifier = sms
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.notificationCategories)
    }

    static var notificationCategories: Set<UNNotificationCategory> {
        MacTransferNotifier.notificationCategories().union([MacFindDeviceNotifier.notificationCategory, MacSmsNotifier.notificationCategory])
    }

    func handleNotificationAction(category: String, action: String, identifier: String, userText: String = "") {
        if category == MacFindDeviceNotifier.category {
            findNotifier?.handleAction(action, identifier: identifier)
        } else if category == MacSmsNotifier.category {
            _ = smsNotifier?.handleAction(category: category, action: action, identifier: identifier, userText: userText)
        } else if category == MacTransferNotifier.Category.offer || category == MacTransferNotifier.Category.result {
            notifier?.handleAction(action, identifier: identifier)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let category = notification.request.content.categoryIdentifier
        let known = category == MacFindDeviceNotifier.category || category == MacSmsNotifier.category ||
            category == MacTransferNotifier.Category.offer || category == MacTransferNotifier.Category.result
        completionHandler(known ? [.banner, .list, .sound] : [])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier, identifier = response.notification.request.identifier
        let userText = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            self?.handleNotificationAction(category: category, action: action, identifier: identifier, userText: userText)
        }
    }

    func openMainFromCompanion() {
        companion?.close()
        reopenMainWindow?()
    }

    func installCompanion(_ content: CompanionView, navigation: ConnectionNavigation) {
        guard companion == nil else { return }
        companion = CompanionHost(content: content, onOpen: { [weak self] in
            self?.openMainFromCompanion()
        }, onManage: { [weak self] in
            navigation.open(.devices, route: .pairing) { self?.openMainFromCompanion() }
        }, onDevices: { [weak self] in
            navigation.diagnostics = false
            navigation.open(.devices) { self?.openMainFromCompanion() }
        })
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        if !hasVisibleWindows {
            reopenMainWindow?()
        }
        return true
    }
}
