// SPDX-License-Identifier: GPL-3.0-or-later
// Encodes transport-independent EDHOC and encrypted-record envelope discriminators.
import Foundation

// The discriminator sits outside EDHOC; payload bytes enter transcript hashing unchanged.
enum SessionEnvelope {
  static func encode(_ kind: UInt8, _ payload: Data) throws -> Data {
    guard (1...6).contains(kind), !payload.isEmpty, payload.count <= 4095 else {
      throw SessionFailure.malformed
    }
    return Data([kind]) + payload
  }
  static func decode(_ message: Data) throws -> (UInt8, Data) {
    guard (2...4096).contains(message.count), let kind = message.first, (1...6).contains(kind)
    else { throw SessionFailure.malformed }
    return (kind, Data(message.dropFirst()))
  }
}
