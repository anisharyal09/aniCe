// SPDX-License-Identifier: GPL-3.0-or-later
// Exchanges display-only name snapshots and persists private aliases separately from trust evidence.
import Foundation
import Observation

struct NameReport: Codable, Equatable, Sendable {
  let revision: Int64
  let name: String
}
enum NameWire {
  static let tag = "aniCe device names"
  static func valid(_ name: String) -> Bool {
    !name.isEmpty && name == name.trimmingCharacters(in: .whitespacesAndNewlines) &&
      name.unicodeScalars.count <= 64 && name.utf8.count <= 256
  }
  static func encode(_ report: NameReport? = nil) throws -> Data {
    if let report, report.revision < 0 || !valid(report.name) { throw SessionFailure.malformed }
    return try SessionCbor.encode(.array([.text(tag), .integer(1), .integer(report == nil ? 1 : 2),
      .array(report.map { [.integer($0.revision), .text($0.name)] } ?? [.integer(1)])]), maximumBytes: 512)
  }
  static func decode(_ bytes: Data) throws -> (Bool, NameReport?)? {
    guard bytes.count <= 512, case .array(let row) = try SessionCbor.decode(bytes),
      row.first == .text(tag) else { return nil }
    guard row.count == 4, row[1] == .integer(1), case .array(let fields) = row[3] else {
      throw SessionFailure.malformed
    }
    if row[2] == .integer(1) {
      guard fields == [.integer(1)] else { throw SessionFailure.malformed }
      return (true, nil)
    }
    guard row[2] == .integer(2), fields.count == 2, case .integer(let revision) = fields[0],
      case .text(let name) = fields[1], revision >= 0, valid(name) else { throw SessionFailure.malformed }
    return (false, NameReport(revision: revision, name: name))
  }
}
struct PeerNameEntry: Codable, Sendable {
  var report: NameReport?
  var nickname: PeerNickname?
}
struct NamesState: Codable, Sendable {
  var local: String
  var report: NameReport
  var peers: [String: PeerNameEntry] = [:]
}
private actor NamesJournal {
  let url: URL
  let read: @Sendable () throws -> Data?
  let write: @Sendable (Data) throws -> Void
  init(url: URL, read: (@Sendable () throws -> Data?)? = nil,
    write: (@Sendable (Data) throws -> Void)? = nil) {
    self.url = url
    self.read = read ?? {
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      return try Data(contentsOf: url)
    }
    self.write = write ?? { data in
      var directory = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try directory.setResourceValues(values)
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
  }
  func update(identity: IdentityService, store: PeerTrustStore, peer: String? = nil,
    report: NameReport? = nil, nickname: PeerNickname? = nil,
    valid: @Sendable () -> Bool) async throws -> NamesState {
    let local = try await identity.publicIdentity()
    guard valid() else { throw SessionFailure.cancelled }
    let keep = Set(store.list(localFingerprint: local.fingerprint).map { PeerNickname.credential($0.peer) })
    var state: NamesState
    let original = try read()
    if let data = original {
      guard data.count <= 1_048_576 else { throw SessionFailure.malformed }
      state = try JSONDecoder().decode(NamesState.self, from: data)
    } else { state = NamesState(local: local.fingerprint, report: NameReport(revision: 0, name: local.deviceName)) }
    if state.local != local.fingerprint {
      state = NamesState(local: local.fingerprint, report: NameReport(revision: 0, name: local.deviceName))
    }
    guard state.report.revision >= 0, NameWire.valid(state.report.name) else { throw SessionFailure.malformed }
    for entry in state.peers.values {
      if let report = entry.report {
        guard report.revision >= 0, NameWire.valid(report.name) else { throw SessionFailure.malformed }
      }
      if let nickname = entry.nickname {
        guard try PeerNickname(name: nickname.name, enabled: nickname.enabled) == nickname else {
          throw SessionFailure.malformed
        }
      }
    }
    if state.report.name != local.deviceName {
      guard state.report.revision < Int64.max else { throw SessionFailure.state }
      state.report = NameReport(revision: state.report.revision + 1, name: local.deviceName)
    }
    state.peers = state.peers.filter { keep.contains($0.key) }
    if let peer {
      guard keep.contains(peer) else { throw SessionFailure.untrustedPeer }
      var entry = state.peers[peer] ?? PeerNameEntry()
      if let report {
        guard report.revision >= 0, NameWire.valid(report.name) else { throw SessionFailure.malformed }
        if let previous = entry.report {
          guard report.revision > previous.revision || report == previous else { throw SessionFailure.state }
        }
        entry.report = report
      }
      if let nickname { entry.nickname = nickname.name.isEmpty ? nil : nickname }
      state.peers[peer] = entry
    }
    let data = try JSONEncoder().encode(state)
    guard data.count <= 1_048_576 else { throw SessionFailure.malformed }
    guard valid() else { throw SessionFailure.cancelled }
    if original != data {
      let current = try await identity.publicIdentity()
      guard current == local, valid(),
        Set(store.list(localFingerprint: local.fingerprint).map { PeerNickname.credential($0.peer) }) == keep,
        try read() == original
      else { throw SessionFailure.cancelled }
      try write(data)
    }
    return state
  }
}

@Observable @MainActor final class PeerNames: FeatureHandler {
  static let shared = PeerNames()
  private var entries: [String: PeerNameEntry] = [:]
  private(set) var failed = false
  private var identity: IdentityService?
  private var trust: (() async throws -> PeerTrustStore)?
  private let journal: NamesJournal
  private var generation = 0
  private var lease = PairingAttemptLease()
  private var refreshing = false
  private var refreshAgain = false
  private final class Link {
    let lease = PairingAttemptLease()
    let channel: any SecuredChannel
    var capability = false
    var remote = false
    var sending = false
    var pending: NameReport?
    init(_ channel: any SecuredChannel) { self.channel = channel }
  }
  private var links: [String: Link] = [:]
  init(url: URL = MacAppStorage.directory.appendingPathComponent("peer_names.json"),
    read: (@Sendable () throws -> Data?)? = nil, write: (@Sendable (Data) throws -> Void)? = nil) {
    journal = NamesJournal(url: url, read: read, write: write)
  }
  func configure(identity: IdentityService, trust: @escaping () async throws -> PeerTrustStore) {
    self.identity = identity
    self.trust = trust
    refresh()
  }
  func deviceName(_ peer: DeviceIdentity) -> String {
    entries[PeerNickname.credential(peer)]?.report?.name ?? peer.deviceName
  }
  func displayName(_ peer: DeviceIdentity) -> String {
    entries[PeerNickname.credential(peer)]?.nickname.flatMap { $0.enabled ? $0.name : nil } ?? deviceName(peer)
  }
  func nickname(_ peer: DeviceIdentity) -> PeerNickname? { entries[PeerNickname.credential(peer)]?.nickname }
  func displayName(deviceId: String, fingerprint: String, fallback: String) -> String {
    let prefix = deviceId + ":" + fingerprint + ":"
    guard let entry = entries.first(where: { $0.key.hasPrefix(prefix) })?.value else { return fallback }
    return entry.nickname.flatMap { $0.enabled ? $0.name : nil } ?? entry.report?.name ?? fallback
  }
  private func update(peer: DeviceIdentity? = nil, report: NameReport? = nil,
    nickname: PeerNickname? = nil, linkLease: PairingAttemptLease? = nil) async throws -> NameReport {
    guard let identity, let trust else { throw SessionFailure.state }
    let op = generation
    let lease = self.lease
    let store = try await trust()
    guard op == generation else { throw SessionFailure.cancelled }
    let state = try await journal.update(identity: identity, store: store,
      peer: peer.map(PeerNickname.credential), report: report, nickname: nickname,
      valid: { lease.active && (linkLease?.active ?? true) })
    guard op == generation else { throw SessionFailure.cancelled }
    entries = state.peers
    failed = false
    return state.report
  }
  func refresh() {
    refreshAgain = true
    guard !refreshing else { return }
    refreshing = true
    Task {
      defer { refreshing = false }
      while refreshAgain {
        refreshAgain = false
        do {
          let report = try await update()
          for link in links.values { link.pending = report; flush(link) }
        } catch { failed = true }
      }
    }
  }
  func invalidate() {
    generation += 1
    lease.cancel()
    lease = PairingAttemptLease()
    for link in links.values { link.lease.cancel() }
    links = [:]
    entries = [:]
    refresh()
  }
  func saveNickname(peer: DeviceIdentity, name: String, enabled: Bool) async throws {
    _ = try await update(peer: peer, nickname: PeerNickname(name: name, enabled: enabled))
  }
  func available(_ channel: any SecuredChannel) {
    links[channel.descriptor.transport]?.lease.cancel()
    links[channel.descriptor.transport] = Link(channel)
    refresh()
  }
  func retired(_ descriptor: ChannelDescriptor) {
    if links[descriptor.transport]?.channel.descriptor.instance == descriptor.instance {
      links.removeValue(forKey: descriptor.transport)?.lease.cancel()
    }
  }
  func capacityAvailable(_ descriptor: ChannelDescriptor) {
    if let link = links[descriptor.transport], link.channel.descriptor.instance == descriptor.instance { flush(link) }
  }
  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    guard let link = links[descriptor.transport], link.channel.descriptor.instance == descriptor.instance else { return .discarded }
    do {
      guard let message = try NameWire.decode(bytes) else { return .unrecognized }
      if message.0 { link.remote = true; flush(link); return .handled }
      guard link.remote, let report = message.1 else { return .discarded }
      _ = try await update(peer: descriptor.peer, report: report, linkLease: link.lease)
      guard links[descriptor.transport] === link else { return .discarded }
      return .handled
    } catch { return .discarded }
  }
  private func flush(_ link: Link) {
    guard !link.sending, links[link.channel.descriptor.transport] === link else { return }
    link.sending = true
    Task {
      defer { link.sending = false }
      while links[link.channel.descriptor.transport] === link {
        let capability = !link.capability
        let report = capability ? nil : (link.remote ? link.pending : nil)
        if !capability && report == nil { break }
        do { try await link.channel.sendData(NameWire.encode(report)) } catch { break }
        if capability { link.capability = true }
        else if link.pending == report { link.pending = nil }
      }
    }
  }
  func awaitRefresh() async throws { _ = try await update() }
}
