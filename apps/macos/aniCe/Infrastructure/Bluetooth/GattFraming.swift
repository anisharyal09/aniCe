// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One contiguous logical message per direction; offsets and IDs reject interleaving/replay.
struct GattReassembler {
  private let version: UInt8
  private let now: () -> TimeInterval
  private var id: UInt64 = 0
  private var total = 0
  private var buffer = Data()
  private var started: TimeInterval = 0
  init(version: UInt8, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime })
  {
    self.version = version
    self.now = now
  }
  func tick() throws { if !buffer.isEmpty, now() - started >= 10 { throw SessionFailure.expired } }
  mutating func receive(_ fragment: Data) throws -> Data? {
    try tick()
    let h = version == 1 ? 7 : 9
    let bytes = [UInt8](fragment)
    guard bytes.count > h, bytes[0] == version else { throw SessionFailure.malformed }
    let width = version == 1 ? 2 : 4
    func number(_ slice: ArraySlice<UInt8>) -> UInt64 { slice.reduce(0) { ($0 << 8) | UInt64($1) } }
    let mid = number(bytes[1..<(1 + width)])
    let length = Int(number(bytes[(1 + width)..<(3 + width)]))
    let offset = Int(number(bytes[(3 + width)..<h]))
    guard mid == id, id <= (version == 1 ? 65535 : UInt64(UInt32.max)), (1...4096).contains(length),
      offset == buffer.count, buffer.isEmpty || total == length, bytes.count - h <= length - offset
    else { throw SessionFailure.malformed }
    // Progress does not extend the assembly deadline, preventing slow-fragment retention.
    if buffer.isEmpty { started = now() }
    total = length
    buffer.append(contentsOf: bytes.dropFirst(h))
    guard buffer.count == total else { return nil }
    let result = buffer
    buffer = Data()
    total = 0
    id += 1
    return result
  }
  static func fragments(_ data: Data, id: UInt64, capacity: Int, version: UInt8) throws -> [Data] {
    let h = version == 1 ? 7 : 9
    guard version == 1 || version == 2, (1...4096).contains(data.count),
      id <= (version == 1 ? 65535 : UInt64(UInt32.max)), capacity > h
    else { throw SessionFailure.malformed }
    return stride(from: 0, to: data.count, by: capacity - h).map { offset in
      Data([version]) + SessionRecordCodec.integer(id, bytes: version == 1 ? 2 : 4)
        + SessionRecordCodec.integer(UInt64(data.count), bytes: 2)
        + SessionRecordCodec.integer(UInt64(offset), bytes: 2)
        + data.subdata(in: offset..<min(data.count, offset + capacity - h))
    }
  }
}
// The discriminator sits outside EDHOC; payload bytes enter transcript hashing unchanged.
enum SessionEnvelope {
  static func encode(_ kind: UInt8, _ payload: Data) throws -> Data {
    guard (1...6).contains(kind), !payload.isEmpty, payload.count <= 4095 else {
      throw SessionFailure.malformed
    }
    return Data([kind]) + payload
  }
  static func decode(_ message: Data) throws -> (UInt8, Data) {
    guard (2...4096).contains(message.count), let kind = message.first, (1...6).contains(kind)
    else { throw SessionFailure.malformed }
    return (kind, Data(message.dropFirst()))
  }
}

/// Counts logical messages until their final fragment is submitted, including in-flight work.
struct GattQueueBudget {
  private(set) var messages = 0
  private(set) var bytes = 0
  func canReserve(_ size: Int) -> Bool {
    (1...4096).contains(size) && messages < 8 && bytes + size <= 32768
  }
  mutating func reserve(_ size: Int) throws {
    guard canReserve(size) else { throw SessionBackpressure() }
    messages += 1
    bytes += size
  }
  mutating func release(_ size: Int) {
    precondition(messages > 0 && size > 0 && size <= bytes)
    messages -= 1
    bytes -= size
  }
  mutating func clear() {
    messages = 0
    bytes = 0
  }
}

struct SessionAdmissionWindow {
  private(set) var deadline: TimeInterval?
  private(set) var failures = 0
  private(set) var admitted = false
  // Candidate failures share the original deadline; retries cannot extend the allow window.
  mutating func open(_ now: TimeInterval) { if deadline == nil { deadline = now + 120 } }
  mutating func claim(_ now: TimeInterval) -> Bool {
    guard !admitted, failures < 5, let deadline, now < deadline else { return false }
    admitted = true
    return true
  }
  mutating func retire(_ now: TimeInterval) -> Bool {
    guard admitted else { return false }
    admitted = false
    failures += 1
    return failures < 5 && now < (deadline ?? 0)
  }
  mutating func clear() {
    deadline = nil
    failures = 0
    admitted = false
  }
}

/// A cached OS subscription is a candidate only within an explicit advertised window.
enum GattCandidateAdmission {
  static func mayReuseSubscription(
    hasCandidate: Bool, advertising: Bool, subscribed: Bool, retired: Bool, blocked: Bool
  ) -> Bool {
    !hasCandidate && advertising && subscribed && !retired && !blocked
  }
}
