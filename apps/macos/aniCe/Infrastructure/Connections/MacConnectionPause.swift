// SPDX-License-Identifier: GPL-3.0-or-later
// Mirrors a phone's pause state on Mac device surfaces without changing local automatic policy.
import Foundation
import Observation

struct MacConnectionPauseMessage: Equatable {
  static let tag = "aniCe connection pause"
  static let maximumUntilMillis: Int64 = 253402300799999
  let kind: Int64
  let until: Int64

  func encode() throws -> Data {
    guard kind == 1 || kind == 2, (0...Self.maximumUntilMillis).contains(until),
      kind == 1 || until == 0 else {
      throw SessionFailure.malformed
    }
    let data = try SessionCbor.encode(.array([
      .text(Self.tag), .integer(1), .integer(kind), .array([.integer(until)])
    ]), maximumBytes: 128)
    guard try Self.decode(data)?.kind == kind else { throw SessionFailure.malformed }
    return data
  }

  static func decode(_ data: Data) throws -> Self? {
    guard data.count <= 128 else { return nil }
    guard case .array(let row) = try SessionCbor.decode(data, maximumBytes: 128),
      row.first == .text(Self.tag) else { return nil }
    guard row.count == 4, row[1] == .integer(1), case .integer(let kind) = row[2],
      case .array(let fields) = row[3], fields.count == 1, case .integer(let until) = fields[0],
      (kind == 1 || kind == 2), (0...maximumUntilMillis).contains(until),
      kind == 1 || until == 0 else {
      throw SessionFailure.malformed
    }
    return Self(kind: kind, until: until)
  }
}

@Observable @MainActor final class MacConnectionPauseModel: FeatureHandler {
  private struct PeerPause {
    let peer: DeviceIdentity
    let until: Date?
  }

  private var links: [String: any SecuredChannel] = [:]
  private var peers: [String: PeerPause] = [:]
  @ObservationIgnored private var expiry: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private let now: () -> Date
  init(now: @escaping () -> Date = Date.init) { self.now = now }

  func status(for peer: DeviceIdentity) -> String? {
    guard let pause = peers[peer.fingerprint] else { return nil }
    guard pause.peer.deviceId == peer.deviceId, pause.peer.publicKey == peer.publicKey else { return nil }
    if let until = pause.until, until <= now() { return nil }
    if let until = pause.until {
      return "Paused on \(pause.peer.deviceName) until \(until.formatted(date: .omitted, time: .shortened))"
    }
    return "Paused on \(pause.peer.deviceName)"
  }

  /** A local Resume or explicit Connect supersedes a mirrored deadline immediately. */
  func clear() {
    for fingerprint in Array(peers.keys) { clear(fingerprint) }
  }

  func reconcileTime() {
    for (fingerprint, pause) in peers where pause.until.map({ $0 <= now() }) == true {
      clear(fingerprint)
    }
  }

  func available(_ channel: any SecuredChannel) {
    links[channel.descriptor.transport] = channel
    // A fresh authenticated channel is the authoritative replacement for an older pause notice.
    clear(channel.descriptor.peer.fingerprint)
  }

  func retired(_ descriptor: ChannelDescriptor) {
    guard links[descriptor.transport]?.descriptor == descriptor else { return }
    links.removeValue(forKey: descriptor.transport)
  }

  func capacityAvailable(_ descriptor: ChannelDescriptor) {}

  func handle(_ bytes: Data, on descriptor: ChannelDescriptor) async -> DataHandling {
    guard links[descriptor.transport]?.descriptor == descriptor else { return .discarded }
    let message: MacConnectionPauseMessage
    do {
      guard let decoded = try MacConnectionPauseMessage.decode(bytes) else { return .unrecognized }
      message = decoded
    } catch { return .discarded }
    if message.kind == 1 { apply(descriptor.peer, until: message.until) }
    else { clear(descriptor.peer.fingerprint) }
    return .handled
  }

  func announcePause(until: Date?) async {
    let value = until.map { ($0.timeIntervalSince1970 * 1000).rounded() } ?? 0
    guard value.isFinite, value >= 0, value <= Double(MacConnectionPauseMessage.maximumUntilMillis) else { return }
    let milliseconds = Int64(value)
    guard let bytes = try? MacConnectionPauseMessage(kind: 1, until: milliseconds).encode() else { return }
    await announce(bytes)
  }

  func announceResume() async {
    guard let bytes = try? MacConnectionPauseMessage(kind: 2, until: 0).encode() else { return }
    await announce(bytes)
  }

  private func announce(_ bytes: Data) async {
    for channel in links.values.sorted(by: { $0.descriptor.transport == "lan" && $1.descriptor.transport != "lan" }) {
      guard !Task.isCancelled else { return }
      let sent = await withTaskGroup(of: Bool.self) { group in
        group.addTask { [channel, bytes] in
          guard !Task.isCancelled else { return false }
          do { try await channel.sendData(bytes); return true } catch { return false }
        }
        group.addTask {
          try? await Task.sleep(for: .milliseconds(800))
          return false
        }
        let completed = await group.next() ?? false
        group.cancelAll()
        return completed
      }
      if sent || Task.isCancelled { return }
    }
  }

  private func apply(_ peer: DeviceIdentity, until: Int64) {
    let deadline = until > 0 ? Date(timeIntervalSince1970: Double(until) / 1000) : nil
    if let deadline, deadline <= now() {
      clear(peer.fingerprint)
      return
    }
    if peers[peer.fingerprint] == nil, peers.count == 16, let oldest = peers.keys.sorted().first {
      clear(oldest)
    }
    peers[peer.fingerprint] = PeerPause(peer: peer, until: deadline)
    expiry.removeValue(forKey: peer.fingerprint)?.cancel()
    guard let deadline else { return }
    expiry[peer.fingerprint] = Task { [weak self] in
      while let self, !Task.isCancelled, self.peers[peer.fingerprint]?.until == deadline {
        do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSince(self.now())))) }
        catch { return }
        guard !Task.isCancelled else { return }
        if deadline <= self.now() { self.clear(peer.fingerprint); return }
      }
    }
  }

  private func clear(_ fingerprint: String) {
    peers.removeValue(forKey: fingerprint)
    expiry.removeValue(forKey: fingerprint)?.cancel()
  }
}
