// SPDX-License-Identifier: GPL-3.0-or-later
// Owns bounded directional records, readiness and generation-fenced native validation.
import CryptoKit
import Foundation

enum SessionProfile: UInt8, Sendable {
  case standard = 1, bulkProbe = 2
  var maximumPlaintext: Int { self == .standard ? 4000 : 4194304 }
  var maximumEnvelope: Int { self == .standard ? 4096 : maximumPlaintext + 31 }
  var exporterLabel: String { self == .standard ? "aniCe session" : "aniCe bulk probe" }
}

enum RecordKind: UInt8, Sendable {
  case ready = 1
  case readyAck = 2
  case data = 3
  case close = 4
}
enum ChannelStage: Sendable { case waiting, readySent, readyReceived, secured, closed }
enum SessionExpiry: Sendable, Equatable { case readiness, idle, lifetime, recordLimit }

struct SessionBackpressure: Error {}

// Counters never wrap or roll back; exhausting the per-key budget requires fresh EDHOC.
struct RecordSequence {
  private(set) var value: UInt64 = 0
  mutating func reserve() throws -> UInt64 {
    guard value < 1 << 20 else { throw SessionFailure.expired }
    let result = value
    value += 1
    return result
  }
}

// Stateless wire codec; SecureSession owns sequence consumption and failure retirement.
enum SessionRecordCodec {
  static func nonce(_ iv: Data, _ sequence: UInt64) throws -> Data {
    guard iv.count == 12 else { throw SessionFailure.malformed }
    let mask = Data(repeating: 0, count: 4) + integer(sequence, bytes: 8)
    return Data(zip(iv, mask).map { $0 ^ $1 })
  }
  static func integer(_ value: UInt64, bytes: Int) -> Data {
    Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
  }
  static func seal(
    key: Data, iv: Data, id: Data, direction: UInt8, kind: RecordKind, sequence: UInt64,
    plaintext: Data, profile: SessionProfile = .standard
  ) throws -> Data {
    guard key.count == 32, iv.count == 12, id.count == 32, (1...2).contains(direction),
      plaintext.count <= profile.maximumPlaintext, kind == .data || plaintext.isEmpty
    else { throw SessionFailure.malformed }
    let header =
      Data([profile.rawValue, kind.rawValue]) + integer(sequence, bytes: 8)
      + integer(UInt64(plaintext.count), bytes: 4)
    let box = try AES.GCM.seal(
      plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce(iv, sequence)),
      authenticating: header + id + Data([direction]))
    return header + box.ciphertext + box.tag
  }
  static func open(key: Data, iv: Data, id: Data, direction: UInt8, expected: UInt64, record: Data, profile: SessionProfile = .standard)
    throws -> (RecordKind, Data)
  {
    guard key.count == 32, iv.count == 12, id.count == 32, (1...2).contains(direction) else {
      throw SessionFailure.malformed
    }
    guard (30...(profile.maximumPlaintext + 30)).contains(record.count), record.first == profile.rawValue
    else { throw SessionFailure.malformed }
    let header = Data(record.prefix(14))
    let bytes = [UInt8](header)
    guard let kind = RecordKind(rawValue: bytes[1]) else { throw SessionFailure.malformed }
    let sequence = bytes[2..<10].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    let length = bytes[10..<14].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    guard length <= UInt64(profile.maximumPlaintext), UInt64(record.count) == 30 + length else { throw SessionFailure.malformed }
    guard sequence == expected else { throw SessionFailure.authentication }
    let plain: Data
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonce(iv, sequence)),
        ciphertext: Data(record.dropFirst(14).dropLast(16)), tag: Data(record.suffix(16)))
      plain = try AES.GCM.open(
        box, using: SymmetricKey(data: key),
        authenticating: header + id + Data([direction]))
    } catch { throw SessionFailure.authentication }
    guard kind == .data || plain.isEmpty else { throw SessionFailure.malformed }
    return (kind, plain)
  }
}

/// Owns directional record keys and readiness; actor reentrancy is guarded across suspension.
actor SecureSession {
  private let responder: Bool
  private let profile: SessionProfile
  private var sendKey: Data
  private var receiveKey: Data
  private var sendIV: Data
  private var receiveIV: Data
  private var sessionID: Data
  private let validate: @Sendable () async throws -> Void
  private let capacity: @Sendable (Int) async -> Bool
  private let submit: @Sendable (Data) async throws -> Void
  private let now: @Sendable () -> TimeInterval
  private let started: TimeInterval
  private var activity: TimeInterval
  private(set) var expiration: SessionExpiry?
  private(set) var closedByPeer = false
  private var generation = 0
  // An actor can reenter at await: reject overlapping operations within each direction.
  private var sending = false
  private var receiving = false
  private var sendSequence = RecordSequence()
  private var receiveSequence = RecordSequence()
  var sent: UInt64 { sendSequence.value }
  var received: UInt64 { receiveSequence.value }
  func renewalReason() -> Int64? {
    Self.renewalReason(age: now() - started, sent: sent, received: received)
  }
  // Renewal margins reserve time/records for close; hard channel bounds remain unchanged.
  static func renewalReason(age: TimeInterval, sent: UInt64, received: UInt64) -> Int64? {
    if age >= 55 * 60 { return 1 }
    if sent >= (1 << 20) - 1024 || received >= (1 << 20) - 1024 { return 2 }
    return nil
  }
  private(set) var stage: ChannelStage = .waiting
  init(
    responder: Bool, sendKey: Data, receiveKey: Data, sendIV: Data, receiveIV: Data,
    sessionID: Data,
    validate: @escaping @Sendable () async throws -> Void,
    capacity: @escaping @Sendable (Int) async -> Bool,
    submit: @escaping @Sendable (Data) async throws -> Void,
    now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    profile: SessionProfile = .standard
  ) throws {
    guard sendKey.count == 32, receiveKey.count == 32, sendIV.count == 12, receiveIV.count == 12,
      sessionID.count == 32
    else { throw SessionFailure.malformed }
    self.responder = responder
    self.profile = profile
    self.sendKey = sendKey
    self.receiveKey = receiveKey
    self.sendIV = sendIV
    self.receiveIV = receiveIV
    self.sessionID = sessionID
    self.validate = validate
    self.capacity = capacity
    self.submit = submit
    self.now = now
    self.started = now()
    self.activity = started
  }
  private func ensure(_ op: Int) throws {
    guard op == generation, stage != .closed else { throw SessionFailure.cancelled }
  }
  func nextDeadline(renew: Bool = false) -> TimeInterval? {
    guard stage != .closed else { return nil }
    var deadlines = [started + 3600, activity + 120]
    if stage != .secured { deadlines.append(started + 10) }
    if renew { deadlines.append(renewalReason() == nil ? started + 3300 : now()) }
    return deadlines.min()
  }
  func checkDeadlines() throws {
    do { try checkTime(generation) } catch { close(); throw error }
  }
  private func check(_ op: Int) async throws {
    try checkTime(op)
    try await validate()
    try ensure(op)
  }
  private func checkTime(_ op: Int) throws {
    try ensure(op)
    let time = now()
    let expired: SessionExpiry?
    if time - started >= 3600 {
      expired = .lifetime
    } else if stage != .secured && time - started >= 10 {
      expired = .readiness
    } else if time - activity >= 120 {
      expired = .idle
    } else {
      expired = nil
    }
    if let expired {
      expiration = expired
      throw SessionFailure.expired
    }
  }
  func tick() async throws {
    do { try await check(generation) } catch {
      close()
      throw error
    }
  }
  func send(_ kind: RecordKind, plaintext: Data = Data()) async throws {
    guard !sending else { throw SessionBackpressure() }
    sending = true
    let op = generation
    var reserved = false
    defer { if op == generation { sending = false } }
    do {
      try await check(op)
      guard plaintext.count <= profile.maximumPlaintext, kind == .data || plaintext.isEmpty else {
        throw SessionFailure.malformed
      }
      let permitted: Bool
      switch kind {
      case .ready: permitted = !responder && stage == .waiting
      case .readyAck: permitted = responder && stage == .readyReceived
      case .data, .close: permitted = stage == .secured
      }
      guard permitted else { throw SessionFailure.state }
      guard sent < 1 << 20 else {
        expiration = .recordLimit
        throw SessionFailure.expired
      }
      // Include the record header, tag and envelope byte before consuming a nonce.
      guard await capacity(plaintext.count + 31) else { throw SessionBackpressure() }
      try await check(op)
      let sequence = try sendSequence.reserve()
      reserved = true  // A reserved nonce remains burned even when encryption/submission fails.
      if kind == .ready { stage = .readySent }
      let record = try SessionRecordCodec.seal(
        key: sendKey, iv: sendIV, id: sessionID, direction: responder ? 2 : 1, kind: kind,
        sequence: sequence, plaintext: plaintext, profile: profile)
      try await submit(record)
      try await check(op)
      activity = now()
      if kind == .readyAck { stage = .secured }
      if kind == .close { close() }
    } catch is SessionBackpressure {
      if reserved {
        close()
        throw SessionFailure.state
      }
      throw SessionBackpressure()
    } catch {
      close()
      throw error
    }
  }
  func receive(_ record: Data) async throws -> (RecordKind, Data) {
    guard !receiving else {
      close()
      throw SessionFailure.state
    }
    receiving = true
    let op = generation
    defer { if op == generation { receiving = false } }
    do {
      try await check(op)
      guard received < 1 << 20 else {
        expiration = .recordLimit
        throw SessionFailure.expired
      }
      let result = try SessionRecordCodec.open(
        key: receiveKey, iv: receiveIV, id: sessionID, direction: responder ? 1 : 2,
        expected: received, record: record, profile: profile)
      let allowed: Bool
      switch result.0 {
      case .ready: allowed = responder && stage == .waiting
      case .readyAck: allowed = !responder && stage == .readySent
      case .data, .close: allowed = stage == .secured
      }
      guard allowed else { throw SessionFailure.state }
      // Advance only after tag verification and a valid readiness/state transition.
      _ = try receiveSequence.reserve()
      activity = now()
      switch result.0 {
      case .ready: stage = .readyReceived
      case .readyAck: stage = .secured
      case .close:
        closedByPeer = true
        close()
      default: break
      }
      return result
    } catch {
      close()
      throw error
    }
  }
  func close() {
    generation += 1
    stage = .closed
    sending = false
    receiving = false
    // Best effort: Data copies and CryptoKit/provider-owned key material may remain.
    sendKey.resetBytes(in: 0..<sendKey.count)
    receiveKey.resetBytes(in: 0..<receiveKey.count)
    sendIV.resetBytes(in: 0..<sendIV.count)
    receiveIV.resetBytes(in: 0..<receiveIV.count)
    sessionID.resetBytes(in: 0..<sessionID.count)
    sendKey = Data()
    receiveKey = Data()
    sendIV = Data()
    receiveIV = Data()
    sessionID = Data()
  }
  static func fromHandshake(
    _ handshake: SessionHandshakeEngine, responder: Bool,
    capacity: @escaping @Sendable (Int) async -> Bool,
    submit: @escaping @Sendable (Data) async throws -> Void,
    now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    profile: SessionProfile = .standard
  ) async throws -> SecureSession {
    // Binding order is initiator/responder on both peers; purpose/direction separate exports.
    let bindings = try await handshake.bindings()
    func export(_ direction: Int64, _ purpose: String, _ length: Int) async throws -> Data {
      let bounds: [SessionCBOR] = profile == .standard ? [] : [.integer(Int64(profile.maximumPlaintext))]
      let context = try SessionCbor.encode(.array(
        [.text(profile.exporterLabel), .integer(1)] + bounds +
        [.bytes(bindings.0), .bytes(bindings.1), .integer(direction), .text(purpose)]))
      return try await handshake.export(context: context, length: length)
    }
    var material = [Data]()
    do {
      let i: Int64 = responder ? 2 : 1
      let r: Int64 = responder ? 1 : 2
      material.append(try await export(i, "key", 32))
      material.append(try await export(r, "key", 32))
      material.append(try await export(i, "iv", 12))
      material.append(try await export(r, "iv", 12))
      material.append(try await export(0, "session-id", 32))
      return try SecureSession(
        responder: responder, sendKey: material[0], receiveKey: material[1], sendIV: material[2],
        receiveIV: material[3], sessionID: material[4],
        validate: { try await handshake.checkDeadline() }, capacity: capacity, submit: submit, now: now, profile: profile)
    } catch {
      for i in material.indices { material[i].resetBytes(in: 0..<material[i].count) }
      throw error
    }
  }
}
