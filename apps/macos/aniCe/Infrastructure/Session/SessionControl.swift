// SPDX-License-Identifier: GPL-3.0-or-later
// Validates control messages and enforces compatibility, ping ordering and renewal thresholds.
import Foundation

enum ControlKind: Int64, Sendable {
  case hello = 1, helloAck, ping, pong, renewalRequest
  var field: String {
    switch self {
    case .hello, .helloAck: "version"
    case .ping, .pong: "requestId"
    case .renewalRequest: "reason"
    }
  }
}

/// Exact DATA payload defined by protocol/session/control.cddl; no new record kind or keys.
struct SessionControl: Equatable, Sendable {
  let kind: ControlKind
  var value: Int64 = 1
  private static let tag = "aniCe control"
  private func validate() throws {
    let valid: Bool
    switch kind {
    case .hello, .helloAck: valid = value == 1
    case .ping, .pong: valid = (0...0xffffffff).contains(value)
    case .renewalRequest: valid = (1...2).contains(value)
    }
    guard valid else { throw SessionFailure.malformed }
  }
  func encode() throws -> Data {
    try validate()
    return try SessionCbor.encode(.array([
      .text(Self.tag), .integer(1), .integer(kind.rawValue),
      .map([.init(.text(kind.field), .integer(value))]),
    ]))
  }
  static func decode(_ bytes: Data) throws -> Self {
    guard bytes.count <= 128 else { throw SessionFailure.malformed }
    return try fromCbor(SessionCbor.decode(bytes))
  }
  private static func fromCbor(_ cbor: SessionCBOR) throws -> Self {
    guard case .array(let row) = cbor, row.count == 4, row[0] == .text(tag),
      case .integer(let version) = row[1], case .integer(let type) = row[2]
    else { throw SessionFailure.malformed }
    guard version == 1, let kind = ControlKind(rawValue: type) else { throw SessionFailure.unsupportedProfile }
    guard case .map(let payload) = row[3], payload.count == 1,
      payload[0].key == .text(kind.field), case .integer(let value) = payload[0].value
    else { throw SessionFailure.malformed }
    let result = Self(kind: kind, value: value)
    try result.validate()
    return result
  }
  /// Valid arrays with other tags and non-array application payloads retain their existing dispatcher.
  static func application(_ bytes: Data) throws -> Self? {
    guard let first = bytes.first, first & 0xe0 == 0x80 else { return nil }
    let parsed = try SessionCbor.decode(bytes)
    guard case .array(let row) = parsed, row.first == .text(tag) else { return nil }
    guard bytes.count <= 128 else { throw SessionFailure.malformed }
    return try fromCbor(parsed)
  }
}

/// Confined to SessionConnection; monotonic milliseconds, with one pending logical control.
struct SessionLiveness {
  private let responder: Bool
  private var nextId: Int64
  private(set) var support: Bool?
  private(set) var pending: SessionControl?
  private var started = false
  private var compatibilityDeadline: Int64 = 0
  private var lastActivity: Int64 = 0
  private var helloIssued = false
  private var outstanding: Int64?
  private var pongDeadline: Int64?
  private var expectedPing: Int64 = 0
  private(set) var renewalReason: Int64?
  private var renewalSubmitted = false
  mutating func requestRenewal(_ reason: Int64) throws {
    guard (1...2).contains(reason) else { throw SessionFailure.state }
    if support == true && renewalReason == nil { renewalReason = reason }
  }
  init(responder: Bool, nextId: Int64 = 0) { self.responder = responder; self.nextId = nextId }
  mutating func start(_ now: Int64) throws {
    guard !started else { throw SessionFailure.state }
    started = true
    lastActivity = now
    compatibilityDeadline = now + 10000
    if !responder { pending = SessionControl(kind: .hello) }
  }
  mutating func activity(_ now: Int64) { lastActivity = now }
  mutating func receive(_ message: SessionControl, _ now: Int64) throws {
    guard started, support != false else { throw SessionFailure.state }
    activity(now)
    switch message.kind {
    case .hello:
      guard responder, support == nil, pending == nil, now < compatibilityDeadline else { throw SessionFailure.state }
      pending = SessionControl(kind: .helloAck)
    case .helloAck:
      guard !responder, support == nil, helloIssued, now < compatibilityDeadline else { throw SessionFailure.state }
      support = true
    case .ping:
      guard responder, support == true, pending == nil, message.value == expectedPing else { throw SessionFailure.state }
      expectedPing += 1 // Int64 storage prevents uint32 request IDs from wrapping.
      pending = SessionControl(kind: .pong, value: message.value)
    case .pong:
      guard !responder, support == true, outstanding == message.value, let pongDeadline else { throw SessionFailure.state }
      guard now < pongDeadline else { throw SessionFailure.controlTimeout }
      outstanding = nil
      self.pongDeadline = nil
    case .renewalRequest:
      guard !responder, support == true else { throw SessionFailure.state }
      try requestRenewal(message.value) // Coalesce local and remote threshold races.
    }
  }
  var nextDeadline: Int64? {
    guard started else { return nil }
    var deadlines = [Int64]()
    if support == nil || pending?.kind == .helloAck { deadlines.append(compatibilityDeadline) }
    if let pongDeadline { deadlines.append(pongDeadline) }
    if !responder, support == true, renewalReason == nil, pending == nil, outstanding == nil {
      deadlines.append(lastActivity + 60000)
    }
    return deadlines.min()
  }
  mutating func poll(_ now: Int64) throws {
    guard started else { return }
    if support == nil && now >= compatibilityDeadline { support = false; pending = nil }
    if pending?.kind == .helloAck && now >= compatibilityDeadline { throw SessionFailure.controlTimeout }
    if let pongDeadline, now >= pongDeadline { throw SessionFailure.controlTimeout }
    if responder, support == true, pending == nil, let renewalReason, !renewalSubmitted {
      pending = SessionControl(kind: .renewalRequest, value: renewalReason)
    }
    if !responder, support == true, renewalReason == nil, pending == nil, outstanding == nil, now - lastActivity >= 60000 {
      guard (0...0xffffffff).contains(nextId) else { throw SessionFailure.controlTimeout }
      pending = SessionControl(kind: .ping, value: nextId)
      nextId += 1
    }
  }
  /// Queue preflight precedes this mutation; mark issued before suspension so a fast reply can match.
  mutating func issuing(_ message: SessionControl, _ now: Int64) throws {
    guard pending == message else { throw SessionFailure.state }
    switch message.kind {
    case .hello: helloIssued = true
    case .helloAck: support = true
    case .ping:
      if outstanding == nil { outstanding = message.value; pongDeadline = now + 20000 }
    default: break
    }
  }
  mutating func submitted(_ message: SessionControl, _ now: Int64) {
    if pending == message { pending = nil }
    if message.kind == .renewalRequest { renewalSubmitted = true }
    activity(now)
  }
}
