// SPDX-License-Identifier: GPL-3.0-or-later
// Defines bounded Find Device envelopes within authenticated application DATA.
import Foundation

enum FindResult: Int64 { case submitted, blocked, stale, busy, failed }
enum FindWireError: Error { case malformed }
struct FindDeviceMessage: Equatable {
  let kind: Int64
  let id: String
  let sequence: Int64
  let result: Int64
  init(kind: Int64, id: String = "", sequence: Int64 = 0, result: Int64 = 0) {
    self.kind = kind; self.id = id; self.sequence = sequence; self.result = result
  }
  func encode() throws -> Data {
    let fields: [SessionCBOR] = kind == 1 ? [] : [.text(id), .integer(sequence)] + (kind == 3 ? [.integer(result)] : [])
    let bytes = try SessionCbor.encode(.array([.text("aniCe find device"), .integer(1), .integer(kind), .array(fields)]))
    _ = try Self.decode(bytes)
    return bytes
  }
  static func decode(_ bytes: Data) throws -> Self? {
    guard bytes.count <= 4000 else { return nil }
    guard case .array(let row) = try SessionCbor.decode(bytes), row.first == .text("aniCe find device") else { return nil }
    guard bytes.count <= 128, row.count == 4, row[1] == .integer(1),
      case .integer(let kind) = row[2], case .array(let fields) = row[3] else { throw FindWireError.malformed }
    if kind == 1, fields.isEmpty { return Self(kind: 1) }
    guard (kind == 2 && fields.count == 2) || (kind == 3 && fields.count == 3),
      case .text(let id) = fields[0], UUID(uuidString: id)?.uuidString.lowercased() == id,
      case .integer(let sequence) = fields[1], (1...4294967295).contains(sequence) else { throw FindWireError.malformed }
    var result: Int64 = 0
    if kind == 3 {
      guard case .integer(let value) = fields[2], FindResult(rawValue: value) != nil else { throw FindWireError.malformed }
      result = value
    }
    return Self(kind: kind, id: id, sequence: sequence, result: result)
  }
}
