// SPDX-License-Identifier: GPL-3.0-or-later
// Defines private display overrides separately from authenticated identity and pairing evidence.
import Foundation

extension DeviceIdentity {
  @MainActor var displayName: String { PeerNames.shared.displayName(self) }
  @MainActor var knownDeviceName: String { PeerNames.shared.deviceName(self) }
}

struct PeerNickname: Codable, Equatable, Sendable {
  let name: String
  let enabled: Bool

  init(name: String, enabled: Bool) throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.unicodeScalars.count <= 64, !enabled || !trimmed.isEmpty else {
      throw IdentityError.invalidPublicIdentity
    }
    self.name = trimmed
    self.enabled = enabled
  }

  func displayedName(for peer: DeviceIdentity) -> String {
    enabled && !name.isEmpty ? name : peer.deviceName
  }

  static func credential(_ peer: DeviceIdentity) -> String {
    peer.deviceId + ":" + peer.fingerprint + ":" + peer.publicKey
  }
}
