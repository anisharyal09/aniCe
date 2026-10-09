// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreImage.CIFilterBuiltins
import Observation

@Observable @MainActor final class MacPairingModel {
  var trustRemoved: () -> Void = {}
  var beforePairing: () -> Void = {}
  var afterPairing: () -> Void = {}
  var status = "Choose how to pair your Android device."
  var phase = "idle"
  var active = false
  var qrText: String?
  var qrImage: NSImage?
  var pin: String?
  var peer: DeviceIdentity?
  var peers: [PeerTrustRecord] = []
  // Presentation only; session admission resolves trust directly from the store.
  var hasTrustedAndroid: Bool {
    peers.contains { $0.active && $0.peer.platform == "android" }
  }
  var trustRecoveryNeeded = false
  var remaining = 0
  private let identity: IdentityService
  private let discovery: MacDiscoveryModel
  private let makeStore: @Sendable () throws -> PeerTrustStore
  private var store: PeerTrustStore?
  private var engine: PairingEngine?
  private var generation = 0
  private var timer: Timer?
  private var work: Task<Void, Never>?
  private var deadline: TimeInterval?
  private var startedRadio = false
  private var observers: [NSObjectProtocol] = []
  init(
    identity: IdentityService, discovery: MacDiscoveryModel,
    makeStore: @escaping @Sendable () throws -> PeerTrustStore = { try PeerTrustStore() }
  ) {
    self.identity = identity
    self.discovery = discovery
    self.makeStore = makeStore
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } })
  }
  func start(_ method: PairingMethod) {
    beforePairing()
    cancel()
    active = true
    phase = "preparing"
    status = "Preparing a new pairing invitation…"
    let op = generation
    let cleanup = work
    Task { [self] in
      await cleanup?.value
      do {
        let factory = self.makeStore
        let store = try await Task.detached { try factory() }.value
        let engine = try await PairingEngine(
          method: method, identity: identity, store: store,
          send: { [weak self] data in
            await self?.send(data, operation: op)
          },
          event: { [weak self] state, peer in await self?.event(state, peer: peer, operation: op) })
        guard op == generation, active else {
          await engine.close()
          return
        }
        self.store = store
        trustRecoveryNeeded = false
        self.engine = engine
        qrText = await engine.qr?.text
        qrImage = qrText.flatMap(Self.renderQR)
        pin = await engine.pin
        discovery.adapter.pairingWrite = { [weak self] data in
          guard let self, self.active, self.generation == op else { return false }
          self.tick()
          guard self.active else { return false }
          self.enqueue(data, operation: op)
          return true
        }
        discovery.adapter.pairingDisconnect = { [weak self] in
          guard let self, self.active, self.generation == op else { return }
          guard self.phase != "cancelling" else { return }
          if self.phase == "paired" {
            self.cancel(message: self.status)
            return
          }
          let previous = self.work
          self.work = Task {
            await previous?.value
            if self.phase == "paired" {
              self.cancel(message: self.status)
              return
            }
            do {
              try await engine.abortAttempt()
              guard self.generation == op else { return }
              self.peer = nil
              self.phase = "invitation"
              self.deadline = nil
              self.status = "Connection ended. Try the invitation again."
            } catch { self.fail() }
          }
        }
        startedRadio = true
        discovery.start()
        phase = "starting"
        status = "Starting Bluetooth for this invitation…"
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        peers = store.list(localFingerprint: engine.local.fingerprint)
      } catch {
        guard op == generation else { return }
        if error is TrustStoreLoadError {
          trustRecoveryNeeded = true
          fail("Local trust records could not be verified. Reset local trust to pair again.")
        } else {
          fail()
        }
      }
    }
  }
  private func send(_ data: Data, operation: Int) {
    guard active, generation == operation else { return }
    tick()
    guard active else { return }
    do { try discovery.adapter.sendPairing(data) } catch { fail() }
  }
  private func enqueue(_ data: Data, operation: Int) {
    guard phase != "cancelling", let engine else { return }
    let previous = work
    work = Task {
      await previous?.value
      guard self.active, self.generation == operation else { return }
      do { try await engine.receive(data) } catch {
        guard self.generation == operation else { return }
        if error is IdentityError {
          self.fail("Identity access failed. Allow Keychain access, then start a fresh invitation.")
          return
        }
        // Authentication/framing failures retire one channel, not the invitation.
        self.discovery.adapter.retirePairingConnection()
        do {
          try await engine.abortAttempt()
          guard self.generation == operation else { return }
          self.peer = nil
          self.phase = "invitation"
          self.deadline = nil
          self.status =
            "That pairing attempt did not authenticate. Scan again or re-enter the code."
        } catch {
          self.fail(
            "This invitation is no longer available. Show a fresh QR code or six-digit code.")
        }
      }
    }
  }
  private func event(_ state: String, peer: DeviceIdentity?, operation: Int) {
    guard active, generation == operation, phase != "cancelling" else { return }
    self.peer = peer
    phase = state
    switch state {
    case "authenticating":
      deadline = ProcessInfo.processInfo.systemUptime + 30
      status = "Authenticating the pairing exchange…"
    case "approval":
      deadline = ProcessInfo.processInfo.systemUptime + 60
      status = "Verify this device, then approve pairing on both devices."
    case "saving":
      deadline = ProcessInfo.processInfo.systemUptime + 10
      status = "Saving trust and confirming peer storage…"
    case "paired":
      deadline = ProcessInfo.processInfo.systemUptime + 2
      status = "Pairing complete. Device saved as trusted."
      qrText = nil
      qrImage = nil
      pin = nil
      Task {
        guard let engine = self.engine else { return }
        let fingerprint = engine.local.fingerprint
        guard operation == self.generation else { return }
        self.peers = self.store?.list(localFingerprint: fingerprint) ?? []
      }
    default: break
    }
  }
  func approve() {
    guard let engine, phase == "approval" else { return }
    status = "Approved here. Waiting for the other device…"
    phase = "waiting"
    let op = generation
    let previous = work
    work = Task {
      await previous?.value
      guard self.active, self.generation == op else { return }
      do { try await engine.approve() } catch { self.fail() }
    }
  }
  func decline() {
    guard active, phase == "approval", let engine else { return }
    phase = "cancelling"
    status = "Declining pairing…"
    remaining = 0
    deadline = nil
    timer?.invalidate()
    timer = nil
    let op = generation
    let previous = work
    work = Task {
      await previous?.value
      guard self.active, self.generation == op else { return }
      try? await engine.decline()
      guard self.generation == op else { return }
      await self.discovery.adapter.drainPairing()
      guard self.generation == op else { return }
      self.cancel(message: "Pairing declined. Start a fresh invitation when ready.")
    }
  }
  func tick() {
    guard active, phase != "cancelling" else { return }
    discovery.session.tick()
    remaining = discovery.session.remainingSeconds
    if phase == "starting" {
      if remaining > 0 {
        phase = "invitation"
        status =
          "On Android, choose Find your Mac and scan this QR code or enter the displayed code."
      } else {
        status = discovery.session.message
      }
    }
    if startedRadio && !discovery.session.active {
      fail(
        remaining == 0 && discovery.session.state == .idle
          ? "Invitation expired. Show a fresh QR code or six-digit code to try again."
          : discovery.session.message)
      return
    }
    if let deadline, ProcessInfo.processInfo.systemUptime >= deadline {
      if phase == "paired" {
        cancel(message: status)
      } else {
        fail("Pairing timed out. Start a fresh invitation.")
      }
    }
  }
  func cancel(message: String = "Pairing stopped. Start a fresh invitation when ready.") {
    let wasActive = active
    generation += 1
    active = false
    timer?.invalidate()
    timer = nil
    deadline = nil
    startedRadio = false
    remaining = 0
    qrText = nil
    qrImage = nil
    pin = nil
    peer = nil
    phase = "idle"
    status = message
    discovery.adapter.pairingWrite = nil
    discovery.adapter.pairingDisconnect = nil
    discovery.stop()
    let old = engine
    engine = nil
    let previous = work
    work = Task {
      await previous?.value
      await old?.close()
      if wasActive && !self.active { self.afterPairing() }
    }
  }
  private func fail(
    _ message: String =
      "Pairing could not finish. Check Bluetooth and identity access, then start a fresh invitation."
  ) {
    cancel(message: message)
    phase = "failed"
  }
  private static func renderQR(_ text: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let image = filter.outputImage else { return nil }
    let white = CIImage(color: .white).cropped(to: image.extent.insetBy(dx: -4, dy: -4))
    let padded = image.composited(over: white).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    guard let cg = CIContext().createCGImage(padded, from: padded.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
  }
  func refresh() async {
    do {
      let local = try await identity.publicIdentity()
      let store = try self.store ?? PeerTrustStore()
      self.store = store
      peers = store.list(localFingerprint: local.fingerprint)
      trustRecoveryNeeded = false
    } catch {
      trustRecoveryNeeded = error is TrustStoreLoadError
      status =
        trustRecoveryNeeded
        ? "Local trust records could not be verified. Reset local trust to pair again."
        : "Trusted devices are unavailable. Check identity access and try again."
    }
  }
  func recoverTrustStore() {
    cancel()
    let operation = generation
    Task {
      do {
        let restored = try await Task.detached { try PeerTrustStore.recover() }.value
        guard operation == generation else { return }
        store = restored
        trustRemoved()
        peers = []
        trustRecoveryNeeded = false
        status =
          "Local trust was reset. Pair your devices again. The unreadable file was preserved."
      } catch { status = "Could not recover local trust. Try again." }
    }
  }
  func sessionStore() async throws -> PeerTrustStore {
    if let store { return store }
    let factory = makeStore
    let loaded = try await Task.detached { try factory() }.value
    // Another caller may have completed while the load was suspended.
    if let store { return store }
    store = loaded
    return loaded
  }
  func forget(_ id: String) {
    do {
      try store?.remove(id)
      trustRemoved()
      peers.removeAll { $0.id == id }
    } catch { status = "Could not remove local trust. Try again." }
  }
}
