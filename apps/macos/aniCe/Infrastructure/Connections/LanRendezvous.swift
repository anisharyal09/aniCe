// SPDX-License-Identifier: GPL-3.0-or-later
// Exchanges bounded LAN eligibility and direct locators only over a live authenticated BLE channel.
import Foundation

struct LanDirectEndpoint: Equatable, Sendable {
  let ip: String
  let port: UInt16
  let profile: SessionProfile
  init(ip: String, port: UInt16, profile: SessionProfile) throws {
    guard Self.ipv4(ip) != nil, port > 0, [.standard, .lanTransfer, .lanTransfer512].contains(profile)
    else { throw SessionFailure.malformed }
    self.ip = ip; self.port = port; self.profile = profile
  }
  static func ipv4(_ ip: String) -> [UInt8]? {
    guard (7...15).contains(ip.utf8.count), ip.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 })
    else { return nil }
    let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var octets = [UInt8]()
    for part in parts {
      guard !part.isEmpty, part.count == 1 || part.first != "0", let octet = UInt8(part) else { return nil }
      octets.append(octet)
    }
    guard octets[0] != 0, octets[0] != 127, octets[0] < 224 else { return nil }
    return octets
  }
}

struct LanRendezvousMessage: Equatable, Sendable {
  let version: Int64
  let state: Int64
  var endpoint: LanDirectEndpoint?
}

enum LanRendezvousWire {
  static func encode(_ state: Int64) throws -> Data {
    guard (0...4).contains(state) else { throw SessionFailure.malformed }
    return try SessionCbor.encode(.array([.text("aniCe LAN"), .integer(1), .integer(state)]))
  }
  static func encode(_ message: LanRendezvousMessage) throws -> Data {
    guard (1...2).contains(message.version),
      (0...(message.version == 1 ? 4 : 5)).contains(message.state) else { throw SessionFailure.malformed }
    if message.version == 1 {
      guard message.endpoint == nil else { throw SessionFailure.malformed }
      return try encode(message.state)
    }
    guard message.endpoint == nil || message.state == 2 else { throw SessionFailure.malformed }
    let fields: [SessionCBOR] = message.endpoint.map {
      [.text($0.ip), .integer(Int64($0.port)), .integer(Int64($0.profile.rawValue))]
    } ?? []
    return try SessionCbor.encode(.array([.text("aniCe LAN"), .integer(2), .integer(message.state), .array(fields)]))
  }
  static func decode(_ bytes: Data) throws -> Int64? { try decodeMessage(bytes)?.state }
  static func decodeMessage(_ bytes: Data) throws -> LanRendezvousMessage? {
    if bytes.count > 64, bytes.first.map({ $0 & 0xe0 != 0x80 }) == true { return nil }
    guard case .array(let row) = try SessionCbor.decode(bytes), row.first == .text("aniCe LAN") else { return nil }
    guard bytes.count <= 64 else { throw SessionFailure.malformed }
    guard (3...4).contains(row.count), case .integer(let version) = row[1],
      (1...2).contains(version), row.count == Int(version) + 2, case .integer(let state) = row[2],
      (0...(version == 1 ? 4 : 5)).contains(state) else { throw SessionFailure.malformed }
    var endpoint: LanDirectEndpoint?
    if version == 2 {
      guard case .array(let fields) = row[3], fields.isEmpty || fields.count == 3 && state == 2
      else { throw SessionFailure.malformed }
      if !fields.isEmpty {
        guard case .text(let ip) = fields[0], case .integer(let port) = fields[1],
          (1...65535).contains(port), case .integer(let profile) = fields[2], [1, 3, 4].contains(profile),
          let selected = SessionProfile(rawValue: UInt8(profile)) else { throw SessionFailure.malformed }
        endpoint = try LanDirectEndpoint(ip: ip, port: UInt16(port), profile: selected)
      }
    }
    return LanRendezvousMessage(version: version, state: state, endpoint: endpoint)
  }
}

@MainActor final class LanRendezvous: FeatureHandler {
  private(set) var channel: (any SecuredChannel)?
  private(set) var remote: Int64?
  private(set) var remoteEndpoint: LanDirectEndpoint?
  private var remoteVersion: Int64 = 0
  private var version2 = false
  private var probePending = true
  var changed: () -> Void = {}
  private(set) var requests: Int64 = 0
  var remoteStateChanged: (ChannelDescriptor, Int64?, Int64) -> Void = { _, _, _ in }
  var transferRequested: (ChannelDescriptor) -> Void = { _ in }
  private var requestPending = false
  func request() { requestPending = true; flush() }
  private var transferRequestUntil: TimeInterval?
  private var transferRevision = 0
  private var transferRequestInFlight: Int?
  private let now: () -> TimeInterval
  init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }
  func requestTransfer() {
    guard channel != nil, transferRequestInFlight != transferRevision else { return }
    if transferRequestUntil == nil { transferRequestUntil = now() + 10 }
    flush()
  }
  func cancelTransferRequest() {
    transferRevision += 1; transferRequestUntil = nil
    if transferRequestInFlight != nil {
      generation += 1 // The cancelled sender's eventual defer cannot clear its replacement.
      sending?.cancel(); sending = nil; wake = false
      transferRequestInFlight = nil
    }
  }
  private var local: Int64 = 0
  private var endpoint: LanDirectEndpoint?
  private var sent: LanRendezvousMessage?
  private var sending: Task<Void, Never>?
  private var wake = false
  private var generation = 0
  func update(_ state: Int64, endpoint: LanDirectEndpoint? = nil) {
    precondition((0...3).contains(state) && (endpoint == nil || (1...2).contains(state)))
    local = state; self.endpoint = endpoint; flush()
  }
  private func publication(_ version: Int64? = nil) -> LanRendezvousMessage {
    let selected = version ?? (version2 ? 2 : 1)
    return LanRendezvousMessage(version: selected,
      state: selected == 2 && local == 1 && endpoint != nil ? 2 : local,
      endpoint: selected == 2 ? endpoint : nil)
  }
  func available(_ channel: any SecuredChannel) {
    guard channel.descriptor.transport == "ble" else { return }
    sending?.cancel(); sending = nil; wake = false; generation += 1
    self.channel = channel; remote = nil; remoteEndpoint = nil; remoteVersion = 0
    version2 = false; probePending = true; sent = nil; requestPending = false; transferRequestUntil = nil
    transferRevision += 1; transferRequestInFlight = nil
    changed(); flush()
  }
  func retired(_ descriptor: ChannelDescriptor) {
    guard channel?.descriptor == descriptor else { return }
    generation += 1
    sending?.cancel(); sending = nil; wake = false; channel = nil; remote = nil
    remoteEndpoint = nil; remoteVersion = 0; version2 = false; probePending = true; sent = nil; requestPending = false
    transferRequestUntil = nil
    transferRevision += 1; transferRequestInFlight = nil
    changed()
  }
  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    guard channel?.descriptor == descriptor else { return }
    if sending != nil { wake = true } else { flush() }
  }
  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    guard channel?.descriptor == descriptor else { return .unrecognized }
    do {
      guard let value = try LanRendezvousWire.decodeMessage(bytes) else { return .unrecognized }
      if value.version == 2 { version2 = true }
      if value.state == 4 || value.state == 5 {
        requests += 1
        if value.state == 5 { transferRequested(descriptor) }
      } else if value.version >= remoteVersion {
        let previous = remote
        remoteVersion = value.version; remote = value.state; remoteEndpoint = value.endpoint
        if previous != value.state { remoteStateChanged(descriptor, previous, value.state) }
      }
      changed()
      flush()
      return .handled
    } catch { return .discarded }
  }
  private func flush() {
    if let until = transferRequestUntil, now() >= until { transferRequestUntil = nil }
    guard let target = channel, (probePending || requestPending || transferRequestUntil != nil || sent != publication()), sending == nil else { return }
    let op = generation
    sending = Task { [weak self] in
      guard let self else { return }
      defer {
        if op == self.generation {
          self.transferRequestInFlight = nil
          self.sending = nil
          if self.wake { self.wake = false; self.flush() }
        }
      }
      var requested = false
      var probing = false
      var transferUntil: TimeInterval?
      var transferOp = self.transferRevision
      do {
        while op == self.generation, self.channel === target,
          (self.probePending || self.requestPending || self.transferRequestUntil != nil || self.sent != self.publication()), !Task.isCancelled {
          if let until = self.transferRequestUntil, self.now() >= until { self.transferRequestUntil = nil }
          if !self.probePending, !self.requestPending, self.transferRequestUntil == nil,
            self.sent == self.publication() { break }
          probing = self.probePending
          transferUntil = probing ? nil : self.transferRequestUntil
          let value = probing ? self.publication(2) : transferUntil != nil
            ? LanRendezvousMessage(version: self.version2 ? 2 : 1, state: self.version2 ? 5 : 4)
            : self.requestPending ? LanRendezvousMessage(version: self.version2 ? 2 : 1, state: 4) : self.publication()
          requested = value.state == 4 && transferUntil == nil
          if probing { self.probePending = false }
          if requested { self.requestPending = false }
          if transferUntil != nil {
            transferOp = self.transferRevision
            self.transferRequestUntil = nil; self.requestPending = false; self.transferRequestInFlight = transferOp
          }
          try await target.sendData(LanRendezvousWire.encode(value))
          probing = false
          requested = false
          transferUntil = nil
          self.transferRequestInFlight = nil
          if op == self.generation, self.channel === target, value.state < 4 { self.sent = value }
        }
      // Backpressure refuses admission before sealing, so the request can be retained for a capacity wakeup.
      } catch is SessionBackpressure {
        if op == self.generation {
          self.requestPending = self.requestPending || requested
          self.probePending = self.probePending || probing
          if transferOp == self.transferRevision, let until = transferUntil,
            self.now() < until, self.transferRequestUntil == nil {
            self.transferRequestUntil = until
          }
        }
      } catch { /* Transport failures retire the channel without replaying sealed requests. */ }
    }
  }
}

struct LanAttemptGate {
  private let recoveryLimit: Int
  private var channel: String?
  private var eligible = false
  private var remoteEligible = false
  private var ready = false
  private var requests: Int64 = 0
  private var attempted = false
  private var cancelled = false
  private var activityDemanded = false
  private var recovery: Int
  private var demand = false
  init(recoveryLimit: Int = 3) {
    self.recoveryLimit = recoveryLimit
    self.recovery = recoveryLimit
  }
  mutating func update(channel: String?, eligible: Bool, remoteEligible: Bool, ready: Bool, requests: Int64) {
    let renewed = self.channel != channel || (eligible && !self.eligible) || (remoteEligible && !self.remoteEligible)
    if renewed { activityDemanded = false; recovery = recoveryLimit; cancelled = false }
    if self.requests != requests { cancelled = false }
    if renewed || self.requests != requests || (ready && !self.ready && !cancelled) { attempted = false }
    self.channel = channel; self.eligible = eligible; self.remoteEligible = remoteEligible
    self.ready = ready; self.requests = requests
  }
  mutating func claimActivity() -> Bool {
    guard !cancelled, !activityDemanded else { return false }
    activityDemanded = true
    return true
  }
  /// An explicit request or preference change gets one attempt, even after recovery is exhausted.
  mutating func trigger() { cancelled = false; demand = true; attempted = false }
  mutating func claim(connected: Bool = false) -> Bool {
    if connected || cancelled || attempted { return false }
    if demand {
      demand = false; attempted = true
      if recovery > 0 { recovery -= 1 }
      return true
    }
    guard recovery > 0 else { return false }
    recovery -= 1; attempted = true
    return true
  }
  /// Marks an in-flight attempt without spending another recovery slot.
  mutating func hold() { attempted = true }
  /// Cancel consumes this event, including late readiness, without disabling automation.
  mutating func cancel() { cancelled = true; attempted = true; demand = false; activityDemanded = true }
  /// Releases the event latch after a failed attempt so a bounded retry can run.
  mutating func release() { if !cancelled { attempted = false } }
  mutating func claimRecovery() -> Bool {
    guard !cancelled, !attempted, recovery > 0 else { return false }
    demand = false; recovery -= 1; attempted = true
    return true
  }
  /// App open, wake, pause expiry or a new BLE channel restores the bounded recovery budget.
  mutating func rearm() { cancelled = false; recovery = recoveryLimit; attempted = false; demand = false }
}
