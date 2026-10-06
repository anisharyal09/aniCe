// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Retain the scene action after its view disappears so Dock reopening still works.
    var reopenMainWindow: (@MainActor () -> Void)?

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
