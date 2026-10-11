// SPDX-License-Identifier: GPL-3.0-or-later
// Defines distinct optional player and output volume envelopes without changing media v1 bytes.
import Foundation

enum VolumeScope: String, Sendable { case player="aniCe player volume", output="aniCe output volume" }

struct PlayerVolumeMessage: Equatable, Sendable {
  let scope: VolumeScope
  let kind: Int64
  let fields: [SessionCBOR]
  init(kind: Int64, fields: [SessionCBOR], scope: VolumeScope = .player) { self.kind=kind;self.fields=fields;self.scope=scope }
  func string(_ i: Int) -> String { if case .text(let s)=fields[i] { return s };return "" }
  func number(_ i: Int) -> Int64 { if case .integer(let n)=fields[i] { return n };return -1 }
  func encode() throws -> Data {
    try validate()
    let data=try SessionCbor.encode(.array([.text(scope.rawValue),.integer(1),.integer(kind),.array(fields)]))
    guard data.count<=4000 else { throw MediaWireError.malformed };return data
  }
  private func validate() throws {
    func text(_ i: Int, empty: Bool=false) -> Bool { guard fields.indices.contains(i), case .text(let s)=fields[i] else { return false };return (empty && s.isEmpty) || (s.utf8.count==36 && UUID(uuidString:s) != nil) }
    func number(_ i: Int, _ range: ClosedRange<Int64>) -> Bool { guard fields.indices.contains(i),case .integer(let n)=fields[i] else { return false };return range.contains(n) }
    let valid: Bool
    switch kind {
    case 1: valid=fields.count==1 && number(0,1...1)
    case 2:
      if fields.count==5, case .bool(let supported)=fields[3] {
        valid=text(0) && text(1,empty:true) && text(2,empty:true) && string(1).isEmpty==string(2).isEmpty && (supported ? text(1) && text(2) && number(4,0...100):number(4,-1 ... -1))
      } else { valid=false }
    case 3: valid=fields.count==5 && text(0) && number(1,1...4294967295) && text(2) && text(3) && number(4,0...100)
    case 4: valid=fields.count==3 && text(0) && number(1,1...4294967295) && number(2,0...7)
    default: valid=false
    }
    guard valid else { throw MediaWireError.malformed }
  }
  static func decode(_ data: Data) throws -> Self? {
    guard data.count<=4000 else { throw MediaWireError.malformed }
    guard case .array(let row)=try SessionCbor.decode(data), case .text(let tag)?=row.first, let scope=VolumeScope(rawValue:tag) else { return nil }
    guard row.count==4,row[1] == .integer(1),case .integer(let kind)=row[2],case .array(let fields)=row[3] else { throw MediaWireError.malformed }
    let message=Self(kind:kind,fields:fields,scope:scope);try message.validate();return message
  }
}
