// SPDX-License-Identifier: GPL-3.0-or-later
// Validates bounded media messages separately from authenticated session readiness and control records.
import Foundation

enum MediaWireError: Error { case malformed, unsupported }
struct MediaMessage: Equatable, Sendable {
  let kind: Int64
  let fields: [SessionCBOR]
  func encode() throws -> Data {
    try validate()
    let bytes = try SessionCbor.encode(.array([.text("aniCe media"), .integer(1), .integer(kind), .array(fields)]))
    guard bytes.count <= 4000 else { throw MediaWireError.malformed }
    return bytes
  }
  static func decode(_ bytes: Data) throws -> Self? {
    guard bytes.count <= 4000 else { throw MediaWireError.malformed }
    guard case .array(let row) = try SessionCbor.decode(bytes), row.first == .text("aniCe media") else { return nil }
    guard row.count == 4, case .integer(let version) = row[1] else { throw MediaWireError.malformed }
    guard version == 1 else { throw MediaWireError.unsupported }
    guard case .integer(let kind) = row[2], case .array(let fields) = row[3] else { throw MediaWireError.malformed }
    let message = Self(kind: kind, fields: fields); try message.validate(); return message
  }
  func validate() throws {
    func require(_ value: Bool) throws { if !value { throw MediaWireError.malformed } }
    func integer(_ i: Int, _ range: ClosedRange<Int64>) -> Bool {
      guard fields.indices.contains(i), case .integer(let n) = fields[i] else { return false }; return range.contains(n)
    }
    func text(_ i: Int, _ count: Int, uuid: Bool = false, empty: Bool = false) -> Bool {
      guard fields.indices.contains(i), case .text(let s) = fields[i], s.utf8.count <= count, !s.contains("\0") else { return false }
      return !uuid || (empty && s.isEmpty) || (s.utf8.count == 36 && UUID(uuidString: s) != nil)
    }
    func blob(_ i: Int, _ counts: Set<Int>) -> Bool { guard fields.indices.contains(i), case .bytes(let d) = fields[i] else { return false }; return counts.contains(d.count) }
    switch kind {
    case 1: try require(fields.count == 2 && integer(0, 1...1)); guard case .bool = fields[1] else { throw MediaWireError.malformed }
    case 2, 3, 4: try require(fields.count == 1 && text(0, 36, uuid: true))
    case 5:
      try require(fields.count == 15 && text(0,36,uuid:true) && text(1,36,uuid:true,empty:true) && text(2,36,uuid:true,empty:true)
        && text(3,512) && text(4,256) && text(5,96) && integer(6,0...3) && integer(7,-1...604800000) && integer(8,-1...604800000)
        && integer(9,0...16000) && integer(10,0...31) && text(11,36,uuid:true,empty:true) && text(12,36,uuid:true) && blob(14,[0,32]))
      guard case .array(let sources) = fields[13], sources.count <= 16 else { throw MediaWireError.malformed }
      var ids = Set<String>()
      for source in sources {
        guard case .array(let s) = source, s.count == 3, case .text(let id) = s[0], UUID(uuidString:id) != nil, id.utf8.count == 36,
          ids.insert(id).inserted, case .text(let name) = s[1], name.utf8.count <= 96, !name.contains("\0"),
          case .integer(let state) = s[2], (0...3).contains(state) else { throw MediaWireError.malformed }
      }
      try require(string(1).isEmpty == string(2).isEmpty)
      try require(string(1).isEmpty || ids.contains(string(1)))
      try require(string(11).isEmpty || ids.contains(string(11)))
      try require(number(10) & 8 == 0 || number(8)>0)
      try require(!string(1).isEmpty || (number(10)==0 && fields[14] == .bytes(Data())))
    case 6: try require(fields.count == 6 && text(0,36,uuid:true) && integer(1,1...4294967295) && text(2,36,uuid:true,empty:true) && text(3,36,uuid:true) && integer(4,1...6) && integer(5,0...604800000))
      try require((number(4)==6) == string(2).isEmpty)
      try require(number(4)==4 || number(5)==0)
    case 7: try require(fields.count == 3 && text(0,36,uuid:true) && integer(1,1...4294967295) && integer(2,0...7))
    case 8:
      try require(fields.count == 7 && text(0,36,uuid:true) && text(1,36,uuid:true) && text(2,36,uuid:true) && blob(3,[32]) && integer(4,1...65536) && integer(5,0...65535))
      guard case .bytes(let chunk) = fields[6], (1...2048).contains(chunk.count), number(5)+Int64(chunk.count) <= number(4) else { throw MediaWireError.malformed }
    default: throw MediaWireError.unsupported
    }
  }
  func string(_ i: Int) -> String { if case .text(let v) = fields[i] { return v }; return "" }
  func number(_ i: Int) -> Int64 { if case .integer(let v) = fields[i] { return v }; return 0 }
}
