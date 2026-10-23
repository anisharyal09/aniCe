// SPDX-License-Identifier: GPL-3.0-or-later
// Owns ordered Network.framework frames, a bounded ingress hand-off, and descriptor retirement.
import Foundation
import OSLog
@preconcurrency import Network

/// Bounded ordered hand-off between a transport read loop and its single delivery consumer.
///
/// A full queue suspends the producer, so the bound is real backpressure and never a drop.
/// `AsyncStream` has no such policy — every buffering option discards an element when full, which
/// would fail a valid transfer on a fast link. One consumer drains in order, which is the record
/// order authenticated sequencing depends on.
actor LanIngressQueue {
  private let limit: Int
  private var pending = [Data]()
  private var room: CheckedContinuation<Void, Never>?
  private var next: CheckedContinuation<Void, Never>?
  private var closed = false
  init(limit: Int) { self.limit = max(1, limit) }
  var count: Int { pending.count }
  /// Only one producer exists — the read loop issues its next read only after this returns — so at
  /// most one producer is ever suspended here.
  func push(_ bytes: Data) async {
    while !closed, pending.count >= limit {
      await withCheckedContinuation { room = $0 }
    }
    guard !closed else { return }
    pending.append(bytes)
    if let waiting = next {
      next = nil
      waiting.resume()
    }
  }
  /// The single consumer. Reports nil once the queue is closed and drained. Both continuations are
  /// wake-ups only, so the resumed side always re-reads `pending` and `closed` rather than a value it
  /// could observe out of date.
  func pop() async -> Data? {
    while pending.isEmpty {
      if closed { return nil }
      await withCheckedContinuation { next = $0 }
      if closed, pending.isEmpty { return nil }
    }
    let bytes = pending.removeFirst()
    if let waiting = room {
      room = nil
      waiting.resume()
    }
    return bytes
  }
  /// Closes the hand-off without emptying it.
  ///
  /// A producer suspended on a full queue and a consumer waiting on an empty one both have to be
  /// let go, or closing the transport would strand them instead of unwinding the read loop. Entries
  /// the read loop already handed over still belong to the consumer: the peer's FIN commonly follows
  /// its last record, so a close that discarded the queue would drop the record carrying the peer's
  /// CLOSE. `pop` reports nil only once the queue is closed *and* drained.
  func close() {
    guard !closed else { return }
    closed = true
    room?.resume()
    room = nil
    next?.resume()
    next = nil
  }
}

actor LanTcpTransport {
  private static let logger = Logger(subsystem: "io.github.anisharyal09.anice", category: "LAN transport")
  private let socket: NWConnection
  private let profile: SessionProfile
  private var framing: LanFraming
  private var budget: LanQueueBudget
  private var changed: (@Sendable () -> Void)?
  private var closed = false
  private var interfaces: Set<Int>?
  private var nextWrite = 0
  private var writes = [Int: CheckedContinuation<Void, Error>]()
  private var watchdogs = [Int: Task<Void, Never>]()
  private var deliver: (@Sendable (Data) async throws -> Void)?
  private var ended: (@Sendable (Error) -> Void)?
  private var assemblyWatchdog: Task<Void, Never>?
  private var assemblyDeadline: TimeInterval?
  // The read loop hands every assembled envelope here and returns to `socket.receive` immediately, so
  // the socket stays read while an earlier record is still being decoded, validated and written. The
  // capacity restates the documented admission bound (8 envelopes standard, 4 otherwise) rather than
  // adding one.
  private let ingress: LanIngressQueue
  init(_ socket: NWConnection, profile: SessionProfile = .standard) {
    self.socket = socket
    self.profile = profile
    self.framing = LanFraming(profile: profile)
    self.budget = LanQueueBudget(profile: profile)
    self.ingress = LanIngressQueue(limit: profile == .standard ? 8 : 4)
  }
  nonisolated static func parameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 10
    tcp.keepaliveInterval = 5
    tcp.keepaliveCount = 3
    tcp.connectionDropTime = 20
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.includePeerToPeer = false
    parameters.prohibitedInterfaceTypes = [.cellular, .loopback, .other]
    return parameters
  }
  func start(
    deliver: @escaping @Sendable (Data) async throws -> Void,
    ended: @escaping @Sendable (Error) -> Void,
    changed: @escaping @Sendable () -> Void = {}
  ) {
    guard !closed else { return }
    self.changed = changed
    self.deliver = deliver
    self.ended = ended
    socket.pathUpdateHandler = { [weak self] path in
      Task { await self?.pathChanged(path) }
    }
    socket.stateUpdateHandler = { [weak self] state in
      Task { await self?.stateChanged(state) }
    }
    socket.start(queue: DispatchQueue(label: "aniCe LAN connection"))
    // Not stored: the consumer ends by itself once the hand-off is closed and drained, so there is no
    // handle to cancel and no owner to leak. It holds the transport weakly.
    Task { [weak self] in await self?.drain() }
  }
  /// A delivery failure reaches the same terminal handling as an inline one, and remains the reported
  /// cause: `fail` closes the transport, which is what releases a reader suspended in the hand-off.
  /// The consumer retires `deliver` when it ends, so a close that leaves envelopes behind still lets
  /// them be delivered before the closure goes away.
  private func drain() async {
    defer { deliver = nil }
    do {
      while let bytes = await ingress.pop() {
        guard let deliver else { return }
        try await deliver(bytes)
      }
    } catch { fail(error) }
  }
  private func pathChanged(_ path: NWPath) {
    guard !closed, let interfaces else { return }
    guard Self.permitsPath(original: interfaces,
      current: Set(path.availableInterfaces.filter { $0.type == .wifi || $0.type == .wiredEthernet }.map(\.index)),
      satisfied: path.status == .satisfied,
      local: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
    else { fail(SessionFailure.state); return }
  }
  // NWPath lists available interfaces, including candidates unrelated to this TCP connection.
  // Adding/removing a VPN or peer-to-peer interface cannot invalidate a surviving local route.
  nonisolated static func permitsPath(original: Set<Int>, current: Set<Int>, satisfied: Bool, local: Bool) -> Bool {
    satisfied && local && !original.isDisjoint(with: current)
  }
  private func stateChanged(_ state: NWConnection.State) {
    guard !closed else { return }
    switch state {
    case .ready:
      guard interfaces == nil else { return }
      guard let path = socket.currentPath,
        path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
      else { fail(SessionFailure.state); return }
      interfaces = Set(path.availableInterfaces.filter { $0.type == .wifi || $0.type == .wiredEthernet }.map(\.index))
      receive()
    case .failed(let error), .waiting(let error): fail(error)
    case .cancelled: fail(SessionFailure.cancelled)
    default: break
    }
  }
  func capacity(_ size: Int) -> Bool { !closed && budget.canReserve(size) }
  /// Exposed so the hand-off ordering and the documented admission bound stay verifiable without a
  /// live Wi-Fi socket, which the hosted suite cannot open.
  var ingressQueue: LanIngressQueue { ingress }
  func submit(_ envelope: Data) async throws {
    guard !closed else { throw SessionFailure.cancelled }
    let bytes = try LanFraming.encode(envelope, profile: profile)
    try budget.reserve(envelope.count)
    defer { budget.release(envelope.count); changed?() }
    let token = nextWrite
    nextWrite += 1
    do { try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        writes[token] = continuation
        watchdogs[token] = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(10)) } catch { return }
          await self?.failWrite(token, error: NWError.posix(.ETIMEDOUT))
        }
        socket.send(
          content: bytes,
          completion: .contentProcessed { [weak self] error in
            Task { await self?.sent(token, error: error) }
          })
      }
    } onCancel: {
      Task { [weak self] in await self?.failWrite(token, error: SessionFailure.cancelled) }
    } } catch {
      // Cancellation before continuation registration still follows an admitted sealed record.
      fail(error)
      throw error
    }
  }
  private func sent(_ token: Int, error: NWError?) {
    guard let pending = writes.removeValue(forKey: token) else { return }
    watchdogs.removeValue(forKey: token)?.cancel()
    if let error {
      pending.resume(throwing: error)
      fail(error)
    } else { pending.resume() }
  }
  private func failWrite(_ token: Int, error: Error) {
    // Deadline/cancellation callbacks can arrive after completion; only an outstanding write owns retirement.
    guard let pending = writes.removeValue(forKey: token) else { return }
    watchdogs.removeValue(forKey: token)?.cancel()
    // Preserve this write's cause before close retires the other outstanding operations.
    pending.resume(throwing: error)
    Self.logger.notice("LAN outstanding write failed: \(String(describing: error), privacy: .public)")
    fail(error)
  }
  private func receive() {
    guard !closed else { return }
    // One whole profile record fits one read. TCP returns as soon as any byte is available, so sizing
    // the buffer to the record does not delay a partial frame or its assembly deadline.
    socket.receive(minimumIncompleteLength: 1, maximumLength: profile.maximumEnvelope + 5) {
      [weak self] data, _, complete, error in
      Task { await self?.received(data, complete: complete, error: error) }
    }
  }
  private func received(_ data: Data?, complete: Bool, error: NWError?) async {
    guard !closed else { return }
    do {
      if let data {
        let receivedAt = try framing.beginBuffer()
        var offset = 0
        while offset < data.count {
          guard !closed else { return }
          let frame = try framing.feed(data, offset: &offset, receivedAt: receivedAt)
          scheduleAssemblyDeadline()
          // Reading must not wait on delivery: the previous shape held the socket unread for the whole
          // decode, native validation and actor hop of every record, so TCP backpressure amplified
          // each stall. Only a full hand-off suspends the reader.
          if let frame { await ingress.push(frame) }
        }
      }
      guard !closed else { return }
      if let error { throw error }
      if complete {
        try framing.end()
        throw SessionFailure.cancelled
      }
      changed?()
      receive()
    } catch { fail(error) }
  }
  private func scheduleAssemblyDeadline() {
    let next = framing.nextDeadline
    guard next != assemblyDeadline else { return }
    assemblyDeadline = next
    assemblyWatchdog?.cancel()
    guard let deadline = next else { assemblyWatchdog = nil; return }
    let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
    assemblyWatchdog = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      await self?.assemblyExpired()
    }
  }
  private func assemblyExpired() {
    assemblyDeadline = nil
    do { try framing.tick(); scheduleAssemblyDeadline() } catch {
      Self.logger.notice("LAN frame assembly failed: \(String(describing: error), privacy: .public)")
      fail(error)
    }
  }
  private func fail(_ error: Error) {
    guard !closed else { return }
    Self.logger.notice("LAN transport ended: \(String(describing: error), privacy: .public)")
    let callback = ended
    close()
    callback?(error)
  }
  func close() {
    guard !closed else { return }
    closed = true
    assemblyWatchdog?.cancel()
    assemblyWatchdog = nil
    // The hand-off is closed but not emptied, and the consumer is not cancelled: it delivers the
    // envelopes the read loop already handed over and then ends by itself, which is what keeps a
    // stream end from discarding a record that arrived before it. Everything else retires now.
    ended = nil
    Task { await ingress.close() }
    socket.stateUpdateHandler = nil
    socket.pathUpdateHandler = nil
    socket.cancel()
    let pending = Array(writes.values)
    writes.removeAll()
    watchdogs.values.forEach { $0.cancel() }
    watchdogs.removeAll()
    for continuation in pending { continuation.resume(throwing: SessionFailure.cancelled) }
  }
}
