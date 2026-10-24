// SPDX-License-Identifier: GPL-3.0-or-later
// Owns manual and BLE-coordinated Bonjour admission and independently authenticated LAN sessions.
import AppKit
import Foundation
@preconcurrency import Network
import Observation
import OSLog

@Observable @MainActor final class MacLanSessionModel {
  private static let logger = Logger(subsystem: "io.github.anisharyal09.anice", category: "LAN lifecycle")
  private(set) var state = "Disconnected" { didSet { channelStateChanged(); scheduleAutomatic() } }
  private(set) var status = "Allow your trusted Android to connect over the local network."
  private(set) var allowing = false
  private(set) var receivedChecks = 0
  private(set) var authenticatedPeer: DeviceIdentity?
  private(set) var automatic: Bool
  private let preferences: UserDefaults?
  let rendezvous = LanRendezvous()
  private var automaticPaused = false
  private var automaticAttempt = false
  private var sleeping = false
  private var quitting = false
  private var registered = false
  private var serviceRegistered = false
  private var listenerReady = false
  private var localPathAvailable = true
  @ObservationIgnored private var pathMonitor: NWPathMonitor?
  private var automaticTask: Task<Void, Never>?
  private var automaticGate = LanAttemptGate()

  func setAutomatic(_ enabled: Bool) {
    automatic = enabled
    preferences?.set(enabled, forKey: "lan.automatic")
    automaticPaused = false
    automaticGate.trigger()
    if !enabled, automaticAttempt, state != "Secured" { end() }
    scheduleAutomatic()
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
    guard automatic, !automaticPaused, !sleeping, !quitting,
      rendezvous.channel != nil, rendezvous.remote != 0 else { return false }
    automaticGate.trigger()
    rendezvous.request()
    scheduleAutomatic()
    return true
  }
  private func scheduleAutomatic() {
    automaticTask?.cancel()
    automaticTask = Task { [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled else { return }
      let eligible = self.automatic && !self.automaticPaused && !self.sleeping && !self.quitting && self.localPathAvailable
      self.automaticGate.update(channel: self.rendezvous.channel?.descriptor.instance, eligible: eligible,
        remoteEligible: self.rendezvous.remote != nil && self.rendezvous.remote != 0,
        ready: false, requests: self.rendezvous.requests)
      self.rendezvous.update(!eligible ? 0 : self.state == "Secured" ? 3 : self.registered ? 2 : 1)
      if !self.localPathAvailable, self.automatic, !self.automaticPaused, !self.sleeping, !self.quitting { return }
      guard eligible, let channel = self.rendezvous.channel, let remote = self.rendezvous.remote,
        remote != 0 else {
        if self.automaticAttempt, self.state != "Secured" { self.end() }
        return
      }
      if self.state == "Secured" || self.allowing { _ = self.automaticGate.claim(); return }
      guard self.automaticGate.claim() else { return }
      self.allow(selected: channel.descriptor.peer, bluetoothAllowing: false, automatically: true)
    }
  }

  private let identity: IdentityService
  private let store: @MainActor () async throws -> PeerTrustStore
  private let peers: SessionPeerReservation
  private let startListener: @MainActor (NWListener) -> Void
  private(set) var listener: NWListener?
  private var transport: LanTcpTransport?
  private var trustLocation: URL?
  var channelStateChanged: () -> Void = {}
  var channelCapacityChanged: () -> Void = {}
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
    startListener: @escaping @MainActor (NWListener) -> Void = { $0.start(queue: DispatchQueue(label: "aniCe LAN listener")) },
    store: @escaping @MainActor () async throws -> PeerTrustStore
  ) {
    self.preferences = preferences
    self.startListener = startListener
    // Absent means the user never chose; an explicit stored false still disables automation.
    self.automatic = preferences.map { ($0.object(forKey: "lan.automatic") as? Bool) ?? true } ?? false
    self.identity = identity
    self.peers = peers
    self.store = store
    rendezvous.changed = { [weak self] in self?.scheduleAutomatic() }
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
            self?.end()
          }
        })
    }
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.sleeping = false; self?.scheduleAutomatic() }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.quitting = true; self?.end() }
      })
  }
  func allow(selected: DeviceIdentity?, bluetoothAllowing: Bool, automatically: Bool = false) {
    if !automatically { automaticPaused = false; automaticGate.trigger() }
    guard !bluetoothAllowing || peers.peer != nil else {
      status =
        "Finish or stop the current Bluetooth admission before allowing a local-network connection."
      return
    }
    end(preserveListener: automatic && !automaticPaused && !sleeping && !quitting)
    admission.clear() // Only a newly authorized Allow event starts another bounded admission window.
    automaticAttempt = automatically
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
        let txt = NWTXTRecord(["v": "2"])
        advertisement = NWListener.Service(
          name: "aniCe-" + UUID().uuidString.lowercased(), type: "_anice._tcp", txtRecord: txt)
        server.service = advertisement
        server.stateUpdateHandler = { [weak self] state in
          Task { @MainActor in
            guard let self, op == self.generation else { return }
            switch state {
            case .waiting(let error) where Self.waitsForNetwork(error):
              self.listenerReady = false
              self.registered = false
              self.startupDeadline = nil
              self.status = "Waiting for network…"
              self.scheduleAutomatic()
              self.maintain()
            case .ready:
              self.listenerReady = true
              self.registered = self.serviceRegistered && self.allowing && !self.admission.admitted
              self.scheduleAutomatic()
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
              self.registered = self.listenerReady
              self.scheduleAutomatic()
              self.startupDeadline = nil
              self.admission.open(ProcessInfo.processInfo.systemUptime)
              if !self.admission.admitted {
                self.state = "Disconnected"
                self.status = self.automaticAttempt
                  ? "Waiting for \(target.deviceName) to connect automatically…"
                  : "Waiting for \(target.deviceName). On that phone, connect over local network."
              }
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
        maintain()
      } catch { if op == generation { failWindow(error.localizedDescription) } }
    }
  }
  private func admit(_ socket: NWConnection, target: DeviceIdentity, trust: PeerTrustStore, op: Int)
  {
    guard allowing, !retiring, admission.claim(ProcessInfo.processInfo.systemUptime) else {
      socket.cancel()
      return
    }
    registered = false
    listener?.service = nil
    state = "Connecting"
    status = "Authenticating your trusted Android…"
    handshakeDeadline = ProcessInfo.processInfo.systemUptime + 30
    let attempt = candidate
    let tcp = LanTcpTransport(socket, profile: .lanTransfer)
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
          changed: { [weak self] in Task { @MainActor in
            guard let self, op == self.generation, attempt == self.candidate else { return }
            self.maintain(); self.channelCapacityChanged()
          } }, profile: .lanTransfer)
        connection = engine
        maintain()
        await tcp.start(
          deliver: { [weak self] bytes in
            try await engine.receive(bytes)
            if bytes.first == 3 { await self?.handshakeReceived(op, attempt) }
            if await engine.isClosed { await self?.peerClosed(op, attempt) }
          },
          ended: { [weak self] error in
            Task { @MainActor in
              guard let self, op == self.generation, attempt == self.candidate else { return }
              self.failCandidate(error)
            }
          }, changed: { [weak self] in
            Task { @MainActor in
              guard let self, op == self.generation, attempt == self.candidate else { return }
              self.channelCapacityChanged()
              self.maintain()
            }
          })
      } catch { if op == generation, attempt == candidate { failCandidate(error) } }
    }
  }
  private func handshakeReceived(_ op: Int, _ attempt: Int) {
    guard op == generation, attempt == candidate else { return }
    handshakeDeadline = ProcessInfo.processInfo.systemUptime + 10
    maintain()
  }
  private func peerClosed(_ op: Int, _ attempt: Int) {
    guard op == generation, attempt == candidate else { return }
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
      authenticatedPeer = peer
      handshakeDeadline = nil
      state = "Secured"
      status = "Secured with \(peer.deviceName) · \(peer.fingerprint.prefix(8))."
      maintain()
    } catch { if op == generation, attempt == candidate { failCandidate(error) } }
  }
  private func received(_ bytes: Data, _ op: Int, _ attempt: Int) async {
    guard op == generation, attempt == candidate else { return }
    if await applicationDataReceived(bytes) { return }
    guard bytes == Data("aniCe connection check".utf8) else { return }
    receivedChecks += 1
    status = "Secured. Local-network connection check received."
  }
  private func maintain() {
    guard allowing else { return }
    let op = generation
    let attempt = candidate
    deadlineWait.schedule(now: { ProcessInfo.processInfo.systemUptime }, deadline: { [weak self] in
      guard let self, op == self.generation, attempt == self.candidate else { return nil }
      let session: Int64?
      if self.checking { session = nil } else { session = await self.connection?.nextDeadline() }
      guard op == self.generation, attempt == self.candidate else { return nil }
      return [self.startupDeadline, self.admission.admitted ? self.handshakeDeadline : self.admission.deadline,
        session.map { Double($0) / 1000 }].compactMap { $0 }.min()
    }, fire: { [weak self] in
      guard let self, op == self.generation, attempt == self.candidate else { return }
      self.tick()
    })
  }
  private func tick() {
    defer { maintain() }
    let now = ProcessInfo.processInfo.systemUptime
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
    guard !checking, let connection else { return }
    checking = true
    let op = generation
    let attempt = candidate
    Task { [weak self] in
      do { try await connection.tick() } catch {
        if let self, op == self.generation, attempt == self.candidate { self.failCandidate(error) }
      }
      if let self, op == self.generation, attempt == self.candidate { self.checking = false; self.maintain() }
    }
  }
  private func failCandidate(_ error: Error) {
    Self.logger.notice("LAN session ended: \(String(describing: error), privacy: .public)")
    let secured = state == "Secured"
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
        failWindow("Identity access changed. Check access before reconnecting.")
      } else {
        retireSession(reason: "Local-network session ended: \(error.localizedDescription).")
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
        self.maintain()
      }
    }
  }
  private func failWindow(_ message: String) {
    end(message: message)
    state = "Failed"
  }
  func retireSession(reason: String) {
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
      Task { @MainActor in self?.localPathChanged(available) }
    }
    monitor.start(queue: DispatchQueue(label: "aniCe LAN availability"))
  }
  func localPathChanged(_ available: Bool) {
    guard localPathAvailable != available else { return }
    localPathAvailable = available
    // Only an external unavailable-to-available edge rearms the attempt gate, never registration.
    if available { automaticGate.trigger() }
    scheduleAutomatic()
  }
  func checkConnection() {
    guard state == "Secured", let connection else { return }
    let op = generation
    Task {
      do {
        try await connection.sendData(Data("aniCe connection check".utf8))
        if op == generation { status = "Secured. Local-network connection check sent." }
      } catch is SessionBackpressure {
        if op == generation { status = "Local-network connection is busy. Try again." }
      } catch { if op == generation { failCandidate(error) } }
    }
  }
  func disconnect() {
    automaticPaused = true
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
    automaticPaused = true
    end(message: message)
  }
  private func end(message: String = "Disconnected. Allow local-network connections to reconnect.", preserveListener: Bool = false) {
    Self.logger.notice("LAN owner ended: \(message, privacy: .public) state=\(self.state, privacy: .public) allowing=\(self.allowing)")
    automaticAttempt = false
    registered = false
    serviceRegistered = false
    generation += 1
    candidate += 1
    allowing = false
    checking = false
    retiring = false
    startupDeadline = nil
    handshakeDeadline = nil
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
