// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds TCP frame allocation and assembly independently of session authentication.
import Foundation

struct LanFraming {
  private let now: () -> TimeInterval
  private var header = [UInt8]()
  private var body = Data()
  private var length = 0
  private var started: TimeInterval = 0
  private var failed = false
  init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.now = now
  }
  var nextDeadline: TimeInterval? { !failed && !header.isEmpty ? started + 10 : nil }
  mutating func tick() throws {
    guard !failed else { throw SessionFailure.cancelled }
    if !header.isEmpty, now() - started >= 10 {
      failed = true
      body = Data()
      throw SessionFailure.expired
    }
  }
  mutating func feed(_ byte: UInt8) throws -> Data? {
    try tick()
    if header.isEmpty { started = now() }
    if header.count < 5 {
      header.append(byte)
      if header.count == 1, byte != 1 {
        failed = true
        throw SessionFailure.unsupportedProfile
      }
      if header.count == 5 {
        let size = header.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard (2...4096).contains(size) else {
          failed = true
          throw SessionFailure.malformed
        }
        length = Int(size)
        body.reserveCapacity(length)
      }
      return nil
    }
    body.append(byte)
    guard body.count == length else { return nil }
    let result = body
    header.removeAll(keepingCapacity: true)
    body = Data()
    length = 0
    return result
  }
  mutating func end() throws {
    try tick()
    guard header.isEmpty else {
      failed = true
      throw SessionFailure.malformed
    }
  }
  static func encode(_ envelope: Data) throws -> Data {
    guard (2...4096).contains(envelope.count) else { throw SessionFailure.malformed }
    return Data([1]) + SessionRecordCodec.integer(UInt64(envelope.count), bytes: 4) + envelope
  }
}
