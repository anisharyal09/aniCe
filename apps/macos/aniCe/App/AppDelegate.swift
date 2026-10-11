// SPDX-License-Identifier: GPL-3.0-or-later
// Retains companion presentation and the main-window reopening action without owning sessions.
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Retain the scene action after its view disappears so Dock reopening still works.
    var reopenMainWindow: (@MainActor () -> Void)?
    private var companion: CompanionHost?

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
        }, onDetails: { [weak self] in
            navigation.details = true
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
