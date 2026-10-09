// SPDX-License-Identifier: GPL-3.0-or-later
// Owns ordered Network.framework frames, bounded submissions and descriptor retirement.
import Foundation
@preconcurrency import Network

@MainActor final class LanTcpTransport {
  private let socket: NWConnection
  private var framing = LanFraming()
  private var budget = GattQueueBudget()
  private var closed = false
  private var interfaces: Set<Int>?
  private var nextWrite = 0
  private var writes = [Int: CheckedContinuation<Void, Error>]()
  private var watchdogs = [Int: Task<Void, Never>]()
  private var deliver: ((Data) async throws -> Void)?
  private var ended: ((Error) -> Void)?
  init(_ socket: NWConnection) { self.socket = socket }
  static func parameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
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
  func start(deliver: @escaping (Data) async throws -> Void, ended: @escaping (Error) -> Void) {
    self.deliver = deliver
    self.ended = ended
    socket.pathUpdateHandler = { [weak self] path in
      Task { @MainActor in
        guard let self, !self.closed, let interfaces = self.interfaces else { return }
        guard path.status == .satisfied,
          path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet),
          Set(path.availableInterfaces.map(\.index)) == interfaces
        else {
          self.fail(SessionFailure.state)
          return
        }
      }
    }
    socket.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        guard let self, !self.closed else { return }
        switch state {
        case .ready:
          guard let path = self.socket.currentPath,
            path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
          else {
            self.fail(SessionFailure.state)
            return
          }
          self.interfaces = Set(path.availableInterfaces.map(\.index))
          self.receive()
        case .failed(let error), .waiting(let error): self.fail(error)
        case .cancelled: self.fail(SessionFailure.cancelled)
        default: break
        }
      }
    }
    socket.start(queue: DispatchQueue(label: "aniCe LAN connection"))
  }
  func capacity(_ size: Int) -> Bool { !closed && budget.canReserve(size) }
  func submit(_ envelope: Data) async throws {
    guard !closed else { throw SessionFailure.cancelled }
    let bytes = try LanFraming.encode(envelope)
    try budget.reserve(envelope.count)
    defer { budget.release(envelope.count) }
    let token = nextWrite
    nextWrite += 1
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        writes[token] = continuation
        watchdogs[token] = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(10)) } catch { return }
          self?.fail(SessionFailure.expired)
        }
        socket.send(
          content: bytes,
          completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
              guard let self, let pending = self.writes.removeValue(forKey: token) else { return }
              self.watchdogs.removeValue(forKey: token)?.cancel()
              if let error {
                pending.resume(throwing: error)
                self.fail(error)
              } else {
                pending.resume()
              }
            }
          })
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.fail(SessionFailure.cancelled) }
    }
  }
  private func receive() {
    guard !closed else { return }
    socket.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
      [weak self] data, _, complete, error in
      Task { @MainActor in
        guard let self, !self.closed else { return }
        do {
          if let data {
            // Await delivery before reading more: authentication never races a second receive.
            for byte in data {
              guard !self.closed else { return }
              if let envelope = try self.framing.feed(byte) { try await self.deliver?(envelope) }
            }
          }
          if let error { throw error }
          if complete {
            try self.framing.end()
            throw SessionFailure.cancelled
          }
          self.receive()
        } catch { self.fail(error) }
      }
    }
  }
  func tick() throws { try framing.tick() }
  private func fail(_ error: Error) {
    guard !closed else { return }
    let callback = ended
    close()
    callback?(error)
  }
  func close() {
    guard !closed else { return }
    closed = true
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
