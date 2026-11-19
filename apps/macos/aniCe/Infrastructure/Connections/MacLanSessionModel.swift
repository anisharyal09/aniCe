// SPDX-License-Identifier: GPL-3.0-or-later
// Owns manual and BLE-coordinated Bonjour admission and independently authenticated LAN sessions.
import AppKit
import Foundation
@preconcurrency import Network
import Observation
import OSLog

@Observable @MainActor final class MacLanSessionModel {
  private static let logger = Logger(subsystem: "io.github.anisharyal09.anice", category: "LAN lifecycle")
  private(set) var state = "Disconnected" {
    didSet {
      if state != "Secured" { checkPending = false }
      channelStateChanged()
      scheduleAutomatic()
    }
  }
  private(set) var status = "Allow your trusted Android to connect over the local network."
  private(set) var allowing = false
  private(set) var receivedChecks = 0
  private var checkPending = false
  private var checkingPeerLoss = false
  var verifyingConnection: Bool { checkingPeerLoss }
  private var checkDeadline: TimeInterval?
  @ObservationIgnored private var checkTask: Task<Void, Never>?
  private(set) var authenticatedPeer: DeviceIdentity?
  private(set) var selectedPeer: DeviceIdentity?
  private(set) var automatic: Bool
  private let preferences: UserDefaults?
  let rendezvous = LanRendezvous()
  private var automaticPaused = false
  private var connectionPaused = false
  var isConnectionPaused: () -> Bool = { false }
  private var automaticAttempt = false
  private var sleeping = false
  private var quitting = false
  private var registered = false
  private var serviceRegistered = false
  private var listenerReady = false
  private var localInterfaces = [Int]()
  private var localEndpoint: LanDirectEndpoint?
  private var localPathAvailable = true
  @ObservationIgnored private var pathMonitor: NWPathMonitor?
  private var automaticTask: Task<Void, Never>?
  private var recoveryTask: Task<Void, Never>?
  private var recoveryStep = 0
  private var recoveryGeneration = 0
  private var recoveryChannel: String?
  private let recoveryDelays: [TimeInterval]
  private var automaticGate = LanAttemptGate()
  /// A local-network return can also finish an elapsed connection pause owned by the session model.
  var onNetworkReturn: () -> Void = {}

  func setAutomatic(_ enabled: Bool) {
    if !enabled { rendezvous.cancelTransferRequest() }
    automatic = enabled
    preferences?.set(enabled, forKey: "lan.automatic")
    automaticPaused = false
    connectionPaused = false
    if enabled { rearmRecovery() } else { cancelRecovery() }
    automaticGate.trigger()
    if !enabled, automaticAttempt, state != "Secured" { end() }
    scheduleAutomatic()
  }
  func resumeAfterTimedPause() {
    guard automatic else { return }
    automaticPaused = false
    connectionPaused = false
    rearmRecovery()
    automaticGate.trigger()
    scheduleAutomatic()
  }
  private func cancelRecovery() {
    recoveryGeneration += 1
    recoveryTask?.cancel(); recoveryTask = nil
    recoveryStep = 0
  }
  private func rearmRecovery() {
    cancelRecovery()
    automaticGate.rearm()
  }
  private func noteRecoveryChannel() {
    let channel = rendezvous.channel?.descriptor.instance
    guard channel != recoveryChannel else { return }
    recoveryChannel = channel
    if channel == nil { cancelRecovery() } else { rearmRecovery() }
  }
  /// A failed automatic attempt may retry twice at two and five seconds. The budget is per
  /// app-open/connection event, so repeated callbacks cannot create an endless loop.
  private func scheduleRecovery() {
    guard recoveryTask == nil, automatic, !automaticPaused, !sleeping, !quitting, localPathAvailable,
      state != "Secured", !allowing, recoveryStep < recoveryDelays.count,
      rendezvous.channel != nil, rendezvous.remote != nil, rendezvous.remote != 0 else { return }
    let delay = recoveryDelays[recoveryStep]
    recoveryStep += 1
    let generation = recoveryGeneration
    recoveryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard let self, !Task.isCancelled, generation == self.recoveryGeneration else { return }
      self.recoveryTask = nil
      guard self.automatic, !self.automaticPaused, !self.sleeping, !self.quitting,
        self.localPathAvailable, self.state != "Secured", !self.allowing,
        let channel = self.rendezvous.channel,
        let remote = self.rendezvous.remote, remote != 0 else { return }
      self.automaticGate.release()
      guard self.automaticGate.claimRecovery() else { return }
      self.allow(selected: channel.descriptor.peer, bluetoothAllowing: false, automatically: true)
    }
  }
  func onApplicationActivity(_ descriptor: ChannelDescriptor, _ bytes: Data) {
    guard automatic, !automaticPaused, !sleeping, !quitting,
      descriptor.transport == "ble", rendezvous.channel?.descriptor == descriptor,
      state != "Secured", !allowing else { return }
    guard (try? LanRendezvousWire.decode(bytes)) == nil, automaticGate.claimActivity() else { return }
    _ = requestAutomaticConnection()
  }
  func requestAutomaticConnection() -> Bool {
    if state == "Secured" || allowing { return true }
    guard automatic, !automaticPaused, !connectionPaused, !isConnectionPaused(), !sleeping, !quitting,
      rendezvous.channel != nil, rendezvous.remote != 0 else { return false }
    automaticGate.trigger()
    rendezvous.request()
    scheduleAutomatic()
    return true
  }
  /// A fresh local file action can resume transport Disconnect without undoing Pause or disabled automation.
  func requestTransferConnection() -> Bool {
    guard !connectionPaused, !isConnectionPaused() else { return false }
    let existing = state == "Secured" || allowing
    guard !sleeping, !quitting else { return false }
    guard automatic else { return existing }
    if automaticPaused {
      automaticPaused = false
      cancelRecovery()
      automaticGate.trigger()
      scheduleAutomatic()
    }
    guard rendezvous.channel != nil else { return existing }
    automaticGate.trigger()
    rendezvous.requestTransfer()
    scheduleAutomatic()
    return true
  }
  private func scheduleAutomatic() {
    noteRecoveryChannel()
    automaticTask?.cancel()
    automaticTask = Task { [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled else { return }
      let eligible = self.automatic && !self.automaticPaused && !self.connectionPaused && !self.isConnectionPaused() &&
        !self.sleeping && !self.quitting && self.localPathAvailable
      self.automaticGate.update(channel: self.rendezvous.channel?.descriptor.instance, eligible: eligible,
        remoteEligible: self.rendezvous.remote != nil && self.rendezvous.remote != 0,
        ready: false, requests: self.rendezvous.requests)
      self.rendezvous.update(!eligible ? 0 : self.state == "Secured" ? 3 : self.registered ? 2 : 1,
        endpoint: eligible && self.allowing && !self.admission.admitted && !self.retiring ? self.localEndpoint : nil)
      if !self.localPathAvailable, self.automatic, !self.automaticPaused, !self.sleeping, !self.quitting { return }
      guard eligible, let channel = self.rendezvous.channel, let remote = self.rendezvous.remote,
        remote != 0 else {
        self.cancelRecovery()
        if self.automaticAttempt, self.state != "Secured" { self.end() }
        return
      }
      if self.state == "Secured" {
        _ = self.automaticGate.claim(connected: true); return
      }
      if self.allowing {
        self.automaticGate.hold(); return
      }
      guard self.automaticGate.claim() else { return }
      self.allow(selected: channel.descriptor.peer, bluetoothAllowing: false, automatically: true)
    }
  }

  private let identity: IdentityService
  private let store: @MainActor () async throws -> PeerTrustStore
  private let peers: SessionPeerReservation
  private let startListener: @MainActor (NWListener) -> Void
  private let endpointProvider: @MainActor (NWListener, [Int]) -> LanDirectEndpoint?
  private(set) var listener: NWListener?
  private var transport: LanTcpTransport?
  private var trustLocation: URL?
  var channelStateChanged: () -> Void = {}
  var channelCapacityChanged: () -> Void = {}
  var channelMaintenanceChanged: (SessionMaintenanceSnapshot) -> Void = { _ in }
  var applicationDataDrained: () async -> Void = {}
  var applicationDataReceived: (Data) async -> Bool = { _ in false }
  var channelToken: String? { state == "Secured" && connection != nil ? "\(generation)-\(candidate)":nil }
  func sendData(_ bytes: Data) async throws {
    guard let connection, let transport, state == "Secured" else { throw SessionBackpressure() }
    let token = channelToken
    let capacity = await transport.capacity(bytes.count + 31)
    let ready = await connection.applicationAvailable
    guard channelToken == token else { throw SessionFailure.cancelled }
    guard capacity, ready else { throw SessionBackpressure() }
    do { try await connection.sendData(bytes) }
    catch is SessionBackpressure { throw SessionBackpressure() }
    catch {
      if error is CancellationError, await !connection.isClosed { throw error }
      if channelToken == token { failCandidate(error) }
      throw error
    }
    guard channelToken == token else { throw SessionFailure.cancelled }
  }
  private var connection: SessionConnection?
  private var admission = SessionAdmissionWindow()
  private var generation = 0
  private var candidate = 0
  private var startupDeadline: TimeInterval?
  private var handshakeDeadline: TimeInterval?
  private var checking = false
  private var retiring = false
  @ObservationIgnored private let deadlineWait = SessionDeadlineWait()
  var maintenanceDeadline: TimeInterval? { deadlineWait.deadline }
  private var work: Task<Void, Never>?
  private var observers = [NSObjectProtocol]()
  private var advertisement: NWListener.Service?
  init(
    identity: IdentityService, peers: SessionPeerReservation,
    preferences: UserDefaults? = nil,
    recoveryDelays: [TimeInterval] = [2, 5],
    startListener: @escaping @MainActor (NWListener) -> Void = { $0.start(queue: DispatchQueue(label: "aniCe LAN listener")) },
    endpointProvider: @escaping @MainActor (NWListener, [Int]) -> LanDirectEndpoint? = { server, interfaces in
      guard let port = server.port, let ip = LanLocalAddress.ipv4(interfaceIndices: interfaces) else { return nil }
      return try? LanDirectEndpoint(ip: ip, port: port.rawValue, profile: .lanTransfer512)
    },
    store: @escaping @MainActor () async throws -> PeerTrustStore
  ) {
    self.preferences = preferences
    self.recoveryDelays = recoveryDelays
    self.startListener = startListener
    self.endpointProvider = endpointProvider
    // Absent means the user never chose; an explicit stored false still disables automation.
    self.automatic = preferences.map { ($0.object(forKey: "lan.automatic") as? Bool) ?? true } ?? false
    self.identity = identity
    self.peers = peers
    self.store = store
    rendezvous.changed = { [weak self] in self?.scheduleAutomatic() }
    rendezvous.transferRequested = { [weak self] descriptor in
      guard let self, self.automatic, !self.connectionPaused, !self.isConnectionPaused(),
        !self.sleeping, !self.quitting, self.rendezvous.channel?.descriptor == descriptor else { return }
      if let peer = self.peers.peer {
        guard peer.deviceId == descriptor.peer.deviceId, peer.fingerprint == descriptor.peer.fingerprint,
          peer.publicKey == descriptor.peer.publicKey else { return }
      }
      self.automaticPaused = false
      self.automaticGate.trigger()
      self.scheduleAutomatic()
    }
    rendezvous.remoteStateChanged = { [weak self] descriptor, previous, current in
      guard let self, self.state == "Secured",
        let peer = self.authenticatedPeer,
        peer.deviceId == descriptor.peer.deviceId, peer.fingerprint == descriptor.peer.fingerprint,
        peer.publicKey == descriptor.peer.publicKey else { return }
      // A delayed BLE state belongs to its BLE lane, not necessarily this TCP generation.
      if previous == 3, current != 3 { self.checkConnection(peerLoss: true) }
    }
    for (name, object) in [(IdentityService.invalidated, identity as AnyObject?),
                           (PeerTrustStore.invalidated, nil)] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) {
        [weak self] notification in
        let location = (notification.object as? PeerTrustStore)?.location ?? (notification.object as? URL)
        MainActor.assumeIsolated {
          guard let self else { return }
          if name == PeerTrustStore.invalidated {
            guard let location, location == self.trustLocation else { return }
          }
          self.cancel()
        }
      })
    }
    for event in [NSWorkspace.willSleepNotification] {
      observers.append(
        NSWorkspace.shared.notificationCenter.addObserver(forName: event, object: nil, queue: .main)
        { [weak self] _ in
          MainActor.assumeIsolated {
            self?.sleeping = true
            self?.cancelRecovery()
            self?.end()
          }
        })
    }
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.sleeping = false
          self?.rearmRecovery()
          self?.scheduleAutomatic()
        }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.rearmRecovery()
          self?.scheduleAutomatic()
        }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.quitting = true; self?.end() }
      })
  }
  /// Device-level Connect asks LAN to listen alongside BLE for the selected phone.
  func connectAlongside(_ selected: DeviceIdentity?) {
    // Any live owner is authoritative; repeated Connect must not replace a healthy listener/session.
    if allowing || state == "Secured" {
      let current = authenticatedPeer ?? selectedPeer
      if selected == nil || (current?.deviceId == selected?.deviceId &&
          current?.fingerprint == selected?.fingerprint && current?.publicKey == selected?.publicKey) {
        automaticPaused = false
        connectionPaused = false
        cancelRecovery()
        automaticGate.trigger()
        scheduleAutomatic()
      }
      return
    }
    allow(selected: selected, bluetoothAllowing: false)
  }

  /// Cancels the current admission or connection without changing the automatic preference.
  func cancelAttempt(message: String = "Connection canceled.") {
    guard state != "Secured" else { return }
    cancelRecovery()
    rendezvous.cancelTransferRequest()
    automaticGate.cancel()
    end(message: message)
  }

  /// Gates automatic work synchronously; the returned teardown cannot close a replacement owner.
  func preparePause() -> @MainActor () -> Void {
    cancelRecovery()
    rendezvous.cancelTransferRequest()
    automaticPaused = true
    connectionPaused = true
    automaticAttempt = false
    if state != "Secured" { end(); return {} }
    scheduleAutomatic()
    let op = generation
    return { [weak self] in
      guard let self, op == self.generation, self.automaticPaused else { return }
      self.disconnect()
    }
  }

  func allow(selected: DeviceIdentity?, bluetoothAllowing: Bool, automatically: Bool = false) {
    if !automatically { cancelRecovery(); automaticPaused = false; connectionPaused = false; automaticGate.trigger() }
    guard !bluetoothAllowing || peers.peer != nil else {
      status =
        "Finish or stop the current Bluetooth admission before allowing a local-network connection."
      return
    }
    end(preserveListener: automatic && !automaticPaused && !sleeping && !quitting)
    admission.clear() // Only a newly authorized Allow event starts another bounded admission window.
    automaticAttempt = automatically
    selectedPeer = selected
    allowing = true
    state = "Connecting"
    status = "Starting local-network availability…"
    receivedChecks = 0
    let op = generation
    work = Task { [self] in
      do {
        let local = try await identity.publicIdentity()
        let trust = try await store()
        guard op == generation else { return }
        trustLocation = trust.location
        let active = trust.list(localFingerprint: local.fingerprint).map(\.peer).filter {
          $0.platform == "android"
        }
        guard op == generation else { return }
        let target = selected ?? peers.peer ?? (active.count == 1 ? active.first : nil)
        guard let target,
          active.filter({
            $0.deviceId == target.deviceId && $0.fingerprint == target.fingerprint
              && $0.publicKey == target.publicKey
          }).count == 1
        else {
          failWindow("Choose one active trusted Android before allowing local-network connections.")
          return
        }
        selectedPeer = target
        guard peers.acquire("lan", peer: target, local: local.fingerprint) else {
          failWindow("Disconnect the other device before allowing this phone.")
          return
        }
        let parameters = LanTcpTransport.parameters()
        if let current = listener {
          switch current.state {
          case .failed, .cancelled:
            current.cancel(); listener = nil; listenerReady = false
          default: break
          }
        }
        let reused = listener != nil
        let server = try listener ?? NWListener(using: parameters, on: .any)
        listener = server
        observeLocalPath()
        // The service name is an ephemeral locator, never an identity or authentication claim.
        let txt = NWTXTRecord(["v": "3"])
        advertisement = NWListener.Service(
          name: "aniCe-" + UUID().uuidString.lowercased(), type: "_anice._tcp", txtRecord: txt)
        server.service = advertisement
        server.stateUpdateHandler = { [weak self] state in
          Task { @MainActor in
            guard let self, op == self.generation else { return }
            switch state {
            case .waiting(let error) where Self.waitsForNetwork(error):
              self.listenerReady = false
              self.localEndpoint = nil
              self.registered = false
              self.startupDeadline = nil
              self.status = "Waiting for network…"
              self.scheduleAutomatic()
              self.maintain()
            case .ready:
              self.listenerReady = true
              self.registered = self.serviceRegistered && self.allowing && !self.admission.admitted
              self.refreshEndpoint()
              self.beginAvailabilityIfReady(target)
              self.scheduleAutomatic()
              self.maintain()
            case .failed(let error), .waiting(let error):
              self.failWindow(
                "Local-network listener unavailable: \(error). Check network access and retry.")
            default: break
            }
          }
        }
        server.serviceRegistrationUpdateHandler = { [weak self] change in
          Task { @MainActor in
            guard let self, op == self.generation else { return }
            defer { self.maintain() }
            if case .add = change {
              self.serviceRegistered = true
              self.registered = self.listenerReady && self.allowing && !self.admission.admitted
              self.beginAvailabilityIfReady(target)
              self.scheduleAutomatic()
            } else {
              self.serviceRegistered = false
              self.registered = false
              self.scheduleAutomatic()
            }
          }
        }
        server.newConnectionHandler = { [weak self] socket in
          Task { @MainActor in
            guard let self, op == self.generation else {
              socket.cancel()
              return
            }
            self.admit(socket, target: target, trust: trust, op: op)
          }
        }
        startupDeadline = ProcessInfo.processInfo.systemUptime + 10
        if !reused { startListener(server) }
        else {
          refreshEndpoint()
          beginAvailabilityIfReady(target)
          scheduleAutomatic()
        }
        maintain()
      } catch { if op == generation { failWindow(error.localizedDescription) } }
    }
  }
  private func refreshEndpoint() {
    localEndpoint = listenerReady && localPathAvailable ? listener.flatMap { endpointProvider($0, localInterfaces) } : nil
  }
  private func beginAvailabilityIfReady(_ target: DeviceIdentity) {
    guard allowing, !automaticPaused, !admission.admitted, registered || localEndpoint != nil else { return }
    startupDeadline = nil
    // TCP and Bonjour callbacks share the original admission deadline; neither can renew it.
    admission.open(ProcessInfo.processInfo.systemUptime)
    state = "Disconnected"
    status = automaticAttempt ? "Waiting for \(target.deviceName) to connect automatically…"
      : "Waiting for \(target.deviceName). On that phone, connect over local network."
  }
  private func admit(_ socket: NWConnection, target: DeviceIdentity, trust: PeerTrustStore, op: Int)
  {
    guard allowing, !automaticPaused, !retiring, admission.claim(ProcessInfo.processInfo.systemUptime) else {
      socket.cancel()
      return
    }
    registered = false
    listener?.service = nil
    state = "Connecting"
    status = "Authenticating your trusted Android…"
    handshakeDeadline = ProcessInfo.processInfo.systemUptime + 30
    let attempt = candidate
    let tcp = LanTcpTransport(socket, profile: .lanTransfer512)
    transport = tcp
    work = Task { [self] in
      do {
        let handshake = try await SessionHandshakeEngine.responder(
          identity: identity, trust: trust, selectedPeer: target)
        guard op == generation, attempt == candidate else {
          await handshake.close()
          return
        }
        let engine = SessionConnection(
          handshake: handshake, responder: true,
          capacity: { [weak self] bytes in await self?.capacity(bytes, op, attempt) ?? false },
          submit: { [weak self] bytes in
            guard let self else { throw SessionFailure.cancelled }
            try await self.submit(bytes, op, attempt)
          },
          data: { [weak self] bytes in await self?.received(bytes, op, attempt) },
          secured: { [weak self] in await self?.secured(op, attempt) }, controls: true,
          renew: true,
          changed: { [weak self] in Task { @MainActor in
            guard let self, op == self.generation, attempt == self.candidate else { return }
            if let snapshot = await self.connection?.maintenanceSnapshot,
              op == self.generation, attempt == self.candidate {
                if snapshot.sinceMillis != nil { self.clearConnectionCheck() }
                self.channelMaintenanceChanged(snapshot)
              }
            self.maintain(); self.channelCapacityChanged()
          } }, profile: .lanTransfer512, drain: { [weak self] in await self?.drainApplication(op, attempt) },
          renewalHandshake: { [identity] in
            try await SessionHandshakeEngine.responder(identity: identity, trust: trust, selectedPeer: target)
          }, pingAfterMillis: 10000, pongWithinMillis: 10000)
        connection = engine
        maintain()
        await tcp.start(
          deliver: { [weak self] bytes in
            try await engine.receive(bytes)
            if bytes.first == 3, await !engine.isRenewing { await self?.handshakeReceived(op, attempt) }
            if await engine.isClosed { await self?.peerClosed(op, attempt) }
          },
          ended: { [weak self] error in
            Task { @MainActor in
              guard let self, op == self.generation, attempt == self.candidate else { return }
              self.failCandidate(error)
            }
          }, drained: { [weak self] in await self?.drainApplication(op, attempt) }, changed: { [weak self] in
            Task { @MainActor in
              guard let self, op == self.generation, attempt == self.candidate else { return }
              await self.connection?.capacityAvailable()
              self.channelCapacityChanged()
              self.maintain()
            }
          })
      } catch { if op == generation, attempt == candidate { failCandidate(error) } }
    }
  }
  private func drainApplication(_ op: Int, _ attempt: Int) async {
    guard op == generation, attempt == candidate else { return }
    await applicationDataDrained()
  }
  private func handshakeReceived(_ op: Int, _ attempt: Int) {
    guard op == generation, attempt == candidate else { return }
    handshakeDeadline = ProcessInfo.processInfo.systemUptime + 10
    maintain()
  }
  private func peerClosed(_ op: Int, _ attempt: Int) {
    guard op == generation, attempt == candidate else { return }
    cancelRecovery()
    retireSession(reason: "Your Android ended the local-network session.")
  }
  private func capacity(_ size: Int, _ op: Int, _ attempt: Int) async -> Bool {
    guard op == generation, attempt == candidate, let transport else { return false }
    let available = await transport.capacity(size)
    return op == generation && attempt == candidate && available
  }
  private func submit(_ bytes: Data, _ op: Int, _ attempt: Int) async throws {
    guard op == generation, attempt == candidate, let transport else {
      throw SessionFailure.cancelled
    }
    try await transport.submit(bytes)
    guard op == generation, attempt == candidate else { throw SessionFailure.cancelled }
  }
  private func secured(_ op: Int, _ attempt: Int) async {
    guard op == generation, attempt == candidate, let connection else { return }
    do {
      let peer = try await connection.authenticatedPeer()
      guard op == generation, attempt == candidate else { return }
      guard peers.authenticate("lan", peer: peer) else { throw SessionFailure.untrustedPeer }
      await transport?.markSecured()
      guard op == generation, attempt == candidate else { return }
      authenticatedPeer = peer
      handshakeDeadline = nil
      state = "Secured"
      status = "Secured with \(peer.deviceName) · \(peer.fingerprint.prefix(8))."
      maintain()
    } catch { if op == generation, attempt == candidate { failCandidate(error) } }
  }
  private func received(_ bytes: Data, _ op: Int, _ attempt: Int) async {
    guard op == generation, attempt == candidate else { return }
    // Authenticated traffic on this socket proves it survived an eligibility-only withdrawal.
    if checkingPeerLoss {
      clearConnectionCheck()
      status = "Local-network connection confirmed."
    }
    if bytes == SessionConnectionCheck.request {
      receivedChecks += 1
      status = "Local-network check received."
      Task { [weak self] in
        guard let self, op == self.generation, attempt == self.candidate else { return }
        do { try await self.sendData(SessionConnectionCheck.reply) }
        catch {
          if op == self.generation, attempt == self.candidate, self.status == "Local-network check received." {
            self.status = "Local-network check received, but its reply could not be sent."
          }
        }
      }
    } else if bytes == SessionConnectionCheck.reply {
      if checkPending {
        clearConnectionCheck()
        status = "Local-network check confirmed."
      }
    } else {
      _ = await applicationDataReceived(bytes)
    }
  }
  private func maintain() {
    guard allowing else { return }
    let op = generation
    let attempt = candidate
    deadlineWait.schedule(now: { ProcessInfo.processInfo.systemUptime }, deadline: { [weak self] in
      guard let self, op == self.generation, attempt == self.candidate else { return nil }
      let session: Int64?
      session = await self.connection?.nextDeadline(includeMaintenance: !self.checking)
      guard op == self.generation, attempt == self.candidate else { return nil }
      return [self.startupDeadline, self.admission.admitted ? self.handshakeDeadline : self.admission.deadline,
        session.map { Double($0) / 1000 }, self.checkDeadline].compactMap { $0 }.min()
    }, fire: { [weak self] in
      guard let self, op == self.generation, attempt == self.candidate else { return }
      self.tick()
    })
  }
  private func tick() {
    defer { maintain() }
    let now = ProcessInfo.processInfo.systemUptime
    if let checkDeadline, now >= checkDeadline, checkPending {
      let lost = checkingPeerLoss
      clearConnectionCheck()
      if lost { failCandidate(NWError.posix(.ETIMEDOUT)); return }
      status = "No reply to the local-network check. Check the Android connection."
    }
    if let startupDeadline, now >= startupDeadline {
      failWindow("Local-network advertising timed out. Check permissions and retry.")
      return
    }
    if !admission.admitted, let deadline = admission.deadline, now >= deadline {
      retireSession(reason: "Local-network Allow window expired.")
      return
    }
    if let handshakeDeadline, now >= handshakeDeadline {
      failCandidate(SessionFailure.expired)
      return
    }
    guard let connection else { return }
    let runControls = !checking
    if runControls { checking = true }
    let op = generation
    let attempt = candidate
    Task { [weak self] in
      do {
        try await connection.checkDeadlines()
        if runControls { try await connection.tick() }
      } catch {
        if let self, op == self.generation, attempt == self.candidate { self.failCandidate(error) }
      }
      if let self, op == self.generation, attempt == self.candidate {
        if runControls { self.checking = false }
        self.maintain()
      }
    }
  }
  private func failCandidate(_ error: Error) {
    Self.logger.notice("LAN session ended: \(String(describing: error), privacy: .public)")
    let wasAutomatic = automaticAttempt
    let secured = state == "Secured"
    let retryable: Bool
    if let failure = error as? SessionFailure {
      retryable = ![.cancelled, .untrustedPeer, .authentication].contains(failure)
    } else {
      retryable = true
    }
    let resume = admission.retire(ProcessInfo.processInfo.systemUptime)
    candidate += 1
    handshakeDeadline = nil
    checking = false
    let retiredTransport = transport
    Task { await retiredTransport?.close() }
    transport = nil
    let old = connection
    connection = nil
    if secured || !resume || error is IdentityError {
      if error is IdentityError {
        failWindow("Identity access changed. Check access before reconnecting.", retry: false)
      } else {
        retireSession(reason: "Local-network session ended: \(error.localizedDescription).")
        if wasAutomatic, secured, retryable { scheduleRecovery() }
      }
      Task { await old?.close() }
    } else {
      retiring = true
      state = "Failed"
      status = "That endpoint could not authenticate. Waiting for your trusted phone."
      let op = generation
      let attempt = candidate
      work = Task { [weak self] in
        await old?.close()
        guard let self, op == self.generation, attempt == self.candidate else { return }
        self.retiring = false
        self.listener?.service = self.advertisement
        self.scheduleAutomatic()
        self.maintain()
      }
    }
  }
  private func failWindow(_ message: String, retry: Bool = true) {
    let wasAutomatic = automaticAttempt
    end(message: message)
    state = "Failed"
    if wasAutomatic, retry { scheduleRecovery() }
  }
  func retireSession(reason: String) {
    // Retire the transport but preserve the automatic recovery step so a failing retry cannot loop.
    // A retained listening socket is not an open admission window or permission to re-advertise.
    end(message: reason, preserveListener: automatic && !automaticPaused && !sleeping && !quitting)
  }
  nonisolated static func waitsForNetwork(_ error: NWError) -> Bool {
    guard case .posix(let code) = error else { return false }
    return [.ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .ENETRESET].contains(code)
  }
  private func observeLocalPath() {
    guard pathMonitor == nil else { return }
    let monitor = NWPathMonitor()
    pathMonitor = monitor
    monitor.pathUpdateHandler = { [weak self] path in
      let available = path.status == .satisfied && path.availableInterfaces.contains {
        $0.type == .wifi || $0.type == .wiredEthernet
      }
      let interfaces = path.availableInterfaces.filter { $0.type == .wifi || $0.type == .wiredEthernet }
        .sorted { left, right in
          if left.type != right.type { return left.type == .wifi }
          return left.index < right.index
        }.map(\.index)
      Task { @MainActor in
        guard let self else { return }
        self.localInterfaces = available ? interfaces : []
        self.localPathChanged(available)
        self.refreshEndpoint()
        if let peer = self.peers.peer { self.beginAvailabilityIfReady(peer) }
        self.scheduleAutomatic()
        self.maintain()
      }
    }
    monitor.start(queue: DispatchQueue(label: "aniCe LAN availability"))
  }
  func localPathChanged(_ available: Bool) {
    guard localPathAvailable != available else { return }
    localPathAvailable = available
    // Only an external unavailable-to-available edge rearms the attempt gate, never registration.
    if available {
      onNetworkReturn()
      rearmRecovery()
    } else { cancelRecovery() }
    scheduleAutomatic()
  }
  func checkConnection() { checkConnection(peerLoss: false) }
  private func checkConnection(peerLoss: Bool) {
    guard state == "Secured", let connection else { return }
    if checkPending {
      if peerLoss, !checkingPeerLoss {
        checkingPeerLoss = true
        checkDeadline = max(checkDeadline ?? 0, ProcessInfo.processInfo.systemUptime + 10)
        maintain()
      }
      return
    }
    let op = generation
    let attempt = candidate
    checkPending = true
    checkingPeerLoss = peerLoss
    status = "Checking the local-network connection…"
    checkTask = Task { [weak self] in
      guard let self else { return }
      let renewing = await connection.isRenewing
      guard op == generation, attempt == candidate, checkPending else { return }
      if renewing {
        checkPending = false; checkingPeerLoss = false
        return
      }
      let deadline = ProcessInfo.processInfo.systemUptime + (checkingPeerLoss ? 10 : 5)
      checkDeadline = deadline
      maintain()
      do {
        try await connection.sendData(SessionConnectionCheck.request)
        guard op == generation, attempt == candidate, checkPending else { return }
        status = "Local-network check sent. Waiting for a reply."
        try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        guard op == generation, attempt == candidate, checkPending else { return }
        tick()
      } catch is SessionBackpressure {
        // The absolute deadline remains armed; capacity refusal is not proof that LAN is alive.
      } catch is CancellationError {
        return
      } catch {
        if op == generation, attempt == candidate { checkPending = false; failCandidate(error) }
      }
    }
  }
  func disconnect() {
    cancelRecovery()
    rendezvous.cancelTransferRequest()
    automaticPaused = true
    automaticAttempt = false
    allowing = false
    registered = false
    scheduleAutomatic()
    let old = connection
    let op = generation
    state = "Disconnected"
    status = "Disconnecting local network…"
    Task {
      try? await old?.disconnect()
      if op == generation { end() }
    }
    Task {
      try? await Task.sleep(for: .seconds(2))
      if op == generation { end() }
    }
  }
  func cancel(message: String = "Disconnected. Allow local-network connections to reconnect.") {
    cancelRecovery()
    rendezvous.cancelTransferRequest()
    automaticPaused = true
    connectionPaused = true
    end(message: message)
  }
  private func clearConnectionCheck() {
    checkPending = false; checkingPeerLoss = false; checkDeadline = nil
    checkTask?.cancel(); checkTask = nil
  }
  private func end(message: String = "Disconnected. Allow local-network connections to reconnect.", preserveListener: Bool = false) {
    Self.logger.notice("LAN owner ended: \(message, privacy: .public) state=\(self.state, privacy: .public) allowing=\(self.allowing)")
    automaticAttempt = false
    registered = false
    serviceRegistered = false
    localEndpoint = nil
    generation += 1
    candidate += 1
    allowing = false
    checking = false
    retiring = false
    startupDeadline = nil
    handshakeDeadline = nil
    clearConnectionCheck()
    deadlineWait.cancel()
    if preserveListener { listener?.newConnectionHandler = { socket in socket.cancel() } }
    else { listener?.newConnectionHandler = nil }
    listener?.stateUpdateHandler = nil
    listener?.serviceRegistrationUpdateHandler = nil
    listener?.service = nil
    if !preserveListener {
      listener?.cancel()
      listener = nil
      listenerReady = false
    }
    advertisement = nil
    let retiredTransport = transport
    Task { await retiredTransport?.close() }
    transport = nil
    let old = connection
    connection = nil
    work?.cancel()
    work = nil
    authenticatedPeer = nil
    if !preserveListener { admission.clear() }
    peers.release("lan")
    Task { await old?.close() }
    state = "Disconnected"
    status = message
  }
}
