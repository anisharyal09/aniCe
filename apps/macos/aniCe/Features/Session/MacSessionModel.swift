// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import Observation

@Observable @MainActor final class MacSessionModel {
  var state = "Disconnected"
  var status = "Allow your trusted Android device to connect."
  var selectedPeer: DeviceIdentity?
  var allowing = false
  var remaining = 0
  var receivedChecks = 0
  var beforeAllow: () -> Void = {}
  private let now: () -> TimeInterval
  private let identity: IdentityService
  private let adapter: any SessionPeripheralAdapter
  private let store: @MainActor () async throws -> PeerTrustStore
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
  private var timer: Timer?
  private var checking = false
  private var work: Task<Void, Never>?
  private var inputCount = 0
  private var inputBytes = 0
  private var observers = [NSObjectProtocol]()
  init(
    identity: IdentityService, adapter: any SessionPeripheralAdapter,
    store: @escaping @MainActor () async throws -> PeerTrustStore,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.now = now
    self.identity = identity
    self.adapter = adapter
    self.store = store
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } })
  }
  func allow() {
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
    // The finite startup task owns the model; stored radio/timer callbacks remain weak.
    work = Task { [self] in
      do {
        let local = try await identity.publicIdentity()
        let trust = try await store()
        if let target {
          let matches = trust.list(localFingerprint: local.fingerprint).filter {
            $0.peer.deviceId == target.deviceId && $0.peer.fingerprint == target.fingerprint
              && $0.peer.publicKey == target.publicKey
          }
          guard matches.count == 1 else { throw SessionFailure.untrustedPeer }
        }
        guard op == generation else { return }
        installCallbacks(op, target: target)
        startupDeadline = now() + 10
        adapter.begin(
          event: { [weak self] event in
            guard let self, op == self.generation, self.allowing else { return }
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
                self.status =
                  target.map { "Waiting for \($0.deviceName). On that phone, tap Connect." }
                  ?? "Waiting for one trusted Android. On your phone, tap Connect."
              }
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
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
      } catch {
        if op == generation {
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
            secured: { [weak self] in await self?.secured(op, candidate) })
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
          self.inputCount -= 1
          self.inputBytes -= bytes.count
          if await engine.isClosed {
            self.cancel()
            self.status = "Disconnected by your Android device."
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
      handshakeDeadline = nil
      state = "Secured"
      status = "Secured with \(peer.deviceName) · \(peer.fingerprint.prefix(8))."
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
  func tick() {
    guard allowing else { return }
    let now = now()
    remaining = Int(ceil(max(0, (windowDeadline ?? now) - now)))
    if let startupDeadline, now >= startupDeadline {
      failWindow("Bluetooth took too long to start. Retry.")
      return
    }
    if admitted, let handshakeDeadline, now >= handshakeDeadline {
      failCandidate("Authentication took too long. Retry from Android.")
      return
    }
    if !admitted, let windowDeadline, now >= windowDeadline {
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
      if op == generation, candidate == attempt { checking = false }
    }
  }
  private func finish(_ error: Error, expiration: SessionExpiry?, peerClosed: Bool) {
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
    connection = nil
    work = nil
    Task { await old?.close() }
    state = "Failed"
    status = reason
    if wasSecured || !canResume { failWindow(reason) } else { adapter.resumeSessionAdvertising() }
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
    attempt += 1
    allowing = false
    admission.clear()
    checking = false
    timer?.invalidate()
    timer = nil
    remaining = 0
    startupDeadline = nil
    inputCount = 0
    inputBytes = 0
    handshakeDeadline = nil
    adapter.sessionWrite = nil
    adapter.sessionDisconnect = nil
    adapter.sessionAdmitted = nil
    adapter.stop()
    let old = connection
    connection = nil
    work = nil
    Task { await old?.close() }
    state = "Disconnected"
    status = "Disconnected. Allow connections to reconnect."
  }
}
