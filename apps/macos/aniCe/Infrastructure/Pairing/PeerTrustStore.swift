// SPDX-License-Identifier: GPL-3.0-or-later
// Persists verified trust journals and publishes explicit revocation before durable mutations.
import Darwin
import Foundation

/// Persistent record of an authenticated, trusted peer device.
struct PeerTrustRecord: Codable, Identifiable, Sendable {
  var id: String { peer.deviceId }
  let peer: DeviceIdentity
  let localFingerprint: String
  let method: PairingMethod
  let pairedAt: Date
  let transcriptHash: Data
  var receipt: Data?
  var active: Bool
}

/// JSON journal schema version 1.
struct TrustJournal: Codable {
  var version = 1
  var records: [PeerTrustRecord] = []
}

/// Error thrown when the trust file cannot be parsed or verified.
enum TrustStoreLoadError: Error { case corrupt }

/// Thread-safe local storage for trusted peer identities on macOS.
///
/// Features:
/// - Persists JSON journal excluded from Time Machine backups.
/// - Two-phase commit: records are staged as inactive (`active = false`), then
///   activated only after valid peer storage receipts are verified.
/// - Enforces capacity bounds: maximum 128 active peers; allows re-pairing existing peers at capacity.
/// - Defensive recovery: corrupted journals are quarantined rather than silently overwritten.
final class PeerTrustStore: @unchecked Sendable {
  static let invalidated = Notification.Name("aniCe.trust.invalidated")
  private let url: URL
  var location: URL { url.standardizedFileURL }
  private var journal: TrustJournal
  private let lock = NSRecursiveLock()

  /// Initializes the store, creating application directories and loading existing trusted peers.
  init(url: URL? = nil) throws {
    let directory = url?.deletingLastPathComponent() ?? MacAppStorage.directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var excluded = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try excluded.setResourceValues(values)
    self.url = url ?? directory.appendingPathComponent("trusted_peers.json")
    if FileManager.default.fileExists(atPath: self.url.path) {
      let data = try Data(contentsOf: self.url)
      do {
        guard data.count <= 1_048_576 else { throw PairingFailure.storage }
        journal = try JSONDecoder().decode(TrustJournal.self, from: data)
        guard journal.version == 1, journal.records.count <= 129 else {
          throw PairingFailure.storage
        }
        for r in journal.records {
          try r.peer.validate()
          guard r.transcriptHash.count == 32 else { throw PairingFailure.storage }
          if r.active {
            guard let receipt = r.receipt,
              r.peer.verify(
                message: PairingCodec.receipt(r.transcriptHash, r.peer.platform == "macos" ? 2 : 1),
                signature: receipt)
            else { throw PairingFailure.storage }
          }
        }
      } catch { throw TrustStoreLoadError.corrupt }
    } else {
      journal = TrustJournal()
    }
    journal.records.removeAll { !$0.active }
    guard journal.records.count <= 128 else { throw PairingFailure.storage }
    try write()
  }

  /// Recovers from a corrupted trust file by moving the damaged file to a quarantine path.
  static func recover(url: URL? = nil) throws -> PeerTrustStore {
    let target = url ?? MacAppStorage.directory.appendingPathComponent("trusted_peers.json")
    NotificationCenter.default.post(name: Self.invalidated, object: target.standardizedFileURL)
    if FileManager.default.fileExists(atPath: target.path) {
      try FileManager.default.moveItem(
        at: target, to: target.appendingPathExtension("quarantined-" + UUID().uuidString))
    }
    return try PeerTrustStore(url: target)
  }

  /// Lists all active trusted peers associated with the given local identity fingerprint.
  func list(localFingerprint: String) -> [PeerTrustRecord] {
    lock.lock()
    defer { lock.unlock() }
    return journal.records.filter { $0.active && $0.localFingerprint == localFingerprint }
  }

  /// Stages a pending (inactive) peer record before receipt exchange.
  func prepare(_ record: PeerTrustRecord) throws {
    lock.lock()
    defer { lock.unlock() }
    try record.peer.validate()
    let isExisting = journal.records.contains(where: { $0.peer.deviceId == record.peer.deviceId })
    guard !record.active, record.transcriptHash.count == 32, (isExisting || journal.records.count < 128) else {
      throw PairingFailure.storage
    }
    guard
      !journal.records.contains(where: {
        $0.peer.deviceId == record.peer.deviceId && $0.peer.publicKey != record.peer.publicKey
      })
    else { throw PairingFailure.authentication }
    let old = journal
    journal.records.removeAll { !$0.active && $0.peer.deviceId == record.peer.deviceId }
    journal.records.append(record)
    do { try write() } catch {
      journal = old
      throw error
    }
  }

  /// Activates a pending record after verifying the peer's signed storage receipt.
  func activate(peerID: String, hash: Data, receipt: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    guard
      let index = journal.records.firstIndex(where: {
        !$0.active && $0.peer.deviceId == peerID && $0.transcriptHash == hash
      })
    else { throw PairingFailure.storage }
    let peer = journal.records[index].peer
    guard
      peer.verify(
        message: PairingCodec.receipt(hash, peer.platform == "macos" ? 2 : 1), signature: receipt)
    else { throw PairingFailure.authentication }
    let old = journal
    var record = journal.records[index]
    record.active = true
    record.receipt = receipt
    journal.records.removeAll { $0.peer.deviceId == peerID }
    journal.records.append(record)
    do { try write() } catch {
      journal = old
      throw error
    }
  }

  /// Removes a trusted peer by device ID (device forgetting).
  func remove(_ id: String) throws {
    NotificationCenter.default.post(name: Self.invalidated, object: self)
    lock.lock()
    defer { lock.unlock() }
    let old = journal
    journal.records.removeAll { $0.peer.deviceId == id }
    do { try write() } catch {
      journal = old
      throw error
    }
  }

  /// Discards all pending (unactivated) records upon pairing failure or timeout.
  func discardPending() throws {
    lock.lock()
    defer { lock.unlock() }
    let old = journal
    journal.records.removeAll { !$0.active }
    do { try write() } catch {
      journal = old
      throw error
    }
  }

  /// Atomically writes the journal to disk via a temporary file.
  private func write() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(journal)
    let temp = url.appendingPathExtension("tmp-" + UUID().uuidString)
    try payload.write(to: temp, options: .atomic)
    defer { try? FileManager.default.removeItem(at: temp) }
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
  }
}
