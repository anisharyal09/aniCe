// SPDX-License-Identifier: GPL-3.0-or-later
// Validates bounded audio-sharing envelopes and checked PCM timelines inside authenticated LAN DATA.
import Foundation

enum AudioSharingWireError: Error { case malformed }

struct AudioSharingMessage: Equatable, Sendable {
  let kind: Int64
  let fields: [SessionCBOR]

  static let tag = "aniCe private listening"
  static let maximumMessageBytes = 4000
  static let sampleRate: Int64 = 48000
  static let channels: Int64 = 2
  static let bitDepth: Int64 = 16
  static let framesPerPacket: Int64 = 960
  static let pcmBytes = 3840
  static let maximumSequence = Int64.max / framesPerPacket
  static let maximumQueuedFrames: Int64 = 48000

  func text(_ index: Int) -> String {
    guard case .text(let value) = fields[index] else { preconditionFailure() }
    return value
  }

  func number(_ index: Int) -> Int64 {
    guard case .integer(let value) = fields[index] else { preconditionFailure() }
    return value
  }

  func flag(_ index: Int) -> Bool {
    guard case .bool(let value) = fields[index] else { preconditionFailure() }
    return value
  }

  func bytes(_ index: Int) -> Data {
    guard case .bytes(let value) = fields[index] else { preconditionFailure() }
    return value
  }

  func encode() throws -> Data {
    try validate()
    return try SessionCbor.encode(.array([
      .text(Self.tag), .integer(1), .integer(kind), .array(fields),
    ]), maximumBytes: Self.maximumMessageBytes)
  }

  func validate() throws {
    func require(_ valid: Bool) throws {
      guard valid else { throw AudioSharingWireError.malformed }
    }
    func integer(_ index: Int, _ range: ClosedRange<Int64>) -> Bool {
      guard fields.indices.contains(index), case .integer(let value) = fields[index] else { return false }
      return range.contains(value)
    }
    func uuid(_ index: Int) -> Bool {
      guard fields.indices.contains(index), case .text(let value) = fields[index],
        value.utf8.count == 36, UUID(uuidString: value)?.uuidString.lowercased() == value else { return false }
      return value[value.index(value.startIndex, offsetBy: 14)] == "4" &&
        "89ab".contains(value[value.index(value.startIndex, offsetBy: 19)])
    }
    func format(_ index: Int) -> Bool {
      integer(index, Self.sampleRate...Self.sampleRate) &&
        integer(index + 1, Self.channels...Self.channels) &&
        integer(index + 2, Self.bitDepth...Self.bitDepth) &&
        integer(index + 3, Self.framesPerPacket...Self.framesPerPacket)
    }

    switch kind {
    case 0:
      try require(fields.count == 5 && format(0))
      guard case .bool = fields[4] else { throw AudioSharingWireError.malformed }
    case 1:
      try require(fields.count == 5 && uuid(0) && format(1))
    case 2:
      try require(fields.count == 2 && uuid(0) && integer(1, 0...9))
    case 3:
      try require(fields.count == 4 && uuid(0) && integer(1, 1...Self.maximumSequence) &&
        integer(2, 0...Int64.max))
      try require(number(2) == (number(1) - 1) * Self.framesPerPacket)
      guard case .bytes(let pcm) = fields[3], pcm.count == Self.pcmBytes else {
        throw AudioSharingWireError.malformed
      }
    case 4:
      try require(fields.count == 2 && uuid(0) && integer(1, 0...7))
    case 5:
      try require(fields.count == 7 && uuid(0) && integer(1, 0...1) && integer(2, 0...5) &&
        integer(3, 0...Self.maximumSequence) && integer(4, 0...Int64.max) &&
        integer(5, 0...Self.maximumQueuedFrames) && integer(6, 0...4294967295))
      try require(number(1) != 0 || number(6) == 0)
    default:
      throw AudioSharingWireError.malformed
    }
  }

  static func decode(_ bytes: Data) throws -> Self? {
    // Larger unrelated LAN DATA must not allocate its payload or claim this feature's byte budget.
    let small = bytes.count <= maximumMessageBytes
    guard case .array(let row) = try SessionCbor.decode(bytes,
      maximumBytes: small ? maximumMessageBytes : 524416, materializeBytes: small),
      row.first == .text(tag) else { return nil }
    guard small, row.count == 4, row[1] == .integer(1),
      case .integer(let kind) = row[2], case .array(let fields) = row[3] else {
      throw AudioSharingWireError.malformed
    }
    let message = Self(kind: kind, fields: fields)
    try message.validate()
    return message
  }

  static func capability(enabled: Bool) -> Self {
    Self(kind: 0, fields: [.integer(sampleRate), .integer(channels), .integer(bitDepth),
      .integer(framesPerPacket), .bool(enabled)])
  }

  static func start(streamID: String) -> Self {
    Self(kind: 1, fields: [.text(streamID), .integer(sampleRate), .integer(channels),
      .integer(bitDepth), .integer(framesPerPacket)])
  }

  static func audio(streamID: String, sequence: Int64, pcm: Data) throws -> Self {
    guard (1...maximumSequence).contains(sequence) else { throw AudioSharingWireError.malformed }
    let message = Self(kind: 3, fields: [.text(streamID), .integer(sequence),
      .integer((sequence - 1) * framesPerPacket), .bytes(pcm)])
    try message.validate()
    return message
  }
}
