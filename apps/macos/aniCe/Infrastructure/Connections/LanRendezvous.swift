// SPDX-License-Identifier: GPL-3.0-or-later
// Exchanges LAN eligibility only over a live authenticated BLE channel.
import Foundation

enum LanRendezvousWire {
  static func encode(_ state: Int64) throws -> Data {
    guard (0...4).contains(state) else { throw SessionFailure.malformed }
    return try SessionCbor.encode(.array([.text("aniCe LAN"), .integer(1), .integer(state)]))
  }
  static func decode(_ bytes: Data) throws -> Int64? {
    guard bytes.count <= 64 else { return nil }
    guard case .array(let row) = try SessionCbor.decode(bytes), row.first == .text("aniCe LAN") else { return nil }
    guard row.count == 3, row[1] == .integer(1), case .integer(let state) = row[2],
      (0...4).contains(state) else { throw SessionFailure.malformed }
    return state
  }
}

@MainActor final class LanRendezvous: FeatureHandler {
  private(set) var channel: (any SecuredChannel)?
  private(set) var remote: Int64?
  var changed: () -> Void = {}
  private(set) var requests: Int64 = 0
  private var requestPending = false
  func request() { requestPending = true; flush() }
  private var local: Int64 = 0
  private var sent: Int64?
  private var sending: Task<Void, Never>?
  private var wake = false
  private var generation = 0
  func update(_ state: Int64) { local = state; flush() }
  func available(_ channel: any SecuredChannel) {
    guard channel.descriptor.transport == "ble" else { return }
    sending?.cancel(); sending = nil; wake = false; generation += 1
    self.channel = channel; remote = nil; sent = nil; requestPending = false
    changed(); flush()
  }
  func retired(_ descriptor: ChannelDescriptor) {
    guard channel?.descriptor == descriptor else { return }
    generation += 1
    sending?.cancel(); sending = nil; wake = false; channel = nil; remote = nil; sent = nil; requestPending = false
    changed()
  }
  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    guard channel?.descriptor == descriptor else { return }
    if sending != nil { wake = true } else { flush() }
  }
  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    guard channel?.descriptor == descriptor else { return .unrecognized }
    do {
      guard let value = try LanRendezvousWire.decode(bytes) else { return .unrecognized }
      if value == 4 { requests += 1 } else { remote = value }
      changed()
      return .handled
    } catch { return .discarded }
  }
  private func flush() {
    guard let target = channel, (requestPending || sent != local), sending == nil else { return }
    let op = generation
    sending = Task { [weak self] in
      guard let self else { return }
      defer {
        if op == self.generation {
          self.sending = nil
          if self.wake { self.wake = false; self.flush() }
        }
      }
      var requested = false
      do {
        while op == self.generation, self.channel === target, (self.requestPending || self.sent != self.local), !Task.isCancelled {
          let value: Int64 = self.requestPending ? 4 : self.local
          requested = value == 4
          if requested { self.requestPending = false }
          try await target.sendData(LanRendezvousWire.encode(value))
          requested = false
          if op == self.generation, self.channel === target, value != 4 { self.sent = value }
        }
      } catch is SessionBackpressure {
        if op == self.generation { self.requestPending = self.requestPending || requested }
      } catch { /* Transport failures retire the channel without replaying sealed requests. */ }
    }
  }
}

struct LanAttemptGate {
  private var channel: String?
  private var eligible = false
  private var remoteEligible = false
  private var ready = false
  private var requests: Int64 = 0
  private var attempted = false
  private var activityDemanded = false
  mutating func update(channel: String?, eligible: Bool, remoteEligible: Bool, ready: Bool, requests: Int64) {
    if self.channel != channel || (eligible && !self.eligible) || (remoteEligible && !self.remoteEligible) { activityDemanded = false }
    if self.channel != channel || self.requests != requests || (eligible && !self.eligible)
      || (remoteEligible && !self.remoteEligible) || (ready && !self.ready) { attempted = false }
    self.channel = channel; self.eligible = eligible; self.remoteEligible = remoteEligible
    self.ready = ready; self.requests = requests
  }
  mutating func claimActivity() -> Bool {
    guard !activityDemanded else { return false }
    activityDemanded = true
    return true
  }
  mutating func trigger() { attempted = false }
  mutating func claim() -> Bool { if attempted { return false }; attempted = true; return true }
}
