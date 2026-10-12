// SPDX-License-Identifier: GPL-3.0-or-later
// Owns ordered Network.framework frames, bounded submissions and descriptor retirement.
import Foundation
@preconcurrency import Network

actor LanTcpTransport {
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
  init(_ socket: NWConnection, profile: SessionProfile = .standard) {
    self.socket = socket
    self.profile = profile
    self.framing = LanFraming(profile: profile)
    self.budget = LanQueueBudget(profile: profile)
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
  }
  private func pathChanged(_ path: NWPath) {
    guard !closed, let interfaces else { return }
    guard path.status == .satisfied,
      path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet),
      Set(path.availableInterfaces.map(\.index)) == interfaces
    else { fail(SessionFailure.state); return }
  }
  private func stateChanged(_ state: NWConnection.State) {
    guard !closed else { return }
    switch state {
    case .ready:
      guard interfaces == nil else { return }
      guard let path = socket.currentPath,
        path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
      else { fail(SessionFailure.state); return }
      interfaces = Set(path.availableInterfaces.map(\.index))
      receive()
    case .failed(let error), .waiting(let error): fail(error)
    case .cancelled: fail(SessionFailure.cancelled)
    default: break
    }
  }
  func capacity(_ size: Int) -> Bool { !closed && budget.canReserve(size) }
  func submit(_ envelope: Data) async throws {
    guard !closed else { throw SessionFailure.cancelled }
    let bytes = try LanFraming.encode(envelope, profile: profile)
    try budget.reserve(envelope.count)
    defer { budget.release(envelope.count); changed?() }
    let token = nextWrite
    nextWrite += 1
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        writes[token] = continuation
        watchdogs[token] = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(10)) } catch { return }
          await self?.fail(SessionFailure.expired)
        }
        socket.send(
          content: bytes,
          completion: .contentProcessed { [weak self] error in
            Task { await self?.sent(token, error: error) }
          })
      }
    } onCancel: {
      Task { [weak self] in await self?.fail(SessionFailure.cancelled) }
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
  private func receive() {
    guard !closed else { return }
    socket.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
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
          let envelope = try framing.feed(data, offset: &offset, receivedAt: receivedAt)
          scheduleAssemblyDeadline()
          if let envelope { try await deliver?(envelope) }
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
    do { try framing.tick(); scheduleAssemblyDeadline() } catch { fail(error) }
  }
  private func fail(_ error: Error) {
    guard !closed else { return }
    let callback = ended
    close()
    callback?(error)
  }
  func close() {
    guard !closed else { return }
    closed = true
    assemblyWatchdog?.cancel()
    assemblyWatchdog = nil
    deliver = nil
    ended = nil
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
