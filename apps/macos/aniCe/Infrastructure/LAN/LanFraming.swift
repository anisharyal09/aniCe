// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds TCP frame allocation and assembly independently of session authentication.
import Foundation

struct LanFraming {
  private let profile: SessionProfile
  private let now: () -> TimeInterval
  private var header = [UInt8]()
  private var body = Data()
  private var length = 0
  private var started: TimeInterval = 0
  private var failed = false
  init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, profile: SessionProfile = .standard) {
    self.profile = profile
    self.now = now
  }
  var nextDeadline: TimeInterval? { !failed && !header.isEmpty ? started + 10 : nil }
  private mutating func check(_ time: TimeInterval) throws {
    guard !failed else { throw SessionFailure.cancelled }
    if !header.isEmpty, time - started >= 10 {
      failed = true
      body = Data()
      throw SessionFailure.expired
    }
  }
  mutating func tick() throws { try check(now()) }
  mutating func beginBuffer() throws -> TimeInterval {
    let time = now()
    try check(time)
    return time
  }
  // One receive-time sample covers the buffer; callers await each frame before consuming more.
  mutating func feed(_ bytes: Data, offset: inout Int, receivedAt time: TimeInterval) throws -> Data? {
    guard !failed else { throw SessionFailure.cancelled }
    precondition((0...bytes.count).contains(offset))
    while offset < bytes.count {
      if header.isEmpty { started = time }
      if header.count < 5 {
        let count = min(5 - header.count, bytes.count - offset)
        let start = bytes.index(bytes.startIndex, offsetBy: offset)
        header.append(contentsOf: bytes[start..<bytes.index(start, offsetBy: count)])
        offset += count
        guard header[0] == profile.rawValue else {
          failed = true
          throw SessionFailure.unsupportedProfile
        }
        if header.count < 5 { return nil }
        let size = header.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard (2...UInt32(profile.maximumEnvelope)).contains(size) else {
          failed = true
          throw SessionFailure.malformed
        }
        length = Int(size)
        body.reserveCapacity(length)
      }
      let count = min(length - body.count, bytes.count - offset)
      let start = bytes.index(bytes.startIndex, offsetBy: offset)
      body.append(bytes[start..<bytes.index(start, offsetBy: count)])
      offset += count
      if body.count == length {
        let result = body
        header.removeAll(keepingCapacity: true)
        body = Data()
        length = 0
        return result
      }
    }
    return nil
  }
  mutating func end() throws {
    try tick()
    guard header.isEmpty else {
      failed = true
      throw SessionFailure.malformed
    }
  }
  static func encode(_ envelope: Data, profile: SessionProfile = .standard) throws -> Data {
    guard (2...profile.maximumEnvelope).contains(envelope.count) else { throw SessionFailure.malformed }
    return Data([profile.rawValue]) + SessionRecordCodec.integer(UInt64(envelope.count), bytes: 4) + envelope
  }
}

// Submission bounds are profile-local; GATT and standard LAN retain their existing limits.
struct LanQueueBudget {
  let profile: SessionProfile
  private(set) var messages = 0
  private(set) var bytes = 0
  func canReserve(_ size: Int) -> Bool {
    let limit = profile == .standard ? 8 : 4
    let capacity = profile == .standard ? 32768 : 4 * profile.maximumEnvelope
    return (1...profile.maximumEnvelope).contains(size) && messages < limit && bytes + size <= capacity
  }
  mutating func reserve(_ size: Int) throws {
    guard canReserve(size) else { throw SessionBackpressure() }
    messages += 1; bytes += size
  }
  mutating func release(_ size: Int) {
    precondition(messages > 0 && size > 0 && size <= bytes)
    messages -= 1; bytes -= size
  }
}
