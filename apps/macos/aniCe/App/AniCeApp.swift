// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct AniCeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  // Both scenes use this instance so details and companion actions share identity state.
  @State private var identity: IdentityViewModel
  @State private var discovery: MacDiscoveryModel
  @State private var session: MacSessionModel
  @State private var pairing: MacPairingModel

  init() {
    let identity = IdentityAssembly.makeModel()
    let radio = CoreBluetoothPeripheralAdapter()
    let discovery = MacDiscoveryModel(adapter: radio)
    _identity = State(initialValue: identity)
    _discovery = State(initialValue: discovery)
    let pairing = MacPairingModel(identity: identity.service, discovery: discovery)
    let session = MacSessionModel(
      identity: identity.service, adapter: radio, store: { try await pairing.sessionStore() })
    session.beforeAllow = {
      pairing.cancel()
      discovery.stop()
    }
    pairing.beforePairing = { session.cancel() }
    pairing.trustRemoved = { session.cancel() }
    discovery.beforeStart = { session.cancel() }
    identity.onIdentityReset = {
      session.cancel()
      pairing.cancel()
    }
    _pairing = State(initialValue: pairing)
    _session = State(initialValue: session)
  }

  var body: some Scene {
    Window("aniCe", id: "main") {
      MainWindowView(
        delegate: delegate, identity: identity, discovery: discovery, pairing: pairing,
        session: session)
    }
    .defaultSize(width: 800, height: 560)
    .windowResizability(.contentMinSize)

    MenuBarExtra("aniCe", systemImage: "laptopcomputer.and.iphone") {
      CompanionView(identity: identity, discovery: discovery, pairing: pairing, session: session)
    }
    .menuBarExtraStyle(.window)
  }
}
