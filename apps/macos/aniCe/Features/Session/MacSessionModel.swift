// SPDX-License-Identifier: GPL-3.0-or-later
// Owns trusted BLE admission, session lifecycle and automatic availability for both Mac surfaces.
import AppKit
import Foundation
import Observation

@Observable @MainActor final class MacSessionModel {
  var state = "Disconnected"
  var status = "Allow your trusted Android device to connect."
  var selectedPeer: DeviceIdentity?
  var allowing = false
  var remaining: Int { allowing ? Int(ceil(max(0, (windowDeadline ?? now()) - now()))) : 0 }
  var receivedChecks = 0
  private(set) var automatic = false
  private var suspended = false
  private var sleeping = false
  private var quitting = false
  private var restart: Task<Void, Never>?
  private var cooldownUntil: TimeInterval?
  private let preferences: UserDefaults?
  var beforeAllow: () -> Void = {}
  private let now: () -> TimeInterval
  private let wait: (TimeInterval) async throws -> Void
  private let peers: SessionPeerReservation
  private(set) var authenticatedPeer: DeviceIdentity?
  private let identity: IdentityService
  private let adapter: any SessionPeripheralAdapter
  private let store: @MainActor () async throws -> PeerTrustStore
  private var trustLocation: URL?
  private var connection: SessionConnection?
  // Generation identifies the allow window; attempt separately identifies its one candidate.
  private var generation = 0
  private var attempt = 0
  private var admission = SessionAdmissionWindow()
  private var failures: Int { admission.failures }
  private var admitted: Bool { admission.admitted }
  private var windowDeadline: TimeInterval? { admission.deadline }
  private var handshakeDeadline: TimeInterval?
  private var startupDeadline: TimeInterval?
  @ObservationIgnored private let deadlineWait = SessionDeadlineWait()
  var maintenanceDeadline: TimeInterval? { deadlineWait.deadline }
  private var checking = false
  private var work: Task<Void, Never>?
  private var inputCount = 0
  private var inputBytes = 0
  private var observers = [NSObjectProtocol]()
  init(
    identity: IdentityService, adapter: any SessionPeripheralAdapter,
    store: @escaping @MainActor () async throws -> PeerTrustStore,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    preferences: UserDefaults? = nil,
    peers: SessionPeerReservation? = nil,
    wait: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
  ) {
    self.peers = peers ?? SessionPeerReservation()
    self.now = now
    self.identity = identity
    self.adapter = adapter
    self.store = store
    self.preferences = preferences
    self.wait = wait
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
          self.retireTrust()
        }
      })
    }
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.sleep() } })
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.wake() } })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.quit() } })
  }
  func restoreAutomatic() {
    guard preferences?.bool(forKey: "session.automatic") == true,
      preferences?.bool(forKey: "session.paused") != true else { return }
    automatic = true
    allow()
  }
  func setAutomatic(_ enabled: Bool) {
    cooldownUntil = nil
    automatic = enabled
    preferences?.set(enabled, forKey: "session.automatic")
    preferences?.set(false, forKey: "session.paused")
    preferences?.set(selectedPeer?.deviceId, forKey: "session.target")
    preferences?.set(selectedPeer?.fingerprint, forKey: "session.fingerprint")
    preferences?.removeObject(forKey: "session.local") // Explicit setup binds the current identity anew.
    if enabled {
      suspended = false
      if allowing {
        let current = connection
        Task { await current?.enableRenewal() }
      } else { allow() }
    } else { cancel() }
  }
  func suspendAutomatic() { suspended = true; cancel() }
  func resumeAutomatic() {
    suspended = false
    if automatic && !sleeping && !quitting && !allowing {
      if let until = cooldownUntil, now() < until { reopen(after: until - now()) }
      else { allow() }
    }
  }
  func sleep() { sleeping = true; cancel() }
  func wake() { sleeping = false; resumeAutomatic() }
  func quit() { quitting = true; cancel() }
  func retireTrust() {
    automatic = false
    preferences?.set(true, forKey: "session.paused")
    cancel()
  }
  private func reopen(after delay: TimeInterval = 0) {
    let old = connection
    cancel()
    guard automatic, !suspended, !sleeping, !quitting else { return }
    let op = generation
    let wait = wait
    status = delay > 0 ? "Waiting before allowing nearby connections." : "Waiting nearby."
    restart = Task { [weak self] in
      // Close keys before opening the next candidate slot; fresh sessions never overlap.
      await old?.close()
      if delay > 0 { try? await wait(delay) }
      guard let self, !Task.isCancelled, op == self.generation, self.automatic,
        !self.suspended, !self.sleeping, !self.quitting else { return }
      self.allow()
    }
  }
  func allow() {
    if automatic && (suspended || sleeping || quitting) { return }
    if automatic, let until = cooldownUntil, now() < until { return }
    cancel()
    beforeAllow()
    allowing = true
    status = "Starting Bluetooth…"
    receivedChecks = 0
    // Freeze the target for this window; window and companion share the editable selection.
    // Validate a remembered selection against the live journal before opening the radio.
    // Display-list loading is asynchronous and must not decide whether a window can start.
    let target = selectedPeer
    let op = generation
    // The finite startup task owns the model; stored radio/deadline callbacks remain weak.
    work = Task { [self] in
      do {
        let local = try await identity.publicIdentity()
        let trust = try await store()
        let peers = trust.list(localFingerprint: local.fingerprint).filter { $0.peer.platform == "android" }
        if automatic && peers.isEmpty { throw SessionFailure.untrustedPeer }
        var target = target
        if automatic, let saved = preferences?.string(forKey: "session.target") {
          let matches = peers.filter { $0.peer.deviceId == saved && $0.peer.fingerprint == preferences?.string(forKey: "session.fingerprint") }
          guard matches.count == 1 else { throw SessionFailure.untrustedPeer }
          target = matches[0].peer
          selectedPeer = target
        }
        if automatic, let previous = preferences?.string(forKey: "session.local") {
          guard previous == local.fingerprint else { throw SessionFailure.untrustedPeer }
        }
        if automatic { preferences?.set(local.fingerprint, forKey: "session.local") }
        target = target ?? self.peers.peer
        if let target {
          let matches = trust.list(localFingerprint: local.fingerprint).filter {
            $0.peer.deviceId == target.deviceId && $0.peer.fingerprint == target.fingerprint
              && $0.peer.publicKey == target.publicKey
          }
          guard matches.count == 1 else { throw SessionFailure.untrustedPeer }
        }
        guard op == generation else { return }
        guard self.peers.acquire("ble", peer: target, local: local.fingerprint) else {
          cancel()
          status = "Waiting for the other device connection to end."
          if automatic { reopen(after: 2) }
          return
        }
        trustLocation = trust.location
        installCallbacks(op, target: target)
        adapter.sessionChanged = { [weak self] in
          guard let self, op == self.generation else { return }
          self.tick()
        }
        startupDeadline = now() + 10
        adapter.begin(
          event: { [weak self] event in
            guard let self, op == self.generation, self.allowing else { return }
            defer { self.startMaintenance() }
            switch event {
            case .permissionPending:
              self.startupDeadline = nil
              self.status = "Allow Bluetooth access to accept connections."
            case .initializing:
              if self.startupDeadline == nil { self.startupDeadline = self.now() + 10 }
            case .available: self.adapter.publish()
            case .published: self.adapter.advertise()
            case .advertising:
              self.startupDeadline = nil
              self.admission.open(self.now())
              if !self.admitted && self.failures == 0 {
                self.status = self.automatic ? "Waiting nearby." :
                  target.map { "Waiting for \($0.deviceName). On that phone, tap Connect." }
                  ?? "Waiting for one trusted Android. On your phone, tap Connect."
              }
            case .off, .resetting:
              if self.automatic {
                self.startupDeadline = nil
                self.status = "Waiting for Bluetooth."
              } else { self.failWindow("Turn on Bluetooth, then retry.") }
            default:
              self.failWindow(
                "Bluetooth became unavailable. Check permissions and Bluetooth, then retry.")
            }
          },
          read: { matches, offset in
            guard matches else { return .unknownCharacteristic }
            guard offset == 0 else { return .invalidOffset }
            guard let nonce = try? PeripheralDiscoverySession.secureNonce(),
              let data = try? BlePayloadCodec.encode(nonce: nonce)
            else { return .unavailable }
            return .value(data)
          })
        startMaintenance()
      } catch {
        if op == generation {
          automatic = false
          preferences?.set(true, forKey: "session.paused")
          failWindow("Trusted devices or identity access are unavailable. Check access and retry.")
        }
      }
    }
  }
  private func installCallbacks(_ op: Int, target: DeviceIdentity?) {
    // Subscription admits one candidate, not an authenticated identity. EDHOC enforces the target.
    adapter.sessionAdmitted = { [weak self] in
      guard let self, op == self.generation, self.allowing, self.admission.claim(self.now()) else {
        return false
      }
      self.handshakeDeadline = self.now() + 30
      self.startMaintenance()
      self.state = "Connecting"
      self.status = "Authenticating a trusted device…"
      let candidate = self.attempt
      // Retain the attempt owner until construction finishes, not in channel callbacks.
      self.work = Task { [self] in
        do {
          let trust = try await self.store()
          let handshake = try await SessionHandshakeEngine.responder(
            identity: self.identity, trust: trust, selectedPeer: target)
          guard op == self.generation, candidate == self.attempt, self.admitted else {
            await handshake.close()
            return
          }
          self.connection = SessionConnection(
            handshake: handshake, responder: true,
            capacity: { [weak self] bytes in await self?.capacity(bytes, op, candidate) ?? false },
            submit: { [weak self] bytes in
              guard let self else { throw SessionFailure.cancelled }
              try await self.submit(bytes, op, candidate)
            },
            data: { [weak self] bytes in await self?.received(bytes, op, candidate) },
            secured: { [weak self] in await self?.secured(op, candidate) }, controls: true,
            renew: self.automatic,
            changed: { [weak self] in Task { @MainActor in
              guard let self, op == self.generation, candidate == self.attempt else { return }
              self.startMaintenance()
            } })
          self.startMaintenance()
        } catch {
          if op == self.generation, candidate == self.attempt {
            self.failCandidate("Authentication could not start. Retry from Android.")
          }
        }
      }
      return true
    }
    adapter.sessionWrite = { [weak self] bytes in
      guard let self, op == self.generation, self.admitted, self.inputCount < 8,
        self.inputBytes + bytes.count <= 32768
      else { return false }
      let candidate = self.attempt
      self.inputCount += 1
      self.inputBytes += bytes.count
      // Chain bounded input work so handshake, readiness and records preserve transport order.
      let previous = self.work
      self.work = Task {
        await previous?.value
        guard op == self.generation, candidate == self.attempt, self.admitted,
          let engine = self.connection
        else { return }
        do {
          try await engine.receive(bytes)
          guard op == self.generation, candidate == self.attempt else { return }
          if bytes.first == 3 { self.handshakeDeadline = self.now() + 10 }
          self.startMaintenance()
          self.inputCount -= 1
          self.inputBytes -= bytes.count
          if await engine.isClosed {
            if self.automatic { self.reopen() }
            else { self.cancel(); self.status = "Disconnected by your Android device." }
          }
        } catch {
          if op == self.generation, candidate == self.attempt {
            let expiration = await engine.expiration
            let peerClosed = await engine.closedByPeer
            guard op == self.generation, candidate == self.attempt else { return }
            self.finish(error, expiration: expiration, peerClosed: peerClosed)
          }
        }
      }
      return true
    }
    adapter.sessionDisconnect = { [weak self] in
      guard let self, op == self.generation, self.admitted else { return }
      self.failCandidate("Connection ended. Retry from Android.")
    }
  }
  private func capacity(_ bytes: Int, _ op: Int, _ candidate: Int) -> Bool {
    op == generation && candidate == attempt && adapter.sessionCapacity(bytes)
  }
  private func submit(_ bytes: Data, _ op: Int, _ candidate: Int) async throws {
    guard op == generation, candidate == attempt, admitted else { throw SessionFailure.cancelled }
    try await adapter.sendSession(bytes)
    guard op == generation, candidate == attempt else { throw SessionFailure.cancelled }
  }
  private func secured(_ op: Int, _ candidate: Int) async {
    guard op == generation, candidate == attempt, let connection else { return }
    do {
      let peer = try await connection.authenticatedPeer()
      guard op == generation, candidate == attempt else { return }
      guard peers.authenticate("ble", peer: peer) else { throw SessionFailure.untrustedPeer }
      authenticatedPeer = peer
      handshakeDeadline = nil
      state = "Secured"
      status = "Secured with \(peer.deviceName) · \(peer.fingerprint.prefix(8))."
      // Every authenticated operation validates current identity protection and peer trust.
      startMaintenance()
    } catch {
      if op == generation, candidate == attempt {
        failCandidate("The authenticated device is no longer available. Retry from Android.")
      }
    }
  }
  private func received(_ bytes: Data, _ op: Int, _ candidate: Int) {
    guard op == generation, candidate == attempt, bytes == Data("aniCe connection check".utf8)
    else { return }
    receivedChecks += 1
    status = "Secured. Connection check received."
  }
  private func startMaintenance() {
    guard allowing else { return }
    let op = generation
    let candidate = attempt
    deadlineWait.schedule(now: now, deadline: { [weak self] in
      guard let self, op == self.generation, candidate == self.attempt else { return nil }
      let session: Int64?
      if self.checking { session = nil } else { session = await self.connection?.nextDeadline() }
      guard op == self.generation, candidate == self.attempt else { return nil }
      return [self.startupDeadline, self.admitted ? self.handshakeDeadline : self.windowDeadline,
        self.adapter.sessionDeadline, session.map { Double($0) / 1000 }].compactMap { $0 }.min()
    }, fire: { [weak self] in
      guard let self, op == self.generation, candidate == self.attempt else { return }
      self.tick()
    })
  }
  func tick() {
    guard allowing else { return }
    defer { startMaintenance() }
    let now = now()
    if let startupDeadline, now >= startupDeadline {
      failWindow("Bluetooth took too long to start. Retry.")
      return
    }
    if admitted, let handshakeDeadline, now >= handshakeDeadline {
      failCandidate("Authentication took too long. Retry from Android.")
      return
    }
    if !admitted, let windowDeadline, now >= windowDeadline {
      if automatic {
        reopen()
        return
      }
      cancel()
      status = "Connection window expired. Choose Allow connections to reopen it."
      return
    }
    do { try adapter.tickSessionTransport() } catch {
      failCandidate("Fragment assembly timed out. Retry from Android.")
      return
    }
    guard admitted, !checking, let connection else { return }
    checking = true
    let op = generation
    let candidate = attempt
    Task {
      do { try await connection.tick() } catch {
        if op == generation, candidate == attempt {
          let expiration = await connection.expiration
          let peerClosed = await connection.closedByPeer
          guard op == generation, candidate == attempt else { return }
          finish(error, expiration: expiration, peerClosed: peerClosed)
        }
      }
      if op == generation, candidate == attempt { checking = false; startMaintenance() }
    }
  }
  private func finish(_ error: Error, expiration: SessionExpiry?, peerClosed: Bool) {
    if automatic {
      if state != "Secured" {
        failCandidate("That connection could not authenticate. Waiting for a trusted device.")
      } else if error as? SessionFailure == .untrustedPeer {
        retireTrust()
        status = "Trust changed. Check your paired devices before enabling automatic connections."
      } else { reopen(after: 2) }
      return
    }
    if let failure = error as? SessionFailure, failure == .controlTimeout {
      cancel()
      status = "Your Android device stopped responding. Allow connections to reconnect."
      return
    }
    if peerClosed {
      cancel()
      status = "Your Android device ended the session."
      return
    }
    if let failure = error as? SessionFailure, failure == .expired {
      switch expiration {
      case .idle:
        cancel()
        status = "Idle for 2 minutes. Allow connections to reconnect."
      case .lifetime:
        cancel()
        status = "The one-hour session ended. Allow connections to reconnect."
      case .recordLimit:
        cancel()
        status = "Session message limit reached. Allow connections to reconnect."
      case .readiness, nil:
        failCandidate("Connection confirmation timed out. Retry from Android.")
      }
    } else if let failure = error as? SessionFailure, failure == .untrustedPeer {
      failCandidate(
        "This device is not allowed for this connection. Check your selection and trusted devices.")
    } else if let failure = error as? SessionFailure, failure == .cancelled {
      failCandidate("The secure connection was interrupted. Retry from Android.")
    } else {
      failCandidate("The secure connection was interrupted. Retry from Android.")
    }
  }

  private func failCandidate(_ reason: String) {
    let wasSecured = state == "Secured"
    let canResume = admission.retire(now())
    attempt += 1
    checking = false
    inputBytes = 0
    inputCount = 0
    adapter.retirePairingConnection()
    let old = connection
    work = nil
    state = automatic ? "Disconnected" : "Failed"
    status = automatic ? "Waiting nearby." : reason
    if wasSecured || !canResume {
      if automatic {
        if !wasSecured && failures >= 5 { cooldownUntil = now() + 120 }
        reopen(after: wasSecured ? 2 : failures >= 5 ? 120 : 0)
      } else { failWindow(reason) }
    } else {
      connection = nil
      startMaintenance()
      let op = generation, candidate = attempt
      work = Task { [weak self] in
        await old?.close()
        guard let self, op == self.generation, candidate == self.attempt, self.allowing else { return }
        self.adapter.resumeSessionAdvertising()
      }
    }
  }
  private func failWindow(_ reason: String) {
    cancel()
    state = "Failed"
    status = reason
  }
  func checkConnection() {
    guard state == "Secured", let connection else { return }
    let op = generation
    Task {
      do {
        try await connection.sendData(Data("aniCe connection check".utf8))
        if op == generation { status = "Secured. Connection check sent." }
      } catch is SessionBackpressure {
        if op == generation { status = "Connection is busy. Try again." }
      } catch {
        if op == generation {
          failWindow("Connection check could not be sent. Allow connections and retry.")
        }
      }
    }
  }
  func disconnect() {
    // Stop outranks renewal/recovery; persist the pause before any suspended close.
    automatic = false
    preferences?.set(true, forKey: "session.paused")
    guard let connection else {
      cancel()
      return
    }
    status = "Disconnecting…"
    let op = generation
    Task {
      try? await connection.disconnect()
      if op == generation { cancel() }
    }
    Task {
      try? await Task.sleep(for: .seconds(2))
      if op == generation { cancel() }
    }
  }
  func cancel() {
    // Invalidate callbacks and suspended signing before retiring transport/key ownership.
    generation += 1
    restart?.cancel()
    restart = nil
    attempt += 1
    allowing = false
    admission.clear()
    checking = false
    deadlineWait.cancel()
    startupDeadline = nil
    inputCount = 0
    inputBytes = 0
    handshakeDeadline = nil
    adapter.sessionWrite = nil
    adapter.sessionDisconnect = nil
    adapter.sessionChanged = nil
    adapter.sessionAdmitted = nil
    adapter.stop()
    let old = connection
    connection = nil
    work = nil
    authenticatedPeer = nil
    peers.release("ble")
    Task { await old?.close() }
    state = "Disconnected"
    status = "Disconnected. Allow connections to reconnect."
  }
}
