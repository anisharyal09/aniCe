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
    private var floatingKeyboard: FloatingKeyboardController?
    private var mainWindowRestoreTask: Task<Void, Never>?
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
        } else if category == MacTransferNotifier.Category.offer || category == MacTransferNotifier.Category.result ||
            category == MacTransferNotifier.Category.paused || category == MacTransferNotifier.Category.pausedSender {
            notifier?.handleAction(action, identifier: identifier)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let category = notification.request.content.categoryIdentifier
        let known = category == MacFindDeviceNotifier.category || category == MacSmsNotifier.category ||
            category == MacTransferNotifier.Category.offer || category == MacTransferNotifier.Category.result ||
            category == MacTransferNotifier.Category.paused || category == MacTransferNotifier.Category.pausedSender
        guard known else { completionHandler([]); return }
        // Sound is chosen by the feature's saved preference, including silent updates to paused actions.
        var presentation: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil { presentation.insert(.sound) }
        completionHandler(presentation)
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
        restoreMainWindow()
    }

    func installCompanion(_ content: CompanionView, navigation: ConnectionNavigation,
        floatingKeyboard: FloatingKeyboardController) {
        guard companion == nil else { return }
        self.floatingKeyboard = floatingKeyboard
        floatingKeyboard.onOpenApp = { [weak self, weak navigation] in
            navigation?.openFeature(.keyboardTrackpad)
            self?.openMainFromCompanion()
        }
        floatingKeyboard.onOpenDevices = { [weak self, weak navigation, weak floatingKeyboard] in
            guard let self, let navigation else { return }
            floatingKeyboard?.collapse()
            navigation.open(.devices, present: { [weak self] in self?.openMainFromCompanion() })
        }
        companion = CompanionHost(content: content, floatingKeyboard: floatingKeyboard, onOpen: { [weak self] in
            self?.openMainFromCompanion()
        }, onManage: { [weak self] in
            navigation.diagnostics = false
            navigation.open(.devices) { self?.openMainFromCompanion() }
        })
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !hasVisibleMainWindow else { return }
        restoreMainWindow()
    }

    // Dock reopen can arrive while only the menu companion or a floating tool is visible.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows _: Bool
    ) -> Bool {
        guard reopenMainWindow != nil else { return false }
        restoreMainWindow()
        return true
    }

    private func restoreMainWindow() {
        guard mainWindowRestoreTask == nil, let reopenMainWindow else { return }
        reopenMainWindow()
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI may create the scene window on a later run-loop turn.
        mainWindowRestoreTask = Task { @MainActor [weak self] in
            for _ in 0..<10 {
                guard let self else { return }
                if let window = NSApp.windows.first(where: {
                    $0.identifier?.rawValue == "main" || $0.title == "aniCe"
                }) {
                    if window.isMiniaturized { window.deminiaturize(nil) }
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    self.mainWindowRestoreTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.mainWindowRestoreTask = nil
        }
    }

    private var hasVisibleMainWindow: Bool {
        NSApp.windows.contains {
            $0.isVisible && ($0.identifier?.rawValue == "main" || $0.title == "aniCe")
        }
    }
}
