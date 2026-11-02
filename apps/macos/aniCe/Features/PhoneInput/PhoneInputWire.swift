// SPDX-License-Identifier: GPL-3.0-or-later
// Validates bounded Phone-to-Mac input envelopes inside authenticated DATA.
import Foundation

enum PhoneInputWireError: Error { case malformed }

struct PhoneInputMessage: Equatable, Sendable {
  let kind: Int64
  let fields: [SessionCBOR]

  func text(_ index: Int) -> String {
    if case .text(let value) = fields[index] { return value }
    preconditionFailure()
  }

  func number(_ index: Int) -> Int64 {
    if case .integer(let value) = fields[index] { return value }
    preconditionFailure()
  }

  func flag(_ index: Int) -> Bool {
    if case .bool(let value) = fields[index] { return value }
    preconditionFailure()
  }

  func encode() throws -> Data {
    try validate()
    return try SessionCbor.encode(.array([
      .text(Self.tag), .integer(Self.version), .integer(kind), .array(fields),
    ]))
  }

  private func validate() throws {
    func check(_ value: Bool) throws {
      guard value else { throw PhoneInputWireError.malformed }
    }

    func value(_ index: Int) throws -> SessionCBOR {
      guard fields.indices.contains(index) else { throw PhoneInputWireError.malformed }
      return fields[index]
    }

    func number(_ index: Int) throws -> Int64 {
      guard case .integer(let result) = try value(index) else { throw PhoneInputWireError.malformed }
      return result
    }

    func text(_ index: Int) throws -> String {
      guard case .text(let result) = try value(index) else { throw PhoneInputWireError.malformed }
      return result
    }

    func uuid(_ index: Int) throws {
      let string = try text(index)
      try check(UUID(uuidString: string)?.uuidString.lowercased() == string)
    }

    func sequence(_ index: Int) throws {
      try check((1...Self.maxSequence).contains(try number(index)))
    }

    func sessionSequence() throws {
      try check(fields.count >= 2)
      try uuid(0)
      try sequence(1)
    }

    switch kind {
    case 1:
      try check(fields.count == 2)
      try check((1...Self.maxTextBytes).contains(try number(0)))
      try check((1...Self.supportedEvents).contains(try number(1)))
    case 2:
      try check(fields.count == 1)
      try uuid(0)
    case 3:
      try check(fields.count == 2)
      try uuid(0)
      try check((0...3).contains(try number(1)))
    case 4:
      try check(fields.count == 3)
      try sessionSequence()
      let string = try text(2)
      try check(!string.isEmpty && string.utf8.count <= Self.maxTextBytes)
    case 5:
      try check(fields.count == 5)
      try sessionSequence()
      try check((Self.minKeyUsage...Self.maxKeyUsage).contains(try number(2)))
      try check((0...255).contains(try number(3)))
      guard case .bool = try value(4) else { throw PhoneInputWireError.malformed }
    case 6, 8:
      try check(fields.count == 4)
      try sessionSequence()
      try check((Self.minDelta...Self.maxDelta).contains(try number(2)))
      try check((Self.minDelta...Self.maxDelta).contains(try number(3)))
    case 7:
      try check(fields.count == 4)
      try sessionSequence()
      try check((0...Self.maxButtons).contains(try number(2)))
      try check((0...255).contains(try number(3)))
    case 9, 10:
      try check(fields.count == 2)
      try sessionSequence()
    default:
      throw PhoneInputWireError.malformed
    }
  }

  static func decode(_ data: Data) throws -> Self? {
    guard data.count <= 4000 else { return nil }
    guard case .array(let row) = try SessionCbor.decode(data),
      row.first == .text(tag) else { return nil }
    guard row.count == 4, row[1] == .integer(version),
      case .integer(let kind) = row[2], case .array(let fields) = row[3] else {
      throw PhoneInputWireError.malformed
    }
    let message = Self(kind: kind, fields: fields)
    try message.validate()
    guard try message.encode() == data else { throw PhoneInputWireError.malformed }
    return message
  }

  static func of(_ kind: Int64, _ fields: SessionCBOR...) -> Self {
    Self(kind: kind, fields: fields)
  }

  private static let tag = "aniCe phone input"
  private static let version: Int64 = 1
  private static let maxTextBytes: Int64 = 1024
  private static let supportedEvents: Int64 = 7
  private static let maxSequence: Int64 = 4294967295
  private static let minKeyUsage: Int64 = 4
  private static let maxKeyUsage: Int64 = 231
  private static let minDelta: Int64 = -32767
  private static let maxDelta: Int64 = 32767
  private static let maxButtons: Int64 = 7
}
