// SPDX-License-Identifier: GPL-3.0-or-later
// Validates bounded notification mirroring records inside authenticated application DATA.
import Foundation

enum NotificationWireError: Error { case malformed }

struct NotificationWireMessage: Equatable, Sendable {
  static let tag = "aniCe notifications"
  static let version: Int64 = 1
  static let maxActions: Int64 = 8
  static let maxSequence: Int64 = 9_007_199_254_740_991
  let kind: Int64
  let fields: [SessionCBOR]

  func text(_ index: Int) throws -> String {
    guard case .text(let value) = fields[index] else { throw NotificationWireError.malformed }
    return value
  }
  func number(_ index: Int) throws -> Int64 {
    guard case .integer(let value) = fields[index] else { throw NotificationWireError.malformed }
    return value
  }
  func actionRows(_ index: Int) throws -> [(Int, String, String)] {
    guard case .array(let rows) = fields[index] else { throw NotificationWireError.malformed }
    return try rows.map { row in
      guard case .array(let cells) = row, cells.count == 3,
            case .integer(let index) = cells[0], case .text(let title) = cells[1],
            case .text(let reply) = cells[2] else { throw NotificationWireError.malformed }
      return (Int(index), title, reply)
    }
  }
  func encode() throws -> Data {
    try validate()
    return try SessionCbor.encode(.array([.text(Self.tag), .integer(Self.version), .integer(kind), .array(fields)]), maximumBytes: 4000)
  }
  private func validate() throws {
    func check(_ value: Bool) throws { if !value { throw NotificationWireError.malformed } }
    func string(_ index: Int, _ maximum: Int, allowEmpty: Bool = true) throws {
      let value = try text(index)
      try check((allowEmpty || !value.isEmpty) && value.utf8.count <= maximum)
    }
    func uuid(_ index: Int) throws {
      let value = try text(index)
      try check(value.utf8.count == 36 && UUID(uuidString: value)?.uuidString.lowercased() == value)
    }
    func identifier(_ index: Int) throws {
      let value = try text(index)
      try check(value.utf8.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) })
    }
    func sequence(_ index: Int) throws { try check((1...Self.maxSequence).contains(try number(index))) }
    switch kind {
    case 1:
      try check(fields.count == 1 && number(0) == Self.maxActions)
    case 2:
      try check(fields.count == 9); try string(0, 36)
      let snapshotToken = try text(0)
      if !snapshotToken.isEmpty { try uuid(0) }
      try identifier(1); try uuid(2); try sequence(3)
      try string(4, 255, allowEmpty: false); try string(5, 128, allowEmpty: false)
      try string(6, 512); try string(7, 1024)
      guard case .array(let rows) = fields[8], rows.count <= Int(Self.maxActions) else { throw NotificationWireError.malformed }
      var indices = Set<Int64>()
      for row in rows {
        guard case .array(let cells) = row, cells.count == 3,
              case .integer(let index) = cells[0], (0..<Self.maxActions).contains(index), indices.insert(index).inserted,
              case .text(let title) = cells[1], (1...48).contains(title.utf8.count),
              case .text(let reply) = cells[2], reply.utf8.count <= 48 else { throw NotificationWireError.malformed }
      }
    case 3:
      try check(fields.count == 3); try identifier(0); try uuid(1); try sequence(2)
    case 4:
      try check(fields.count == 3); try uuid(0); try uuid(1); try check((0...Self.maxSequence).contains(try number(2)))
    case 5:
      try check(fields.count == 1); try uuid(0)
    case 6:
      try check(fields.count == 6); try uuid(0); try identifier(1); try uuid(2); try sequence(3)
      try check((-1..<Self.maxActions).contains(try number(4))); try string(5, 1024)
      if try number(4) == -1 { try check(try text(5).isEmpty) }
    case 7:
      try check(fields.count == 2); try uuid(0); try check((0...3).contains(try number(1)))
    case 8:
      try check(fields.count == 4); try uuid(0); try identifier(1); try uuid(2); try sequence(3)
    default: throw NotificationWireError.malformed
    }
  }
  static func decode(_ bytes: Data) throws -> Self? {
    guard bytes.count <= 4000 else { return nil }
    guard case .array(let row) = try SessionCbor.decode(bytes), row.first == .text(tag) else { return nil }
    guard row.count == 4, row[1] == .integer(version), case .integer(let kind) = row[2], case .array(let fields) = row[3] else {
      throw NotificationWireError.malformed
    }
    let message = Self(kind: kind, fields: fields)
    try message.validate()
    guard try message.encode() == bytes else { throw NotificationWireError.malformed }
    return message
  }
}

func notificationText(_ value: String, maxBytes: Int) -> String {
  var result = ""
  var count = 0
  for scalar in value.unicodeScalars {
    let size = String(scalar).utf8.count
    if count + size > maxBytes { break }
    result.unicodeScalars.append(scalar)
    count += size
  }
  return result
}
