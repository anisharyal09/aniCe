// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Owns EDHOC/envelope ordering and readiness; transport queues remain outside authentication.
actor SessionConnection {
  private let handshake: SessionHandshakeEngine
  private let responder: Bool
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
  private var sendingControl = false
  private var liveness: SessionLiveness?
  private let now: @Sendable () -> Int64
  private var renew: Bool
  var controlSupport: Bool? { liveness?.support }
  var renewalReason: Int64? { responder ? nil : liveness?.renewalReason }
  func enableRenewal() { if !closed { renew = true } }
  init(
    handshake: SessionHandshakeEngine, responder: Bool,
    capacity: @escaping @Sendable (Int) async -> Bool,
    submit: @escaping @Sendable (Data) async throws -> Void,
    data: @escaping @Sendable (Data) async -> Void,
    secured: @escaping @Sendable () async -> Void,
    controls: Bool = false,
    now: @escaping @Sendable () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) },
    renew: Bool = false
  ) {
    self.handshake = handshake
    self.responder = responder
    self.capacity = capacity
    self.submit = submit
    self.data = data
    self.secured = secured
    self.now = now
    self.renew = renew
    liveness = controls ? SessionLiveness(responder: responder) : nil
    expected = responder ? 1 : 2
  }
  private func ensure(_ op: Int) throws {
    guard !closed, op == generation else { throw SessionFailure.cancelled }
  }
  func start() async throws {
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
  func receive(_ envelope: Data) async throws {
    let op = generation
    guard !processing else {
      await close()
      throw SessionFailure.state
    }
    processing = true
    defer { if op == generation { processing = false } }
    do {
      try ensure(op)
      let (kind, payload) = try SessionEnvelope.decode(envelope)
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
          await secured()
          try ensure(op)
          try liveness?.start(now())
        case .readyAck:
          await secured()
          try ensure(op)
          try liveness?.start(now())
        case .data:
          if liveness != nil, let control = try SessionControl.application(result.1) {
            try liveness?.receive(control, now())
          } else { await data(result.1) }
        case .close:
          closedByPeer = true
          await close()
        }
        if !closed { try await flushControl(op) }
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
  }
  private func makeChannel(_ op: Int) async throws {
    // Exporting can suspend; close the newly created channel if ownership was retired meanwhile.
    let clock = now
    let ch = try await SecureSession.fromHandshake(
      handshake, responder: responder, capacity: capacity,
      submit: { [submit] record in try await submit(SessionEnvelope.encode(6, record)) },
      now: { Double(clock()) / 1000 })
    do {
      try ensure(op)
      channel = ch
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
  func sendData(_ bytes: Data) async throws {
    let op = generation
    do {
      try ensure(op)
      if liveness?.renewalReason != nil { throw SessionBackpressure() }
      guard let channel else { throw SessionFailure.state }
      try await channel.send(.data, plaintext: bytes)
      try ensure(op)
      liveness?.activity(now())
    } catch is SessionBackpressure { throw SessionBackpressure() } catch {
      await close()
      throw error
    }
  }
  func tick() async throws {
    // Actor reentrancy must not let a health check race a suspended authenticated close.
    if processing { return }
    let op = generation
    do {
      try ensure(op)
      if let channel { try await channel.tick() } else { try await handshake.checkDeadline() }
      try ensure(op)
      if renew, let reason = await channel?.renewalReason() {
        try ensure(op)
        try liveness?.requestRenewal(reason)
      }
      try liveness?.poll(now())
      try await flushControl(op)
    } catch {
      await close()
      throw error
    }
  }
  private func flushControl(_ op: Int) async throws {
    guard !sendingControl, let message = liveness?.pending, let channel else { return }
    sendingControl = true
    defer { if op == generation { sendingControl = false } }
    let bytes = try message.encode()
    guard await capacity(bytes.count + 31) else { return }
    try ensure(op)
    // Actor reentrancy may deliver the response before submit returns; issue before awaiting it.
    try liveness?.issuing(message, now())
    do {
      try await channel.send(.data, plaintext: bytes)
      try ensure(op)
      liveness?.submitted(message, now())
    } catch is SessionBackpressure { /* No nonce consumed; retain the single pending control. */ }
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
    generation += 1
    processing = false
    sendingControl = false
    let old = channel
    channel = nil
    if expiration == nil { expiration = await old?.expiration }
    if await old?.closedByPeer == true { closedByPeer = true }
    await old?.close()
    await handshake.close()
  }
}
