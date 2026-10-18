// SPDX-License-Identifier: GPL-3.0-or-later
// Validates canonical bounded SMS relay envelopes inside authenticated DATA.
import Foundation

enum SmsWireError: Error { case malformed }
struct SmsMessage: Equatable, Sendable {
  static let tag = "aniCe sms"
  static let maxBodyBytes: Int64 = 24576
  static let maxFragments: Int64 = 8
  static let maxDate: Int64 = 9007199254740991
  static let maximumThreads = 50
  static let maximumMessages = 50
  /** First page requested when a conversation is opened; older pages continue from its cursor. */
  static let defaultPageSize = 20
  let kind: Int64
  let fields: [SessionCBOR]
  func text(_ i: Int) -> String { if case .text(let v) = fields[i] { return v }; preconditionFailure() }
  func number(_ i: Int) -> Int64 { if case .integer(let v) = fields[i] { return v }; preconditionFailure() }
  func flag(_ i: Int) -> Bool { if case .bool(let v) = fields[i] { return v }; preconditionFailure() }
  func bytes(_ i: Int) -> Data { if case .bytes(let v) = fields[i] { return v }; preconditionFailure() }
  func encode() throws -> Data {
    try validate()
    return try SessionCbor.encode(.array([.text(Self.tag), .integer(1), .integer(kind), .array(fields)]))
  }
  private func validate() throws {
    func check(_ v: Bool) throws { if !v { throw SmsWireError.malformed } }
    func n(_ i: Int) throws -> Int64 { guard case .integer(let v) = fields[i] else { throw SmsWireError.malformed }; return v }
    func string(_ i: Int) throws -> String { guard case .text(let v) = fields[i] else { throw SmsWireError.malformed }; return v }
    func uuid(_ i: Int) throws { let s = try string(i); try check(UUID(uuidString: s)?.uuidString.lowercased() == s) }
    func uuidOrEmpty(_ i: Int) throws { if try !string(i).isEmpty { try uuid(i) } }
    func messageId(_ i: Int) throws { try check(Self.isMessageId(try string(i))) }
    func cursorId(_ i: Int) throws { let s = try string(i); try check(s.isEmpty || Self.isMessageId(s)) }
    func millis(_ i: Int) throws { try check((0...Self.maxDate).contains(try n(i))) }
    func result(_ i: Int) throws { try check((0...6).contains(try n(i))) }
    func threadId(_ i: Int) throws { try check((1...80).contains(try string(i).utf8.count)) }
    func address(_ i: Int) throws { try check((1...64).contains(try string(i).utf8.count)) }
    func snippet(_ i: Int) throws { try check(try string(i).utf8.count <= 160) }
    func bool(_ i: Int) throws { if case .bool = fields[i] { return }; throw SmsWireError.malformed }
    func body(_ total: Int, _ count: Int) throws {
      let size = try n(total)
      try check((1...Self.maxBodyBytes).contains(size) && n(count) == (size + 3071) / 3072 && (1...Self.maxFragments).contains(n(count)))
    }
    func fragment(_ i: Int) throws {
      try check((0...Self.maxFragments - 1).contains(n(i)))
      guard case .bytes(let data) = fields[i + 1], (1...3072).contains(data.count) else { throw SmsWireError.malformed }
    }
    switch kind {
    case 1:
      try check(fields.count == 4 && n(0) == Self.maxBodyBytes && n(1) == Self.maxFragments)
      try check(n(2) == Int64(Self.maximumThreads) && n(3) == Int64(Self.maximumMessages))
    case 2:
      try check(fields.count == 1); try uuid(0)
    case 3:
      try check(fields.count == 6); try uuid(0); try threadId(1); try address(2); try snippet(3); try millis(4); try millis(5)
    case 4:
      try check(fields.count == 2); try uuid(0); try result(1)
    case 5:
      try check(fields.count == 5); try uuid(0); try threadId(1); try millis(2); try cursorId(3)
      try check((1...Int64(Self.maximumMessages)).contains(n(4)))
    case 6:
      try check(fields.count == 11); try uuid(0); try uuidOrEmpty(1); try messageId(2); try threadId(3); try address(4); try millis(5)
      try check((0...1).contains(n(6))); try bool(7); try body(8, 9)
      guard case .bytes(let digest) = fields[10], digest.count == 32 else { throw SmsWireError.malformed }
    case 7, 12:
      try check(fields.count == 3); try uuid(0); try fragment(1)
    case 8, 13:
      try check(fields.count == 1); try uuid(0)
    case 9:
      try check(fields.count == 2); try uuid(0); try result(1)
    case 10:
      try check(fields.count == 4); try uuid(0); try result(1); try millis(2); try cursorId(3)
    case 11:
      try check(fields.count == 6); try uuid(0); try threadId(1); try address(2); try body(3, 4)
      guard case .bytes(let digest) = fields[5], digest.count == 32 else { throw SmsWireError.malformed }
    case 14:
      try check(fields.count == 4); try uuid(0)
      let code = try n(1), id = try string(2)
      try check((0...6).contains(code) && (id.isEmpty || Self.isMessageId(id)) && (code == 0 || id.isEmpty))
      try millis(3)
    default: throw SmsWireError.malformed
    }
  }
  static func decode(_ bytes: Data) throws -> Self? {
    guard bytes.count <= 4000 else { return nil }
    guard case .array(let row) = try SessionCbor.decode(bytes), row.first == .text(tag) else { return nil }
    guard row.count == 4, row[1] == .integer(1), case .integer(let kind) = row[2], case .array(let fields) = row[3] else { throw SmsWireError.malformed }
    let message = Self(kind: kind, fields: fields)
    try message.validate()
    guard try message.encode() == bytes else { throw SmsWireError.malformed }
    return message
  }
  // Provider ids stay digits only and live ids stay 32 lowercase hex characters; never parse the numeric id.
  static func isMessageId(_ value: String) -> Bool {
    if value.hasPrefix("live:") {
      let hex = value.dropFirst(5)
      return hex.count == 32 && hex.allSatisfy { "0123456789abcdef".contains($0) }
    }
    for prefix in ["sms:", "mms:"] where value.hasPrefix(prefix) {
      let digits = value.dropFirst(prefix.count)
      return (1...19).contains(digits.count) && digits.allSatisfy { $0 >= "0" && $0 <= "9" }
    }
    return false
  }
}
