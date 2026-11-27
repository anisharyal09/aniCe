// SPDX-License-Identifier: GPL-3.0-or-later
// Separates reverse PCM from Mac-to-phone listening without changing its original wire bytes.
import Foundation

struct PhoneAudioMessage: Equatable, Sendable {
  static let tag = "aniCe phone audio"
  let kind: Int64
  let fields: [SessionCBOR]
  var payload: AudioSharingMessage { AudioSharingMessage(kind: kind, fields: fields) }

  private func validate() throws {
    guard (0...4).contains(kind) else { throw AudioSharingWireError.malformed }
    try payload.validate()
  }
  func encode() throws -> Data {
    try validate()
    return try SessionCbor.encode(.array([.text(Self.tag), .integer(1), .integer(kind),
      .array(fields)]), maximumBytes: 4000)
  }
  static func decode(_ bytes: Data) throws -> Self? {
    let small = bytes.count <= 4000
    guard case .array(let row) = try SessionCbor.decode(bytes,
      maximumBytes: small ? 4000 : 524416, materializeBytes: small),
      row.first == .text(tag) else { return nil }
    guard small, row.count == 4, row[1] == .integer(1),
      case .integer(let kind) = row[2], case .array(let fields) = row[3] else {
      throw AudioSharingWireError.malformed
    }
    let result = Self(kind: kind, fields: fields)
    try result.validate()
    return result
  }
}
