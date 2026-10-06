// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct AniCeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Both scenes use this instance so details and companion actions share identity state.
    @State private var identity = IdentityAssembly.makeModel()

    var body: some Scene {
        Window("aniCe", id: "main") {
            MainWindowView(delegate: delegate, identity: identity)
        }
        .defaultSize(width: 800, height: 560)
        .windowResizability(.contentMinSize)

        MenuBarExtra("aniCe", systemImage: "laptopcomputer.and.iphone") {
            CompanionView(identity: identity)
        }
        .menuBarExtraStyle(.window)
    }
}
