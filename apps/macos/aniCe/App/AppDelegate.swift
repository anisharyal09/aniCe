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
    private var updateModel: MacUpdateModel = .shared
    private var iconAppearanceObservation: NSKeyValueObservation?
    private var companion: CompanionHost?
    private var floatingKeyboard: FloatingKeyboardController?
    private var mainWindowRestoreTask: Task<Void, Never>?
    var onPrepareTerminate: () -> Void = {}
    var onTerminate: () -> Void = {}
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        onPrepareTerminate()
        return .terminateNow
    }
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
        notificationMirror: MacNotificationMirrorNotifier? = nil, updates: MacUpdateModel = .shared) {
        findNotifier = findDevice
        notifier = transfer
        smsNotifier = sms
        notificationMirrorNotifier = notificationMirror
        updateModel = updates
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.notificationCategories)
    }

    static var notificationCategories: Set<UNNotificationCategory> {
        MacTransferNotifier.notificationCategories().union([MacFindDeviceNotifier.notificationCategory,
            MacSmsNotifier.notificationCategory, MacSmsNotifier.resultNotificationCategory,
            UNNotificationCategory(identifier: MacUpdateModel.notificationCategory, actions: [], intentIdentifiers: [])])
    }

    func handleNotificationAction(category: String, action: String, identifier: String, userText: String = "",
        mirrorEpoch: String? = nil, mirrorSequence: Int64? = nil, transferToken: String? = nil, smsToken: String? = nil,
        updateTag: String? = nil) {
        if category == MacUpdateModel.notificationCategory {
            if action == UNNotificationDefaultActionIdentifier,
                updateModel.review(expectedTag: updateTag) {
                openMainFromCompanion()
            }
        } else if category == MacFindDeviceNotifier.category {
            findNotifier?.handleAction(action, identifier: identifier)
        } else if category == MacSmsNotifier.category || category == MacSmsNotifier.resultCategory {
            _ = smsNotifier?.handleAction(category: category, action: action, identifier: identifier, userText: userText,
                sourceToken: smsToken)
        } else if category.hasPrefix(MacNotificationMirrorNotifier.categoryPrefix) {
            _ = notificationMirrorNotifier?.handleAction(category: category, action: action, identifier: identifier,
                userText: userText, sourceEpoch: mirrorEpoch, sourceSequence: mirrorSequence)
        } else if category == MacTransferNotifier.Category.offer || category == MacTransferNotifier.Category.result ||
            category == MacTransferNotifier.Category.paused || category == MacTransferNotifier.Category.pausedSender {
            notifier?.handleAction(action, identifier: identifier, category: category, sourceToken: transferToken)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.presentationOptions(for: notification.request.content))
    }

    nonisolated static func presentationOptions(for content: UNNotificationContent) -> UNNotificationPresentationOptions {
        let category = content.categoryIdentifier
        let known = category == MacFindDeviceNotifier.category || category == MacSmsNotifier.category || category == MacSmsNotifier.resultCategory ||
            category == MacTransferNotifier.Category.offer || category == MacTransferNotifier.Category.result ||
            category == MacTransferNotifier.Category.paused || category == MacTransferNotifier.Category.pausedSender ||
            category.hasPrefix(MacNotificationMirrorNotifier.categoryPrefix)
        guard known else { return [] }
        // Reconnect snapshots and revisions remain quiet even while aniCe is the foreground app.
        guard content.interruptionLevel != .passive else { return [.list] }
        var presentation: UNNotificationPresentationOptions = [.banner, .list]
        if content.sound != nil { presentation.insert(.sound) }
        return presentation
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier, identifier = response.notification.request.identifier
        let userText = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        let userInfo = response.notification.request.content.userInfo
        let mirrorEpoch = userInfo["anice.mirror.epoch"] as? String
        let mirrorSequence = (userInfo["anice.mirror.sequence"] as? NSNumber)?.int64Value
        let transferToken = userInfo["anice.transfer.token"] as? String
        let smsToken = userInfo["anice.sms.token"] as? String
        let updateTag = userInfo[MacUpdateModel.notificationTagKey] as? String
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            self?.handleNotificationAction(category: category, action: action, identifier: identifier,
                userText: userText, mirrorEpoch: mirrorEpoch, mirrorSequence: mirrorSequence,
                transferToken: transferToken, smsToken: smsToken, updateTag: updateTag)
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
                    $0.identifier?.rawValue == "main" || $0.title == "aniCe" || $0.title == MacAppStorage.applicationName
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
            $0.isVisible && ($0.identifier?.rawValue == "main" || $0.title == "aniCe" || $0.title == MacAppStorage.applicationName)
        }
    }
}
