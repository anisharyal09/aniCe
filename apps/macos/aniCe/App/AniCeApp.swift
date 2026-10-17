// SPDX-License-Identifier: GPL-3.0-or-later
// Assembles shared trust, peer reservations and native Bluetooth/LAN owners for both scenes.
import SwiftUI
import UserNotifications

@main
struct AniCeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  // Both scenes use this instance so details and companion actions share identity state.
  @State private var identity: IdentityViewModel
  @State private var discovery: MacDiscoveryModel
  @State private var session: MacSessionModel
  @State private var pairing: MacPairingModel
  @State private var lan: MacLanSessionModel
  @State private var playback: MacPlaybackModel
  @State private var findDevice: MacFindDeviceModel
  private let findNotifier: MacFindDeviceNotifier
  @State private var transfer: MacTransferModel
  @State private var transferNotifier: MacTransferNotifier?
  @State private var navigation: ConnectionNavigation

  init() {
    let notifier = MacFindDeviceNotifier()
    findNotifier = notifier
    let findDevice = MacFindDeviceModel(notifier: notifier)
    notifier.dismissed = { [weak findDevice] id in findDevice?.dismiss(identifier: id) }
    _findDevice = State(initialValue: findDevice)
    let playback = MacPlaybackModel()
    _playback = State(initialValue: playback)
    let transfer = MacTransferModel()
    _transfer = State(initialValue: transfer)
    let transferNotifier = MacTransferNotifier(
      model: transfer,
      openMainWindow: {
        for window in NSApp.windows where window.identifier?.rawValue == "main" || window.title == "aniCe" {
          window.deminiaturize(nil)
          window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
      }
    )
    _transferNotifier = State(initialValue: transferNotifier)
    transfer.onEvent = { [weak transferNotifier] event in
      transferNotifier?.handle(event)
    }
    let navigation = ConnectionNavigation()
    _navigation = State(initialValue: navigation)
    let identity = IdentityAssembly.makeModel()
    let radio = CoreBluetoothPeripheralAdapter()
    let discovery = MacDiscoveryModel(adapter: radio)
    _identity = State(initialValue: identity)
    _discovery = State(initialValue: discovery)
    let pairing = MacPairingModel(identity: identity.service, discovery: discovery)
    let peers = SessionPeerReservation()
    let lan = MacLanSessionModel(identity: identity.service, peers: peers, preferences: .standard, store: { try await pairing.sessionStore() })
    _lan = State(initialValue: lan)
    transfer.onLanRequired = { [weak lan] in _ = lan?.requestAutomaticConnection() }
    let session = MacSessionModel(
      identity: identity.service, adapter: radio, store: { try await pairing.sessionStore() },
      preferences: .standard, peers: peers)
    let features=FeatureDispatch()
    features.applicationActivity = { [weak lan] descriptor, bytes in lan?.onApplicationActivity(descriptor, bytes) }
    features.register(lan.rendezvous)
    features.register(playback)
    features.register(transfer)
    features.register(findDevice)
    session.channelStateChanged = { [weak session] in
      if let session, let token=session.channelToken, let peer=session.authenticatedPeer {
        features.available(ChannelDescriptor(instance:token,transport:"ble",peer:peer)) { [weak session] bytes in
          guard let session else { throw SessionFailure.cancelled }; try await session.sendData(bytes)
        }
      } else { features.retired("ble") }
    }
    lan.channelStateChanged = { [weak lan] in
      if let lan, let token=lan.channelToken, let peer=lan.authenticatedPeer {
        features.available(ChannelDescriptor(instance:token,transport:"lan",peer:peer,maximumDataBytes:SessionProfile.lanTransfer.maximumPlaintext)) { [weak lan] bytes in
          guard let lan else { throw SessionFailure.cancelled }; try await lan.sendData(bytes)
        }
      } else { features.retired("lan") }
    }
    session.channelCapacityChanged = { features.capacityAvailable("ble") }
    lan.channelCapacityChanged = { features.capacityAvailable("lan") }
    session.applicationDataReceived = { [weak session] bytes in await features.handle(bytes,transport:"ble",instance:session?.channelToken) != .unrecognized }
    lan.applicationDataReceived = { [weak lan] bytes in await features.handle(bytes,transport:"lan",instance:lan?.channelToken) != .unrecognized }
    Self.configureSessionLifecycle(session: session, pairing: pairing, discovery: discovery)
    pairing.onPaired = { [weak session, weak navigation, weak lan] peer in
      guard let session, let navigation else { return }
      lan?.setAutomatic(navigation.automaticLanAfterPairing)
      navigation.show(.home)
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
    delegate.configureNotifications(findDevice: notifier, transfer: transferNotifier)
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
        session: session, lan: lan, playback: playback, transfer: transfer, findDevice: findDevice, findNotifier: findNotifier, navigation: navigation)
        .onAppear {
          if !IdentityView.isTesting {
            delegate.onTerminate = { findNotifier.clearAll() }
            delegate.installCompanion(
              CompanionView(identity: identity, discovery: discovery, pairing: pairing,
                session: session, lan: lan, playback: playback, transfer: transfer, navigation: navigation,
                openMainWindow: { delegate.openMainFromCompanion() }),
              navigation: navigation)
          }
        }
    }
    .defaultSize(width: 800, height: 560)
    .windowResizability(.contentMinSize)

  }
}
