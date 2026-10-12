// SPDX-License-Identifier: GPL-3.0-or-later
// Encodes transport-independent EDHOC and encrypted-record envelope discriminators.
import Foundation

// The discriminator sits outside EDHOC; payload bytes enter transcript hashing unchanged.
enum SessionEnvelope {
  static func encode(_ kind: UInt8, _ payload: Data, profile: SessionProfile = .standard) throws -> Data {
    guard (1...6).contains(kind), !payload.isEmpty, payload.count < (kind == 6 ? profile.maximumEnvelope : 4096) else {
      throw SessionFailure.malformed
    }
    return Data([kind]) + payload
  }
  static func decode(_ message: Data, profile: SessionProfile = .standard) throws -> (UInt8, Data) {
    guard (2...profile.maximumEnvelope).contains(message.count), let kind = message.first, (1...6).contains(kind)
    else { throw SessionFailure.malformed }
    guard kind == 6 || message.count <= 4096 else { throw SessionFailure.malformed }
    return (kind, Data(message.dropFirst()))
  }
}
