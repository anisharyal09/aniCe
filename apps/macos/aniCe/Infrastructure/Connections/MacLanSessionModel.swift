// SPDX-License-Identifier: GPL-3.0-or-later
// Owns explicit Bonjour admission and pinned LAN sessions shared by both Mac surfaces.
import AppKit
import Foundation
@preconcurrency import Network
import Observation

@Observable @MainActor final class MacLanSessionModel {
  private(set) var state = "Disconnected" { didSet { channelStateChanged() } }
  private(set) var status = "Allow your trusted Android to connect over the local network."
  private(set) var allowing = false
  private(set) var receivedChecks = 0
  private(set) var authenticatedPeer: DeviceIdentity?
  private let identity: IdentityService
  private let store: @MainActor () async throws -> PeerTrustStore
  private let peers: SessionPeerReservation
  private var listener: NWListener?
  private var transport: LanTcpTransport?
  private var trustLocation: URL?
  var channelStateChanged: () -> Void = {}
  var channelCapacityChanged: () -> Void = {}
  var applicationDataReceived: (Data) -> Bool = { _ in false }
  var channelToken: String? { state == "Secured" && connection != nil ? "\(generation)-\(candidate)":nil }
  func sendData(_ bytes: Data) async throws {
    guard let connection, state == "Secured", transport?.capacity(bytes.count + 31) == true, await connection.applicationAvailable else { throw SessionBackpressure() }
    let token=channelToken
    try await connection.sendData(bytes)
    guard channelToken==token else { throw SessionFailure.cancelled }
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
    store: @escaping @MainActor () async throws -> PeerTrustStore
  ) {
    self.identity = identity
    self.peers = peers
    self.store = store
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
          MainActor.assumeIsolated { self?.cancel() }
        })
    }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.cancel() }
      })
  }
  func allow(selected: DeviceIdentity?, bluetoothAllowing: Bool) {
    guard !bluetoothAllowing || peers.peer != nil else {
      status =
        "Finish or stop the current Bluetooth admission before allowing a local-network connection."
      return
    }
    cancel()
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
        let target = selected ?? (active.count == 1 ? active.first : nil)
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
        let server = try NWListener(using: parameters, on: .any)
        listener = server
        // The service name is an ephemeral locator, never an identity or authentication claim.
        let txt = NWTXTRecord(["v": "1"])
        advertisement = NWListener.Service(
          name: "aniCe-" + UUID().uuidString.lowercased(), type: "_anice._tcp", txtRecord: txt)
        server.service = advertisement
        server.stateUpdateHandler = { [weak self] state in
          Task { @MainActor in
            guard let self, op == self.generation else { return }
            switch state {
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
              self.startupDeadline = nil
              self.admission.open(ProcessInfo.processInfo.systemUptime)
              if !self.admission.admitted {
                self.state = "Disconnected"
                self.status =
                  "Waiting for \(target.deviceName). On that phone, connect over local network."
              }
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
        server.start(queue: DispatchQueue(label: "aniCe LAN listener"))
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
    listener?.service = nil
    state = "Connecting"
    status = "Authenticating your trusted Android…"
    handshakeDeadline = ProcessInfo.processInfo.systemUptime + 30
    let attempt = candidate
    let tcp = LanTcpTransport(socket)
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
          } })
        connection = engine
        tcp.changed = { [weak self] in
          self?.channelCapacityChanged()
          guard let self, op == self.generation, attempt == self.candidate else { return }
          self.tick()
        }
        maintain()
        tcp.start(
          deliver: { [weak self] bytes in
            guard let self, op == self.generation, attempt == self.candidate else {
              throw SessionFailure.cancelled
            }
            try await engine.receive(bytes)
            guard op == self.generation, attempt == self.candidate else { return }
            if bytes.first == 3 {
              self.handshakeDeadline = ProcessInfo.processInfo.systemUptime + 10
              self.maintain()
            }
            if await engine.isClosed {
              self.cancel(message: "Your Android ended the local-network session.")
            }
          },
          ended: { [weak self] error in
            guard let self, op == self.generation, attempt == self.candidate else { return }
            self.failCandidate(error)
          })
      } catch { if op == generation, attempt == candidate { failCandidate(error) } }
    }
  }
  private func capacity(_ size: Int, _ op: Int, _ attempt: Int) -> Bool {
    op == generation && attempt == candidate && transport?.capacity(size) == true
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
  private func received(_ bytes: Data, _ op: Int, _ attempt: Int) {
    guard op == generation, attempt == candidate else { return }
    if applicationDataReceived(bytes) { return }
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
        self.transport?.nextDeadline, session.map { Double($0) / 1000 }].compactMap { $0 }.min()
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
      cancel(message: "Local-network Allow window expired.")
      return
    }
    if let handshakeDeadline, now >= handshakeDeadline {
      failCandidate(SessionFailure.expired)
      return
    }
    do { try transport?.tick() } catch {
      failCandidate(error)
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
    let secured = state == "Secured"
    let resume = admission.retire(ProcessInfo.processInfo.systemUptime)
    candidate += 1
    handshakeDeadline = nil
    checking = false
    transport?.close()
    transport = nil
    let old = connection
    connection = nil
    if secured || !resume || error is IdentityError {
      failWindow(
        "Local-network session ended: \(error.localizedDescription). Open Connection details and retry Local network.")
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
    cancel(message: message)
    state = "Failed"
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
    let old = connection
    let op = generation
    state = "Disconnected"
    status = "Disconnecting local network…"
    Task {
      try? await old?.disconnect()
      if op == generation { cancel() }
    }
    Task {
      try? await Task.sleep(for: .seconds(2))
      if op == generation { cancel() }
    }
  }
  func cancel(message: String = "Disconnected. Allow local-network connections to reconnect.") {
    generation += 1
    candidate += 1
    allowing = false
    checking = false
    retiring = false
    startupDeadline = nil
    handshakeDeadline = nil
    deadlineWait.cancel()
    listener?.newConnectionHandler = nil
    listener?.stateUpdateHandler = nil
    listener?.serviceRegistrationUpdateHandler = nil
    listener?.cancel()
    listener = nil
    advertisement = nil
    transport?.close()
    transport = nil
    let old = connection
    connection = nil
    work?.cancel()
    work = nil
    authenticatedPeer = nil
    admission.clear()
    peers.release("lan")
    Task { await old?.close() }
    state = "Disconnected"
    status = message
  }
}
