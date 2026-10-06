// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct AniCeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("aniCe", id: "main") {
            MainWindowView(delegate: delegate)
        }
        .defaultSize(width: 800, height: 560)
        .windowResizability(.contentMinSize)

        MenuBarExtra("aniCe", systemImage: "laptopcomputer.and.iphone") {
            CompanionView()
        }
        .menuBarExtraStyle(.window)
    }
}
