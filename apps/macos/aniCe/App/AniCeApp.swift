// SPDX-License-Identifier: GPL-3.0-or-later
// Assembles shared trust, peer reservations and native Bluetooth/LAN owners for both scenes.
import SwiftUI

@main
struct AniCeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  // Both scenes use this instance so details and companion actions share identity state.
  @State private var identity: IdentityViewModel
  @State private var discovery: MacDiscoveryModel
  @State private var session: MacSessionModel
  @State private var pairing: MacPairingModel
  @State private var lan: MacLanSessionModel
  @State private var navigation: ConnectionNavigation

  init() {
    let navigation = ConnectionNavigation()
    _navigation = State(initialValue: navigation)
    let identity = IdentityAssembly.makeModel()
    let radio = CoreBluetoothPeripheralAdapter()
    let discovery = MacDiscoveryModel(adapter: radio)
    _identity = State(initialValue: identity)
    _discovery = State(initialValue: discovery)
    let pairing = MacPairingModel(identity: identity.service, discovery: discovery)
    let peers = SessionPeerReservation()
    let lan = MacLanSessionModel(identity: identity.service, peers: peers, store: { try await pairing.sessionStore() })
    _lan = State(initialValue: lan)
    let session = MacSessionModel(
      identity: identity.service, adapter: radio, store: { try await pairing.sessionStore() },
      preferences: .standard, peers: peers)
    Self.configureSessionLifecycle(session: session, pairing: pairing, discovery: discovery)
    pairing.onPaired = { [weak session, weak navigation] peer in
      guard let session, let navigation else { return }
      navigation.managingDevices = false
      navigation.details = false
      session.selectedPeer = peer
      session.setAutomatic(navigation.automaticAfterPairing)
      if !navigation.automaticAfterPairing { session.allow() }
    }
    pairing.trustRemoved = { session.retireTrust(); lan.cancel() }
    identity.onIdentityReset = {
      lan.cancel()
      session.retireTrust()
      pairing.cancel()
    }
    _pairing = State(initialValue: pairing)
    _session = State(initialValue: session)
    session.restoreAutomatic()
  }

  /// One shared radio owner; completed cleanup must not take the radio from a newer exclusive mode.
  @MainActor static func configureSessionLifecycle(
    session: MacSessionModel, pairing: MacPairingModel, discovery: MacDiscoveryModel
  ) {
    session.beforeAllow = {
      pairing.cancel()
      discovery.stop()
    }
    pairing.beforePairing = { session.suspendAutomatic() }
    pairing.afterPairing = { [weak session, weak pairing, weak discovery] in
      guard pairing?.active == false, discovery?.session.active == false else { return }
      session?.resumeAutomatic()
    }
    pairing.trustRemoved = { session.retireTrust() }
    discovery.beforeStart = { session.suspendAutomatic() }
    discovery.afterStop = { [weak session, weak pairing, weak discovery] in
      // Defer until a shared-radio mode change finishes installing its new owner.
      Task { @MainActor in
        guard pairing?.active == false, discovery?.session.active == false else { return }
        session?.resumeAutomatic()
      }
    }
  }

  var body: some Scene {
    Window("aniCe", id: "main") {
      MainWindowView(
        delegate: delegate, identity: identity, discovery: discovery, pairing: pairing,
        session: session, lan: lan, navigation: navigation)
        .onAppear {
          if !IdentityView.isTesting {
            delegate.installCompanion(
              CompanionView(identity: identity, discovery: discovery, pairing: pairing,
                session: session, lan: lan, navigation: navigation,
                openMainWindow: { [weak delegate] in delegate?.openMainFromCompanion() }),
              navigation: navigation)
          }
        }
    }
    .defaultSize(width: 800, height: 560)
    .windowResizability(.contentMinSize)

  }
}
