// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct AniCeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Both scenes use this instance so details and companion actions share identity state.
    @State private var identity: IdentityViewModel
    @State private var discovery: MacDiscoveryModel
    @State private var pairing: MacPairingModel

    init() {
        let identity = IdentityAssembly.makeModel(); let discovery = MacDiscoveryModel()
        _identity = State(initialValue: identity); _discovery = State(initialValue: discovery)
        _pairing = State(initialValue: MacPairingModel(identity: identity.service, discovery: discovery))
    }

    var body: some Scene {
        Window("aniCe", id: "main") {
            MainWindowView(delegate: delegate, identity: identity, discovery: discovery, pairing: pairing)
        }
        .defaultSize(width: 800, height: 560)
        .windowResizability(.contentMinSize)

        MenuBarExtra("aniCe", systemImage: "laptopcomputer.and.iphone") {
            CompanionView(identity: identity, discovery: discovery, pairing: pairing)
        }
        .menuBarExtraStyle(.window)
    }
}
