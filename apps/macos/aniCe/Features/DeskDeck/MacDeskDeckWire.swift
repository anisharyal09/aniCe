// SPDX-License-Identifier: GPL-3.0-or-later
// Encodes and validates Desk Deck messages.
import Foundation

enum MacDeskDeckWireError: Error { case malformed }

struct MacDeskDeckShortcut: Equatable {
  let id: String
  let name: String
}

struct MacDeskDeckMessage {
  let version: Int64
  let kind: Int64
  let fields: [SessionCBOR]

  init(version: Int64 = 1, kind: Int64, fields: [SessionCBOR]) {
    self.version = version
    self.kind = kind
    self.fields = fields
  }

  func encode() throws -> Data {
    try validate()
    let limit = version == 1 ? 512 : 3800
    let data = try SessionCbor.encode(.array([.text("aniCe desk deck"), .integer(version), .integer(kind), .array(fields)]), maximumBytes: limit)
    guard data.count <= limit else { throw MacDeskDeckWireError.malformed }
    return data
  }

  static func decode(_ data: Data) throws -> Self? {
    guard data.count <= 4000 else { throw MacDeskDeckWireError.malformed }
    guard case .array(let row) = try SessionCbor.decode(data), case .text("aniCe desk deck")? = row.first else { return nil }
    guard row.count == 4, case .integer(let version) = row[1], (1...5).contains(version),
      data.count <= (version == 1 ? 512 : 3800), case .integer(let kind) = row[2], case .array(let fields) = row[3] else {
      throw MacDeskDeckWireError.malformed
    }
    let message = Self(version: version, kind: kind, fields: fields)
    try message.validate()
    return message
  }

  func number(_ index: Int) -> Int64 { if fields.indices.contains(index), case .integer(let value) = fields[index] { return value }; return -1 }
  func string(_ index: Int) -> String { if fields.indices.contains(index), case .text(let value) = fields[index] { return value }; return "" }
  func bool(_ index: Int) -> Bool { if fields.indices.contains(index), case .bool(let value) = fields[index] { return value }; return false }

  private func validate() throws {
    guard (1...5).contains(version) else { throw MacDeskDeckWireError.malformed }
    func text(_ i: Int) -> Bool { fields.indices.contains(i) && { if case .text = fields[i] { return true }; return false }() }
    func number(_ i: Int, _ range: ClosedRange<Int64>) -> Bool { fields.indices.contains(i) && { if case .integer(let n) = fields[i] { return range.contains(n) }; return false }() }
    func integer(_ i: Int) -> Int64 { self.number(i) }
    func bool(_ i: Int) -> Bool { fields.indices.contains(i) && { if case .bool = fields[i] { return true }; return false }() }
    func uuid(_ i: Int) -> Bool { guard text(i), let value = UUID(uuidString: string(i)) else { return false }; return value.uuidString.lowercased() == string(i) }
    func validIdentity(_ supported: Bool, _ target: String, _ revision: String) -> Bool {
      supported ? !target.isEmpty && !revision.isEmpty : target.isEmpty && revision.isEmpty
    }
    func validControl(_ supported: Bool, _ target: String, _ revision: String, _ level: Int64) -> Bool {
      supported ? !target.isEmpty && !revision.isEmpty && (0...100).contains(level) : target.isEmpty && revision.isEmpty && level == -1
    }
    let validMemory: Bool = {
      guard fields.indices.contains(3), fields.indices.contains(4), case .integer(let used) = fields[3], case .integer(let total) = fields[4] else { return false }
      return used >= 0 && total >= 0 && used <= total
    }()
    let valid: Bool
    let capabilityMask: ClosedRange<Int64> = version >= 5 ? 0...63 : version >= 4 ? 0...31 : 0...15
    switch kind {
    case 1: valid = fields.count == 1 && number(0, capabilityMask)
    case 2, 6, 7: valid = fields.count == 1 && uuid(0) && (kind != 7 || version >= 2)
    case 8: valid = version >= 2 && fields.count == 2 && uuid(0) && number(1, 0...3)
    case 10: valid = version >= 2 && fields.count == 2 && uuid(0) && uuid(1)
    case 11: valid = version >= 5 && fields.count == 2 && uuid(0) && number(1, 0...3)
    case 13: valid = version >= 5 && fields.count == 2 && uuid(0) && uuid(1)
    case 9, 12:
      guard version >= (kind == 12 ? 5 : 2), fields.count == 5, uuid(0), number(1, 0...3), number(2, 1...4), integer(1) < integer(2), uuid(3),
        fields.indices.contains(4), case .array(let rows) = fields[4], rows.count <= 8 else { throw MacDeskDeckWireError.malformed }
      var ids = Set<String>()
      valid = rows.allSatisfy { item in
        guard case .array(let pair) = item, pair.count == 2, case .text(let id) = pair[0],
          let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id,
          case .text(let name) = pair[1], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          name.utf16.count <= 80, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          ids.insert(id).inserted else { return false }
        return true
      }
    case 3:
      if version == 1 {
        valid = fields.count == 19 && uuid(0) && number(1, 1...4294967295) && number(2, -1...100) &&
          validMemory && number(5, 0...3) && number(6, 0...15) && bool(7) && text(8) && text(9) && number(10, -1...100) &&
          bool(11) && text(12) && text(13) && bool(14) && bool(15) && text(16) && text(17) && number(18, -1...100) &&
          validControl(self.bool(7), self.string(8), self.string(9), self.number(10)) && validIdentity(self.bool(11), self.string(12), self.string(13)) &&
          validControl(self.bool(15), self.string(16), self.string(17), self.number(18))
      } else {
        guard fields.count == (version >= 5 ? 25 : version >= 3 ? 24 : 20), uuid(0) else { throw MacDeskDeckWireError.malformed }
        let active = integer(3), wired = integer(4), compressed = integer(5), total = integer(6)
        let sumValid = active >= 0 && wired >= 0 && compressed >= 0 && total >= 0 && active <= total && wired <= total - active && compressed <= total - active - wired
        let detailValid: Bool
        if version >= 3 {
          let app = integer(20), cached = integer(21), free = integer(22), swap = integer(23)
          detailValid = (20...23).allSatisfy { number($0, -1...Int64.max) } &&
            ((app == -1 && cached == -1 && free == -1 && swap == -1) ||
             (app >= 0 && app <= total && cached >= 0 && cached <= total && free >= 0 && free <= total &&
              cached <= total - free && app <= total - free - cached &&
              wired >= 0 && wired <= total - free - cached - app && compressed >= 0 && compressed <= total - free - cached - app - wired))
        } else { detailValid = true }
        let selectedOutputValid = version < 5 || (text(24) && (string(24).isEmpty || uuid(24)))
        valid = number(3, 0...Int64.max) && number(4, 0...Int64.max) && number(5, 0...Int64.max) && number(6, 0...Int64.max) &&
          number(1, 1...4294967295) && number(2, -1...100) && sumValid && detailValid && number(7, 0...3) && number(8, capabilityMask) &&
          bool(9) && text(10) && text(11) && number(12, -1...100) && bool(13) && text(14) && text(15) && bool(16) &&
          number(17, 0...5) && number(18, -1...100) && number(19, 0...3) &&
          (integer(17) >= 2 || integer(18) == -1) && selectedOutputValid &&
          validControl(self.bool(9), self.string(10), self.string(11), self.number(12)) && validIdentity(self.bool(13), self.string(14), self.string(15))
      }
    case 4:
      guard fields.count == 6, uuid(0), number(1, 1...4294967295), number(2, 1...(version == 1 ? 7 : version >= 5 ? 10 : version >= 4 ? 9 : 8)), text(3), text(4), number(5, -1...100) else {
        throw MacDeskDeckWireError.malformed
      }
      let action = self.number(2), target = self.string(3), revision = self.string(4), value = self.number(5)
      switch action {
      case 1, 5: valid = target.isEmpty && revision.isEmpty && value == -1
      case 3, 4: valid = version == 1 && target.isEmpty && revision.isEmpty && value == -1
      case 2: valid = !target.isEmpty && !revision.isEmpty && (0...1).contains(value)
      case 6: valid = !target.isEmpty && !revision.isEmpty && (0...100).contains(value)
      case 7: valid = version == 1 && !target.isEmpty && !revision.isEmpty && (0...100).contains(value)
      case 8: valid = version >= 2 && uuid(3) && uuid(4) && value == -1
      case 9: valid = version >= 4 && target.isEmpty && revision.isEmpty && value == -1
      case 10: valid = version >= 5 && uuid(3) && uuid(4) && value == -1
      default: valid = false
      }
    case 5: valid = fields.count == 3 && uuid(0) && number(1, 1...4294967295) && number(2, 0...7)
    default: valid = false
    }
    guard valid else { throw MacDeskDeckWireError.malformed }
  }
}
