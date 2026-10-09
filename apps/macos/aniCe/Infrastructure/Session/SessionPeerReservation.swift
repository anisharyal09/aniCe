// SPDX-License-Identifier: GPL-3.0-or-later
// Pins simultaneous transport owners to one peer credential and local identity.
import Foundation

@MainActor final class SessionPeerReservation {
  private var owners = Set<String>()
  private(set) var peer: DeviceIdentity?
  private var local: String?
  private func same(_ a: DeviceIdentity, _ b: DeviceIdentity) -> Bool {
    a.deviceId == b.deviceId && a.fingerprint == b.fingerprint && a.publicKey == b.publicKey
  }
  func acquire(_ owner: String, peer candidate: DeviceIdentity?, local fingerprint: String) -> Bool
  {
    if !owners.isEmpty {
      guard local == fingerprint else { return false }
      if let peer, let candidate {
        guard same(peer, candidate) else { return false }
      } else {
        guard peer == nil, candidate == nil, owners.count == 1, owners.contains(owner)
        else { return false }
      }
    }
    owners.insert(owner)
    peer = candidate
    local = fingerprint
    return true
  }
  func authenticate(_ owner: String, peer candidate: DeviceIdentity) -> Bool {
    guard owners.contains(owner) else { return false }
    if let peer, !same(peer, candidate) { return false }
    peer = candidate
    return true
  }
  func release(_ owner: String) {
    guard owners.remove(owner) != nil else { return }
    if owners.isEmpty {
      peer = nil
      local = nil
    }
  }
}
