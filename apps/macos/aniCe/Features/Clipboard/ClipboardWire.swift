// SPDX-License-Identifier: GPL-3.0-or-later
// Validates canonical bounded clipboard envelopes inside authenticated DATA.
import Foundation

enum ClipboardWireError: Error { case malformed }
struct ClipboardMessage: Equatable, Sendable {
  let kind: Int64
  let fields: [SessionCBOR]
  func text(_ i: Int) -> String { if case .text(let v) = fields[i] { return v }; preconditionFailure() }
  func number(_ i: Int) -> Int64 { if case .integer(let v) = fields[i] { return v }; preconditionFailure() }
  func flag(_ i: Int) -> Bool { if case .bool(let v) = fields[i] { return v }; preconditionFailure() }
  func bytes(_ i: Int) -> Data { if case .bytes(let v) = fields[i] { return v }; preconditionFailure() }
  func encode() throws -> Data {
    try validate()
    return try SessionCbor.encode(.array([.text("aniCe clipboard"), .integer(1), .integer(kind), .array(fields)]))
  }
  private func validate() throws {
    func check(_ v: Bool) throws { if !v { throw ClipboardWireError.malformed } }
    func uuid(_ i: Int) throws { guard case .text(let s) = fields[i], UUID(uuidString: s)?.uuidString.lowercased() == s else { throw ClipboardWireError.malformed } }
    func n(_ i: Int) throws -> Int64 { guard case .integer(let n) = fields[i] else { throw ClipboardWireError.malformed }; return n }
    func b(_ i: Int) throws { guard case .bool = fields[i] else { throw ClipboardWireError.malformed } }
    func revision(_ i: Int) throws { try check((1...4294967295).contains(try n(i))) }
    switch kind {
    case 1:
      try check(fields.count == 3); try uuid(0); try check(n(1) == 65536 && n(2) == 3072)
    case 2:
      try check(fields.count == 2); try revision(0); try b(1)
    case 3:
      try check(fields.count == 8); try uuid(0); try revision(1); try uuid(2); try check((0...2).contains(n(3))); try b(4)
      let size = try n(5); try check((1...65536).contains(size) && n(6) == (size + 3071) / 3072)
      guard case .bytes(let digest) = fields[7], digest.count == 32 else { throw ClipboardWireError.malformed }
    case 4:
      try check(fields.count == 3); try uuid(0); try check((0...21).contains(n(1)))
      guard case .bytes(let data) = fields[2], (1...3072).contains(data.count) else { throw ClipboardWireError.malformed }
    case 5, 7: try check(fields.count == 1); try uuid(0)
    case 6: try check(fields.count == 2); try uuid(0); try check((0...7).contains(n(1)))
    case 8: try check(fields.isEmpty)
    default: throw ClipboardWireError.malformed
    }
  }
  static func decode(_ data: Data) throws -> Self? {
    guard data.count <= 4000 else { return nil }
    guard case .array(let row) = try SessionCbor.decode(data), row.first == .text("aniCe clipboard") else { return nil }
    guard row.count == 4, row[1] == .integer(1), case .integer(let kind) = row[2], case .array(let fields) = row[3] else { throw ClipboardWireError.malformed }
    let m = Self(kind: kind, fields: fields)
    try m.validate()
    guard try m.encode() == data else { throw ClipboardWireError.malformed }
    return m
  }
  static func id(_ kind: Int64, _ id: String) -> Self { Self(kind: kind, fields: [.text(id)]) }
  static func result(_ id: String, _ code: Int64) -> Self { Self(kind: 6, fields: [.text(id), .integer(code)]) }
}

enum ClipboardLink {
  static func url(_ value: String) -> URL? {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      let components = URLComponents(string: text),
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty else { return nil }
    return components.url
  }
}
