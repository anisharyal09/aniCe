// SPDX-License-Identifier: GPL-3.0-or-later
// Owns authenticated envelope ordering and deadline-driven transport-independent session maintenance.
import Foundation

// Only admission waiters are retained here; callers keep plaintext and SecureSession owns sealing.
actor SessionDataAdmission {
  private struct Waiter {
    let id: UUID
    let bulk: Bool
    let continuation: CheckedContinuation<Void, Error>
  }
  private var active = false
  private var closed = false
  private var waiters: [Waiter] = []
  private var interactiveTurns = 0
  var pendingCount: Int { waiters.count }

  func run(bulk: Bool, _ action: @Sendable () async throws -> Void) async throws {
    try Task.checkCancellation()
    guard !closed else { throw SessionFailure.cancelled }
    if active {
      guard waiters.count < 8 else { throw SessionBackpressure() }
      let id = UUID()
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          waiters.append(Waiter(id: id, bulk: bulk, continuation: continuation))
        }
      } onCancel: { Task { await self.cancel(id) } }
    } else { active = true }
    defer { release() }
    try Task.checkCancellation()
    guard !closed else { throw SessionFailure.cancelled }
    try await action()
  }
  private func cancel(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }
  private func release() {
    guard !waiters.isEmpty else { active = false; interactiveTurns = 0; return }
    // Four small-record turns bound bulk starvation; classification uses size until explicit feature priority exists.
    let bulk = waiters.firstIndex { $0.bulk }
    let interactive = waiters.firstIndex { !$0.bulk }
    let index = (interactiveTurns >= 4 ? bulk ?? interactive : interactive ?? bulk)!
    let next = waiters.remove(at: index)
    interactiveTurns = next.bulk ? 0 : min(4, interactiveTurns + 1)
    next.continuation.resume()
  }
  func close() {
    closed = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.continuation.resume(throwing: SessionFailure.cancelled) }
  }
}

/// Cumulative monotonic maintenance accounting survives coalesced callbacks across cryptographic epochs.
struct SessionMaintenanceSnapshot: Sendable {
  var sinceMillis: Int64?
  var elapsedMillis: Int64 = 0
  var revision: Int64 = 0
}

/// Owns EDHOC/envelope ordering and readiness; DATA admission precedes sealing.
actor SessionConnection {
  private var handshake: SessionHandshakeEngine
  private let responder: Bool
  private let profile: SessionProfile
  private let capacity: @Sendable (Int) async -> Bool
  private let submit: @Sendable (Data) async throws -> Void
  private let data: @Sendable (Data) async -> Void
  private let secured: @Sendable () async -> Void
  private(set) var expiration: SessionExpiry?
  private(set) var closedByPeer = false
  private var channel: SecureSession?
  private var expected: UInt8
  private var generation = 0
  private var closed = false
  var isClosed: Bool { closed }
  private var processing = false
  private var sendingData = false
  private let dataAdmission = SessionDataAdmission()
  private var sendingControl = false
  private var liveness: SessionLiveness?
  private let now: @Sendable () -> Int64
  private var renew: Bool
  private let renewalHandshake: (@Sendable () async throws -> SessionHandshakeEngine)?
  private enum RenewalPhase { case none, request, begin, waitDrained, drained, switching, handshake, readiness }
  private var renewalPhase = RenewalPhase.none
  private var renewalDeadline: Int64?
  private var creatingHandshake = false
  private var advertisedRenewal = false
  private var peerRenewal = false
  private var renewalID = Data()
  private var drainedReceived = false
  private var sendingRenewalControl = false
  private var renewalBlocked = false
  private var switchWaiter: CheckedContinuation<Void, Error>?
  private(set) var maintenanceSnapshot = SessionMaintenanceSnapshot()
  var isRenewing: Bool { renewalPhase != .none }
  private var mutualRenewal: Bool { renewalHandshake != nil && advertisedRenewal && peerRenewal }
  private let drain: @Sendable () async -> Void
  private let changed: @Sendable () -> Void
  private var deadline: Int64?
  var controlSupport: Bool? { liveness?.support }
  var renewalReason: Int64? { responder ? nil : liveness?.renewalReason }
  func enableRenewal() { if !closed { renew = true; changed() } }
  init(
    handshake: SessionHandshakeEngine, responder: Bool,
    capacity: @escaping @Sendable (Int) async -> Bool,
    submit: @escaping @Sendable (Data) async throws -> Void,
    data: @escaping @Sendable (Data) async -> Void,
    secured: @escaping @Sendable () async -> Void,
    controls: Bool = false,
    now: @escaping @Sendable () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) },
    renew: Bool = false,
    changed: @escaping @Sendable () -> Void = {},
    profile: SessionProfile = .standard,
    drain: @escaping @Sendable () async -> Void = {},
    renewalHandshake: (@Sendable () async throws -> SessionHandshakeEngine)? = nil
  ) {
    self.drain = drain
    self.profile = profile
    self.handshake = handshake
    self.responder = responder
    self.capacity = capacity
    self.submit = submit
    self.data = data
    self.secured = secured
    self.now = now
    self.renew = renew
    self.renewalHandshake = renewalHandshake
    self.changed = changed
    deadline = now() + 30000
    liveness = controls ? SessionLiveness(responder: responder) : nil
    expected = responder ? 1 : 2
  }
  private func ensure(_ op: Int) throws {
    guard !closed, op == generation else { throw SessionFailure.cancelled }
  }
  func nextDeadline(includeMaintenance: Bool = true) async -> Int64? {
    guard !closed, !closedByPeer else { return nil }
    let op = generation
    let policy = includeMaintenance && !processing
    let channelDeadline = await channel?.nextDeadline(
      renew: policy && renew && (renewalHandshake == nil || mutualRenewal) &&
        liveness?.support == true && liveness?.renewalReason == nil && !isRenewing)
    let handshakeDeadline = await handshake.nextDeadline
    guard op == generation, !closed else { return nil }
    let ready = renewalHandshake != nil && !renewalBlocked && !sendingData && !sendingControl && !sendingRenewalControl &&
      ((!advertisedRenewal && !isRenewing && liveness?.support == true) ||
        renewalPhase == .begin || renewalPhase == .drained || drainedReceived ||
        renewalPhase == .request && liveness?.pending != nil)
    return [handshakeDeadline.map { Int64($0 * 1000) }, deadline, renewalDeadline,
      channelDeadline.map { Int64($0 * 1000) }, policy ? liveness?.nextDeadline : liveness?.pendingPongDeadline,
      policy && ready ? now() : nil]
      .compactMap { $0 }.min()
  }
  func capacityAvailable() {
    if renewalBlocked { renewalBlocked = false; changed() }
  }
  func start() async throws {
    defer { changed() }
    let op = generation
    do {
      try ensure(op)
      if !responder { try await submit(SessionEnvelope.encode(1, handshake.initiate())) }
      try ensure(op)
    } catch {
      await close()
      throw error
    }
  }
  // Application delivery runs outside the reentry gate: it hops actors and decodes a whole record,
  // and none of that may delay control flush, deadline maintenance or the next record's
  // authentication. Delivery order is preserved because every caller awaits one `receive` before
  // starting the next — LanTcpTransport's ingress consumer and MacSessionModel's input chain are both
  // single sequential loops.
  func receive(_ envelope: Data) async throws {
    let op = generation
    guard !processing else {
      await close()
      throw SessionFailure.state
    }
    processing = true
    var delivery: Data?
    do {
      try ensure(op)
      let (kind, payload) = try SessionEnvelope.decode(envelope, profile: profile)
      if kind == 1, responder, renewalPhase == .switching {
        // The peer can receive drained before its native write callback and post-write validation finish.
        try await withCheckedThrowingContinuation { switchWaiter = $0 }
        try ensure(op)
      }
      if kind == 5 { try await handshake.receiveError(payload) }
      if kind == 6 {
        guard let channel else { throw SessionFailure.state }
        let result = try await channel.receive(payload)
        try ensure(op)
        liveness?.activity(now())
        switch result.0 {
        // Secured means application keys were confirmed, not merely that EDHOC completed.
        // Responder readiness follows transport submission, which does not prove peer delivery.
        case .ready:
          try await channel.send(.readyAck)
          try ensure(op)
          deadline = nil
          if !isRenewing { await secured() }
          try ensure(op)
          try liveness?.start(now())
          if renewalPhase == .readiness { renewalPhase = .none; finishMaintenance() }
        case .readyAck:
          deadline = nil
          if !isRenewing { await secured() }
          try ensure(op)
          try liveness?.start(now())
          if renewalPhase == .readiness { renewalPhase = .none; finishMaintenance() }
        case .data:
          guard !(responder && [.drained, .switching].contains(renewalPhase)), !drainedReceived
          else { throw SessionFailure.state }
          let control = liveness == nil ? nil : try SessionControl.classifyApplication(result.1,
            maximumBytes: min(524416, max(4096, profile.maximumPlaintext)), lanRenewal: renewalHandshake != nil)
          switch control {
          case .session(let message):
            if message.kind == .renewalRequest, renewalHandshake != nil, !mutualRenewal {
              guard !responder, liveness?.support == true else { throw SessionFailure.state }
            } else { try liveness?.receive(message, now(), allowRenewalPing: renewalHandshake != nil && isRenewing) }
            if message.kind == .renewalRequest, mutualRenewal { try beginRenewal(message.value) }
          case .lanRenewal(let message): try receiveRenewal(message)
          case nil: delivery = result.1
          }
        case .close:
          closedByPeer = true
          await drain()
          await close()
        }
        if !closed { try await flushControl(op); try await flushRenewal(op) }
      } else {
        guard channel == nil, kind == expected else { throw SessionFailure.state }
        switch kind {
        case 1:
          try await submit(SessionEnvelope.encode(2, handshake.respond(payload)))
          try ensure(op)
          expected = 3
        case 2:
          try await submit(SessionEnvelope.encode(3, handshake.authenticateResponder(payload)))
          try ensure(op)
          expected = 4
        case 3:
          try await submit(SessionEnvelope.encode(4, handshake.authenticateInitiator(payload)))
          try await makeChannel(op)
        case 4:
          try await handshake.confirmResponder(payload)
          try await makeChannel(op)
          try await channel?.send(.ready)
        default: throw SessionFailure.state
        }
      }
      if !closed { try ensure(op) }
    } catch {
      await close()
      throw error
    }
    if op == generation { processing = false }
    changed()
    // Application delivery releases the maintenance gate; transport callers still await it in record order.
    if let delivery {
      let deliveryStart = SessionTiming.start()
      await data(delivery)
      SessionTiming.end(self, "delivery", deliveryStart, bytes: delivery.count, profile: profile.rawValue, direction: "receive")
    }
  }
  private func makeChannel(_ op: Int) async throws {
    // Exporting can suspend; close the newly created channel if ownership was retired meanwhile.
    let clock = now
    let ch = try await SecureSession.fromHandshake(
      handshake, responder: responder, capacity: capacity,
      submit: { [submit, profile] record in try await submit(SessionEnvelope.encode(6, record, profile: profile)) },
      now: { Double(clock()) / 1000 }, profile: profile)
    do {
      try ensure(op)
      channel = ch
      deadline = now() + 10000
      if renewalPhase == .handshake { renewalPhase = .readiness }
    } catch {
      await ch.close()
      throw error
    }
  }
  func authenticatedPeer() async throws -> DeviceIdentity {
    let op = generation
    try ensure(op)
    let peer = try await handshake.authenticatedPeer()
    try ensure(op)
    return peer
  }
  var applicationAvailable: Bool { !closed && channel != nil && deadline == nil && liveness?.renewalReason == nil && !isRenewing }
  func sendData(_ bytes: Data) async throws {
    let admissionStart = SessionTiming.start()
    try await dataAdmission.run(bulk: bytes.count > SessionProfile.standard.maximumPlaintext) {
      SessionTiming.end(self, "admission", admissionStart, bytes: bytes.count, profile: self.profile.rawValue, direction: "send")
      try await self.sendAdmittedData(bytes)
    }
  }
  private func sendAdmittedData(_ bytes: Data) async throws {
    guard !sendingData else { throw SessionBackpressure() }
    var trackedSend = false
    var refused = false
    defer {
      if trackedSend { sendingData = false }
      if !refused || trackedSend && isRenewing { changed() }
    }
    let op = generation
    do {
      try ensure(op)
      if liveness?.renewalReason != nil || isRenewing { throw SessionBackpressure() }
      try await flushControl(op)
      try await flushRenewal(op)
      try ensure(op)
      if liveness?.pending != nil || sendingControl || sendingRenewalControl || isRenewing { throw SessionBackpressure() }
      guard let channel else { throw SessionFailure.state }
      sendingData = true; trackedSend = true
      try await channel.send(.data, plaintext: bytes)
      try ensure(op)
      liveness?.activity(now())
    } catch is SessionBackpressure { refused = true; throw SessionBackpressure() } catch {
      if error is CancellationError, !closed, let channel, await channel.stage == .secured { throw error }
      await close()
      throw error
    }
  }
  private(set) var maintenanceRuns = 0
  func checkDeadlines() async throws {
    if closedByPeer, !closed { return }
    let op = generation
    while true {
      let checkedChannel = channel
      let checkedHandshake = handshake
      do {
        try ensure(op)
        if let deadline, now() >= deadline { throw SessionFailure.expired }
        // Directional barriers have completed; only the fresh-handshake deadline remains active.
        if creatingHandshake { return }
        if let checkedChannel { try await checkedChannel.checkDeadlines() }
        else { try await checkedHandshake.checkTime() }
        try ensure(op)
        // Re-evaluate the successor instead of retiring it for an old actor's delayed result.
        if checkedChannel !== channel || checkedHandshake !== handshake { continue }
        try liveness?.checkPongDeadline(now())
        if let renewalDeadline, now() >= renewalDeadline { throw SessionFailure.controlTimeout }
        return
      } catch {
        if !closed, op == generation,
          checkedChannel !== channel || checkedHandshake !== handshake { continue }
        await close()
        throw error
      }
    }
  }
  func tick() async throws {
    defer { changed() }
    try await checkDeadlines()
    // Actor reentrancy must not let a health check race a suspended authenticated close.
    if processing || creatingHandshake || sendingControl || sendingRenewalControl { return }
    maintenanceRuns += 1
    let op = generation
    do {
      try ensure(op)
      if let deadline, now() >= deadline { throw SessionFailure.expired }
      let checkedChannel = channel
      if renew, let reason = await checkedChannel?.renewalReason() {
        try ensure(op)
        guard checkedChannel === channel, !processing, !creatingHandshake else { return }
        if renewalHandshake == nil { try liveness?.requestRenewal(reason) }
        else if mutualRenewal { try beginRenewal(reason) }
      }
      try liveness?.poll(now())
      try await flushControl(op)
      try await flushRenewal(op)
    } catch {
      await close()
      throw error
    }
  }
  private func flushControl(_ op: Int) async throws {
    guard !sendingControl, !sendingRenewalControl, !(isRenewing && sendingData),
      let message = liveness?.pending, let channel else { return }
    sendingControl = true
    defer { if op == generation { sendingControl = false } }
    let bytes = try message.encode()
    guard await capacity(bytes.count + 31) else {
      if isRenewing { renewalBlocked = true }
      return
    }
    try ensure(op)
    // Actor reentrancy may deliver the response before submit returns; issue before awaiting it.
    try liveness?.issuing(message, now())
    do {
      try await channel.send(.data, plaintext: bytes)
      try ensure(op)
      liveness?.submitted(message, now())
      if renewalHandshake != nil, isRenewing { try liveness?.poll(now()) }
    } catch is SessionBackpressure { if isRenewing { renewalBlocked = true } }
  }
  private func beginRenewal(_ reason: Int64) throws {
    guard mutualRenewal, !isRenewing else { return }
    try liveness?.requestRenewal(reason)
    renewalDeadline = now() + 10000
    renewalPhase = responder ? .request : .begin
    maintenanceSnapshot = SessionMaintenanceSnapshot(sinceMillis: now(), elapsedMillis: maintenanceSnapshot.elapsedMillis,
      revision: maintenanceSnapshot.revision + 1)
    renewalBlocked = false
    if !responder {
      var random = SystemRandomNumberGenerator()
      renewalID = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &random) })
      liveness?.quiesceForLanBarrier()
    }
    changed()
  }
  private func receiveRenewal(_ message: LanRenewalControl) throws {
    guard liveness?.support == true else { throw SessionFailure.state }
    switch message.kind {
    case 1: peerRenewal = true
    case 2:
      guard responder, mutualRenewal else { throw SessionFailure.state }
      guard renewalPhase == .none || renewalPhase == .request else { throw SessionFailure.state }
      renewalDeadline = renewalDeadline ?? (now() + 10000)
      if !isRenewing {
        maintenanceSnapshot = SessionMaintenanceSnapshot(sinceMillis: now(), elapsedMillis: maintenanceSnapshot.elapsedMillis,
          revision: maintenanceSnapshot.revision + 1)
      }
      renewalID = message.id
      try liveness?.requestRenewal(message.reason)
      liveness?.quiesceForLanBarrier()
      renewalPhase = .drained
      renewalBlocked = false
    case 3:
      guard !responder, renewalPhase == .waitDrained, renewalID == message.id, !drainedReceived
      else { throw SessionFailure.state }
      drainedReceived = true
    default: throw SessionFailure.state
    }
  }
  private func flushRenewal(_ op: Int) async throws {
    guard let channel, renewalHandshake != nil, !sendingData, !sendingControl,
      !sendingRenewalControl, liveness?.pending == nil, liveness?.support == true else { return }
    if drainedReceived, renewalPhase == .waitDrained { try await switchHandshake(op); return }
    let message: LanRenewalControl
    if !advertisedRenewal, !isRenewing { message = LanRenewalControl(kind: 1) }
    else if renewalPhase == .begin { message = LanRenewalControl(kind: 2, id: renewalID, reason: liveness?.renewalReason ?? 1) }
    else if renewalPhase == .drained { message = LanRenewalControl(kind: 3, id: renewalID) }
    else { return }
    let bytes = try message.encode()
    guard await capacity(bytes.count + 31) else { renewalBlocked = true; return }
    try ensure(op)
    sendingRenewalControl = true
    defer { if op == generation { sendingRenewalControl = false } }
    if message.kind == 2 { renewalPhase = .waitDrained }
    if message.kind == 3 { renewalPhase = .switching }
    do { try await channel.send(.data, plaintext: bytes) }
    catch is SessionBackpressure {
      renewalBlocked = true
      if message.kind == 2 { renewalPhase = .begin }
      if message.kind == 3 { renewalPhase = .drained }
      return
    }
    try ensure(op)
    sendingRenewalControl = false
    if message.kind == 1 { advertisedRenewal = true }
    if message.kind == 3 || message.kind == 2 && drainedReceived { try await switchHandshake(op) }
    try await flushControl(op)
    changed()
  }
  private func finishMaintenance() {
    if let start = maintenanceSnapshot.sinceMillis {
      maintenanceSnapshot = SessionMaintenanceSnapshot(elapsedMillis: maintenanceSnapshot.elapsedMillis + max(0, now() - start),
        revision: maintenanceSnapshot.revision + 1)
    }
  }
  private func switchHandshake(_ op: Int) async throws {
    guard let factory = renewalHandshake else { throw SessionFailure.state }
    renewalPhase = .switching
    renewalDeadline = nil
    deadline = now() + 30000
    creatingHandshake = true
    let old = handshake
    let oldChannel = channel
    liveness = SessionLiveness(responder: responder)
    channel = nil
    await oldChannel?.close()
    await old.close()
    try ensure(op)
    advertisedRenewal = false; peerRenewal = false; drainedReceived = false; renewalBlocked = false
    let created = try await factory()
    do { try ensure(op) } catch { await created.close(); throw error }
    handshake = created
    creatingHandshake = false
    expected = responder ? 1 : 2
    renewalPhase = .handshake
    let waiting = switchWaiter
    switchWaiter = nil
    waiting?.resume()
    if !responder { try await submit(SessionEnvelope.encode(1, created.initiate())) }
    try ensure(op)
    changed()
  }
  func disconnect() async throws {
    do { if let channel, await channel.stage == .secured { try await channel.send(.close) } } catch
    {
      await close()
      throw error
    }
    await close()
  }
  func close() async {
    closed = true
    finishMaintenance()
    let waiting = switchWaiter
    switchWaiter = nil
    waiting?.resume(throwing: SessionFailure.cancelled)
    await dataAdmission.close()
    generation += 1
    processing = false
    sendingData = false
    sendingControl = false
    let old = channel
    channel = nil
    if expiration == nil { expiration = await old?.expiration }
    if await old?.closedByPeer == true { closedByPeer = true }
    await old?.close()
    await handshake.close()
    changed()
  }
}

@MainActor final class SessionDeadlineWait {
  private var task: Task<Void, Never>?
  private var revision = 0
  private(set) var deadline: TimeInterval?
  func cancel() { revision += 1; task?.cancel(); task = nil; deadline = nil }
  func schedule(
    now: @escaping () -> TimeInterval,
    deadline: @escaping () async -> TimeInterval?, fire: @escaping () -> Void
  ) {
    cancel()
    let token = revision
    task = Task { [weak self] in
      guard let due = await deadline(), let self, token == self.revision else { return }
      self.deadline = due
      do { try await Task.sleep(for: .seconds(max(0, due - now()))) } catch { return }
      guard !Task.isCancelled, token == self.revision else { return }
      self.deadline = nil
      self.task = nil // Firing may rearm the wait; it must not cancel the current operation.
      fire()
    }
  }
}
