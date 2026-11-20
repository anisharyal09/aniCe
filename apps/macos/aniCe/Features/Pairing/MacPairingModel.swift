// SPDX-License-Identifier: GPL-3.0-or-later
// Owns mutual pairing and publishes successful completion only after generation-guarded radio cleanup.
import AppKit
import CoreImage.CIFilterBuiltins
import Observation
import CoreGraphics
import OSLog

@Observable @MainActor final class MacPairingModel {
  private static let logger = Logger(subsystem: "io.github.anisharyal09.anice", category: "pairing")
  var trustRemoved: () -> Void = {}
  var beforePairing: () -> Void = {}
  var afterPairing: () -> Void = {}
  var onPaired: ((DeviceIdentity) -> Void)?
  var onNewPeerPaired: ((DeviceIdentity) -> Void)?
  var completedPeer: DeviceIdentity?
  var status = "Choose how to pair your Android device."
  var phase = "idle"
  var active = false
  var qrText: String?
  var qrImage: NSImage?
  var pin: String?
  private(set) var method: PairingMethod?
  private(set) var comparisonCode: String?
  private(set) var comparisonAttempt = UUID()
  var comparisonChanged: () -> Void = {}
  var nearbyAvailabilityChanged: () -> Void = {}
  private var nearbyAdmission = NearbyPairingAdmission()
  private var nearbyDeadline: Task<Void, Never>?
  private var nearbyAvailabilityWait: Task<Void, Never>?
  private var nearbyAttemptDeadline: TimeInterval?
  private var attemptLease: PairingAttemptLease?
  private var sleeping = false
  private var quitting = false
  private let isScreenLocked: () -> Bool
  private var screenLocked: Bool { isScreenLocked() }
  nonisolated private static func nativeScreenLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
    return session["CGSSessionScreenIsLocked"] as? Bool == true ||
      session[kCGSessionOnConsoleKey] as? Bool != true ||
      session[kCGSessionLoginDoneKey] as? Bool != true
  }
  private(set) var nearbyPaused = false
  private(set) var nearbyRecovery: DiscoveryRecovery = .none
  var nearbyEnabled: Bool { active && method == .sas }
  var nearbySetupDetail: String {
    nearbyEnabled || phase == "failed" ? status : "Let aniCe on your Android phone discover this Mac."
  }
  var nearbyNeedsSettings: Bool {
    nearbyRecovery == .bluetoothSettings || nearbyRecovery == .permissionSettings
  }
  func openNearbySettings() { discovery.openSettings(recovery: nearbyRecovery) }
  var peer: DeviceIdentity?
  var peers: [PeerTrustRecord] = []
  var nicknameFailure = false
  var savingNickname = false
  func nickname(for peer: DeviceIdentity) -> PeerNickname? { PeerNames.shared.nickname(peer) }
  func displayedName(for peer: DeviceIdentity) -> String {
    PeerNames.shared.displayName(peer)
  }
  func saveNickname(peer: DeviceIdentity, name: String, enabled: Bool) {
    guard !savingNickname,
      peers.contains(where: { PeerNickname.credential($0.peer) == PeerNickname.credential(peer) })
    else { return }
    savingNickname = true
    nicknameFailure = false
    Task {
      defer { savingNickname = false }
      do {
        try await PeerNames.shared.saveNickname(peer: peer, name: name, enabled: enabled)
      } catch { nicknameFailure = true }
    }
  }
  // Presentation only; session admission resolves trust directly from the store.
  var hasTrustedAndroid: Bool {
    peers.contains { $0.active && $0.peer.platform == "android" }
  }
  var trustRecoveryNeeded = false
  var trustedPeersLoaded = false
  var remaining = 0
  private let identity: IdentityService
  private let discovery: MacDiscoveryModel
  private let makeStore: @Sendable () throws -> PeerTrustStore
  private let readInvitation: @MainActor (PairingEngine) async -> (qr: String?, pin: String?)
  private var store: PeerTrustStore?
  private var engine: PairingEngine?
  private var generation = 0
  private var timer: Timer?
  private var work: Task<Void, Never>?
  private var deadline: TimeInterval?
  private var startedRadio = false
  private var observers: [NSObjectProtocol] = []
  private var trustedPeerIdsBeforePairing = Set<String>()
  init(
    identity: IdentityService, discovery: MacDiscoveryModel,
    makeStore: @escaping @Sendable () throws -> PeerTrustStore = { try PeerTrustStore() },
    isScreenLocked: @escaping () -> Bool = MacPairingModel.nativeScreenLocked,
    readInvitation: @escaping @MainActor (PairingEngine) async -> (qr: String?, pin: String?) = {
      engine in
      let qr = await engine.qr?.text
      let pin = await engine.pin
      return (qr, pin)
    }
  ) {
    self.identity = identity
    self.discovery = discovery
    self.makeStore = makeStore
    self.isScreenLocked = isScreenLocked
    self.readInvitation = readInvitation
    discovery.availabilityFailed = { [weak self] in
      guard let self, self.nearbyEnabled else { return }
      self.fail(self.discovery.session.message)
    }
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated {
        self?.sleeping = true; self?.cancel()
      } })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated {
        self?.quitting = true; self?.cancel()
      } })
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
      observers.append(NSWorkspace.shared.notificationCenter.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated {
        self?.sleeping = false
        self?.nearbyAvailabilityChanged()
      } })
    }
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated {
      self?.sleeping = true
      if self?.nearbyEnabled == true { self?.cancel() }
    } })
    for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
      observers.append(DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name(name), object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated {
        guard let self else { return }
        self.sleeping = locked
        if locked {
          if self.nearbyEnabled { self.cancel() }
        } else { self.nearbyAvailabilityChanged() }
      } })
    }
    observers.append(NotificationCenter.default.addObserver(
      forName: IdentityService.invalidated, object: identity, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated {
      self?.trustedPeersLoaded = false
      self?.cancel(message: "Identity changed. Start a fresh pairing.")
    } })
  }
  func start(_ method: PairingMethod) {
    completedPeer = nil
    beforePairing()
    cancel()
    self.method = method
    active = true
    phase = "preparing"
    status = "Preparing a new pairing invitation…"
    let op = generation
    let cleanup = work
    let lease = PairingAttemptLease()
    attemptLease = lease
    Task { [self] in
      await cleanup?.value
      do {
        let factory = self.makeStore
        let store = try await Task.detached { try factory() }.value
        let localIdentity = try await identity.publicIdentity()
        guard op == generation, active else { return }
        trustedPeerIdsBeforePairing = Set(
          store.list(localFingerprint: localIdentity.fingerprint).map { $0.peer.deviceId })
        if method == .sas, !trustedPeerIdsBeforePairing.isEmpty {
          fail("Nearby first-time setup is unavailable while trusted devices exist.")
          return
        }
        let engine = try await PairingEngine(
          method: method, identity: identity, store: store,
          send: { [weak self] data in
            await self?.send(data, operation: op)
          },
          event: { [weak self] state, peer in await self?.event(state, peer: peer, operation: op) },
          comparison: { [weak self] digits in await self?.showComparison(digits, operation: op) },
          isCurrent: { lease.active })
        guard op == generation, active else {
          await engine.close()
          return
        }
        self.store = store
        trustRecoveryNeeded = false
        self.engine = engine
        let invitation = await readInvitation(engine)
        // Actor reads suspend: Stop, sleep or a replacement may already own engine cleanup.
        // Do not republish secrets or reinstall radio callbacks for that retired startup.
        guard op == generation, active else { return }
        qrText = invitation.qr
        qrImage = qrText.flatMap(Self.renderQR)
        pin = invitation.pin
        discovery.adapter.pairingStopsAdvertisingOnAdmission = method == .sas
        discovery.adapter.pairingAdmitted = { [weak self] in
          guard let self, self.generation == op, self.active else { return false }
          guard method == .sas else { return true }
          guard !self.sleeping, !self.quitting, !self.screenLocked, self.phase == "nearby",
            self.nearbyAdmission.admit(at: ProcessInfo.processInfo.systemUptime)
          else {
            Self.logger.notice("pairing_admission accepted=false phase=\(self.phase, privacy: .public) generation=\(op)")
            return false
          }
          Self.logger.notice("pairing_admission accepted=true generation=\(op)")
          self.phase = "connecting"
          self.status = "A nearby phone is requesting pairing…"
          let now = ProcessInfo.processInfo.systemUptime
          self.nearbyAttemptDeadline = now + 120
          self.deadline = now + 15
          self.scheduleNearbyDeadline()
          return true
        }
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
            if method == .sas {
              guard self.generation == op else { return }
              self.endNearbyAttempt("Connection ended. Choose Try again in aniCe on your phone.")
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
        if method == .sas {
          let now = ProcessInfo.processInfo.systemUptime
          let availableAt = nearbyAdmission.nextAdmission(at: now)
          if availableAt > now {
            phase = "cooldown"
            status = "Nearby pairing is taking a short break. It will become available automatically."
            nearbyAvailabilityWait = Task { [weak self] in
              do { try await Task.sleep(for: .seconds(max(0.001, availableAt - ProcessInfo.processInfo.systemUptime))) }
              catch { return }
              guard let self, self.generation == op, self.active, !self.sleeping, !self.quitting,
                !self.screenLocked, self.phase == "cooldown" else { return }
              self.openNearbyRadio(operation: op)
            }
          } else { openNearbyRadio(operation: op) }
        } else {
          discovery.start()
          guard op == generation, active else { return }
          phase = "starting"
          status = "Starting Bluetooth for this invitation…"
          let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
          }
          self.timer = timer
          RunLoop.main.add(timer, forMode: .common)
        }
        guard op == generation, active else { return }
        peers = store.list(localFingerprint: engine.local.fingerprint)
        trustedPeersLoaded = true
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
    Self.logger.notice("pairing_send generation=\(operation) kind=\(data.first ?? 0) bytes=\(data.count)")
    do { try discovery.adapter.sendPairing(data) } catch { fail() }
  }
  private func openNearbyRadio(operation: Int) {
    guard generation == operation, active, method == .sas else { return }
    discovery.startNearby(flags: PairingSas.discoveryFlag)
    guard generation == operation, active else { return }
    phase = "nearby"
    status = "Bring your phone close with aniCe open, then compare the code on both screens."
  }
  private func enqueue(_ data: Data, operation: Int) {
    guard phase != "cancelling", let engine else { return }
    Self.logger.notice("pairing_receive generation=\(operation) kind=\(data.first ?? 0) bytes=\(data.count)")
    let previous = work
    work = Task {
      await previous?.value
      guard self.active, self.generation == operation else { return }
      do { try await engine.receive(data) } catch {
        guard self.generation == operation else { return }
        Self.logger.notice("pairing_receive_failed generation=\(operation) reason=\(String(describing: error), privacy: .public)")
        if self.method == .sas {
          self.endNearbyAttempt((error as? PairingFailure) == .cancelled
            ? "Pairing dismissed." : "Pairing was interrupted. Start a fresh comparison.")
          return
        }
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
    Self.logger.notice("pairing_state generation=\(operation) from=\(self.phase, privacy: .public) to=\(state, privacy: .public)")
    self.peer = peer
    phase = state
    switch state {
    case "authenticating":
      deadline = ProcessInfo.processInfo.systemUptime + 30
      status = "Authenticating the pairing exchange…"
    case "approval":
      deadline = ProcessInfo.processInfo.systemUptime + 60
      status = "Verify this device, then approve pairing on both devices."
    case "comparison":
      deadline = ProcessInfo.processInfo.systemUptime + 60
      status = "Compare all six digits on your phone, then confirm on both devices."
      comparisonChanged()
    case "verifying":
      deadline = ProcessInfo.processInfo.systemUptime + 30
      status = "Both confirmed. Verifying device identities…"
      comparisonChanged()
    case "saving":
      deadline = ProcessInfo.processInfo.systemUptime + 10
      status = "Saving trust and confirming peer storage…"
    case "paired":
      deadline = ProcessInfo.processInfo.systemUptime + 2
      status = "Pairing complete. Device saved as trusted."
      qrText = nil
      qrImage = nil
      pin = nil
      comparisonCode = nil
      comparisonChanged()
      Task {
        guard let engine = self.engine else { return }
        let fingerprint = engine.local.fingerprint
        guard operation == self.generation else { return }
        self.peers = self.store?.list(localFingerprint: fingerprint) ?? []
      }
    default: break
    }
    if method == .sas { scheduleNearbyDeadline() }
  }
  private func showComparison(_ digits: String, operation: Int) {
    guard active, generation == operation, method == .sas, phase == "authenticating" else { return }
    comparisonCode = digits
    comparisonAttempt = UUID()
  }
  func confirmComparison(attempt: UUID) {
    Self.logger.notice("comparison_confirm current=\(attempt == self.comparisonAttempt) phase=\(self.phase, privacy: .public) generation=\(self.generation)")
    guard !sleeping, !screenLocked, attempt == comparisonAttempt, phase == "comparison", comparisonCode != nil,
      method == .sas, let engine else { return }
    tick()
    guard phase == "comparison" else { return }
    phase = "waiting"
    status = "Confirmed on this Mac. Waiting for your phone…"
    comparisonChanged()
    let op = generation
    let previous = work
    work = Task {
      await previous?.value
      guard self.generation == op, self.active else { return }
      do { try await engine.confirmComparison() } catch {
        if self.generation == op { self.endNearbyAttempt("Comparison could not finish. Start again.") }
      }
    }
  }
  func dismissComparison(attempt: UUID) {
    guard attempt == comparisonAttempt, method == .sas, active,
      ["comparison", "waiting", "verifying"].contains(phase), let engine else { return }
    Self.logger.notice("comparison_dismiss phase=\(self.phase, privacy: .public) generation=\(self.generation)")
    nearbyAdmission.dismiss(at: ProcessInfo.processInfo.systemUptime)
    attemptLease?.cancel()
    phase = "cancelling"
    comparisonChanged()
    let op = generation
    let previous = work
    work = Task {
      await previous?.value
      guard self.generation == op else { return }
      try? await engine.decline()
      await self.discovery.adapter.drainPairing()
      if self.generation == op { self.endNearbyAttempt("Pairing dismissed.") }
    }
  }
  func pauseNearby() {
    nearbyPaused = true
    cancel()
  }
  func resumeNearby() {
    nearbyPaused = false
    ensureNearbyAvailable()
  }
  func ensureNearbyAvailable() {
    guard !active, !sleeping, !quitting, !screenLocked, !nearbyPaused, trustedPeersLoaded,
      !trustRecoveryNeeded, peers.isEmpty, !discovery.session.active else { return }
    start(.sas)
  }
  private func endNearbyAttempt(_ message: String) {
    guard method == .sas else { return }
    cancel(message: message)
    let cleanup = work
    let op = generation
    Task {
      await cleanup?.value
      guard self.generation == op, !self.active else { return }
      self.nearbyAvailabilityChanged()
    }
  }
  private func scheduleNearbyDeadline() {
    nearbyDeadline?.cancel()
    nearbyDeadline = nil
    guard method == .sas, active,
      let next = [deadline, nearbyAttemptDeadline].compactMap({ $0 }).min()
    else { return }
    let op = generation
    nearbyDeadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(max(0.001, next - ProcessInfo.processInfo.systemUptime))) }
      catch { return }
      guard let self, self.generation == op else { return }
      self.tick()
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
    if phase == "cooldown" { return }
    discovery.session.tick()
    remaining = method == .sas ? 0 : discovery.session.remainingSeconds
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
    let now = ProcessInfo.processInfo.systemUptime
    if (deadline.map { now >= $0 } ?? false) || (nearbyAttemptDeadline.map { now >= $0 } ?? false) {
      if phase == "paired" {
        cancel(message: status)
      } else {
        if method == .sas { endNearbyAttempt("Pairing timed out. Choose Try again in aniCe on your phone.") }
        else { fail("Pairing timed out. Start a fresh invitation.") }
      }
    }
  }
  func cancel(message: String = "Pairing stopped. Start a fresh invitation when ready.") {
    Self.logger.notice("pairing_cancel phase=\(self.phase, privacy: .public) generation=\(self.generation)")
    attemptLease?.cancel()
    attemptLease = nil
    let wasActive = active
    let paired = phase == "paired" ? peer : nil
    let isNewPeer = paired.map { !trustedPeerIdsBeforePairing.contains($0.deviceId) } ?? false
    generation += 1
    let operation = generation
    active = false
    nearbyRecovery = .none
    timer?.invalidate()
    timer = nil
    nearbyDeadline?.cancel()
    nearbyDeadline = nil
    nearbyAvailabilityWait?.cancel()
    nearbyAvailabilityWait = nil
    nearbyAttemptDeadline = nil
    deadline = nil
    startedRadio = false
    remaining = 0
    qrText = nil
    qrImage = nil
    pin = nil
    comparisonCode = nil
    method = nil
    comparisonChanged()
    peer = nil
    phase = "idle"
    status = message
    discovery.adapter.pairingWrite = nil
    discovery.adapter.pairingDisconnect = nil
    discovery.adapter.pairingAdmitted = nil
    discovery.adapter.pairingStopsAdvertisingOnAdmission = false
    discovery.stop()
    let old = engine
    engine = nil
    let previous = work
    work = Task {
      await previous?.value
      await old?.close()
      if wasActive && !self.active && self.generation == operation {
        if let paired, let onPaired = self.onPaired {
          if let local = try? await self.identity.publicIdentity() {
            guard self.generation == operation, !self.active else { return }
            self.peers = self.store?.list(localFingerprint: local.fingerprint) ?? self.peers
          }
          self.completedPeer = paired
          if isNewPeer { self.onNewPeerPaired?(paired) }
          onPaired(paired)
        } else { self.afterPairing() }
      }
    }
  }
  private func fail(
    _ message: String =
      "Pairing could not finish. Check Bluetooth and identity access, then start a fresh invitation."
  ) {
    // Cancellation retires discovery and clears its native error. Keep only the
    // recovery hint for presentation so the inactive setup row still explains why.
    let recovery = discovery.session.recovery
    cancel(message: message)
    phase = "failed"
    nearbyRecovery = recovery
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
    let operation = generation
    trustedPeersLoaded = false
    do {
      let local = try await identity.publicIdentity()
      let store = try self.store ?? PeerTrustStore()
      guard operation == generation else { return }
      self.store = store
      peers = store.list(localFingerprint: local.fingerprint)
      PeerNames.shared.refresh()
      trustRecoveryNeeded = false
      trustedPeersLoaded = true
      nearbyAvailabilityChanged()
    } catch {
      guard operation == generation else { return }
      trustedPeersLoaded = false
      trustRecoveryNeeded = error is TrustStoreLoadError
      status =
        trustRecoveryNeeded
        ? "Local trust records could not be verified. Reset local trust to pair again."
        : "Trusted devices are unavailable. Check identity access and try again."
      if nearbyEnabled { fail(status) }
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
