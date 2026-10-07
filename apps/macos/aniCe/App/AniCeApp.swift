// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct AniCeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Both scenes use this instance so details and companion actions share identity state.
    @State private var identity = IdentityAssembly.makeModel()
    @State private var discovery = MacDiscoveryModel()

    var body: some Scene {
        Window("aniCe", id: "main") {
            MainWindowView(delegate: delegate, identity: identity, discovery: discovery)
        }
        .defaultSize(width: 800, height: 560)
        .windowResizability(.contentMinSize)

        MenuBarExtra("aniCe", systemImage: "laptopcomputer.and.iphone") {
            CompanionView(identity: identity, discovery: discovery)
        }
        .menuBarExtraStyle(.window)
    }
}
