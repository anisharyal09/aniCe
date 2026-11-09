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
    private var notificationMirrorNotifier: MacNotificationMirrorNotifier?
    private var iconAppearanceObservation: NSKeyValueObservation?
    private var companion: CompanionHost?
    private var floatingKeyboard: FloatingKeyboardController?
    var onTerminate: () -> Void = {}
    func applicationWillTerminate(_ notification: Notification) { onTerminate() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        updateDockIcon()
        iconAppearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateDockIcon() }
        }
    }

    private func updateDockIcon() {
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let icon = NSImage(named: "DockIcon") else {
                NSLog("aniCe: DockIcon asset is missing from the app bundle")
                return
            }
            NSApp.applicationIconImage = icon
        }
    }

    func configureNotifications(findDevice: MacFindDeviceNotifier, transfer: MacTransferNotifier, sms: MacSmsNotifier? = nil,
        notificationMirror: MacNotificationMirrorNotifier? = nil) {
        findNotifier = findDevice
        notifier = transfer
        smsNotifier = sms
        notificationMirrorNotifier = notificationMirror
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.notificationCategories)
    }

    static var notificationCategories: Set<UNNotificationCategory> {
        MacTransferNotifier.notificationCategories().union([MacFindDeviceNotifier.notificationCategory, MacSmsNotifier.notificationCategory])
    }

    func handleNotificationAction(category: String, action: String, identifier: String, userText: String = "",
        mirrorEpoch: String? = nil, mirrorSequence: Int64? = nil) {
        if category == MacFindDeviceNotifier.category {
            findNotifier?.handleAction(action, identifier: identifier)
        } else if category == MacSmsNotifier.category {
            _ = smsNotifier?.handleAction(category: category, action: action, identifier: identifier, userText: userText)
        } else if category.hasPrefix(MacNotificationMirrorNotifier.categoryPrefix) {
            _ = notificationMirrorNotifier?.handleAction(category: category, action: action, identifier: identifier,
                userText: userText, sourceEpoch: mirrorEpoch, sourceSequence: mirrorSequence)
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
            category == MacTransferNotifier.Category.paused || category == MacTransferNotifier.Category.pausedSender ||
            category.hasPrefix(MacNotificationMirrorNotifier.categoryPrefix)
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
        let userInfo = response.notification.request.content.userInfo
        let mirrorEpoch = userInfo["anice.mirror.epoch"] as? String
        let mirrorSequence = (userInfo["anice.mirror.sequence"] as? NSNumber)?.int64Value
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            self?.handleNotificationAction(category: category, action: action, identifier: identifier,
                userText: userText, mirrorEpoch: mirrorEpoch, mirrorSequence: mirrorSequence)
        }
    }

    func openMainFromCompanion() {
        companion?.close()
        reopenMainWindow?()
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

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        if !hasVisibleWindows {
            reopenMainWindow?()
        }
        return true
    }
}
