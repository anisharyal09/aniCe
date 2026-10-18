// SPDX-License-Identifier: GPL-3.0-or-later
// Persists opt-in bounded clipboard history through serialized private-file operations.
import Foundation
import Observation

struct ClipboardHistoryEntry: Codable, Identifiable, Sendable, Equatable {
  let id: String
  let text: String
  let origin: String
  let timestamp: Date
  let credential: String?
}
protocol ClipboardHistoryStorage: Sendable {
  func load() throws -> [ClipboardHistoryEntry]?
  func save(_ entries: [ClipboardHistoryEntry]) throws
  func delete() throws
}
struct ClipboardHistoryFile: ClipboardHistoryStorage {
  let url: URL
  private struct Envelope: Codable { let version: Int; let entries: [ClipboardHistoryEntry] }
  private func clearTemporary() throws {
    let directory = url.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      where item.lastPathComponent.hasPrefix(".clipboard-") && UUID(uuidString: String(item.lastPathComponent.dropFirst(11))) != nil {
      try FileManager.default.removeItem(at: item)
    }
  }
  func load() throws -> [ClipboardHistoryEntry]? {
    try clearTemporary()
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    let data = try handle.read(upToCount: 8_000_001) ?? Data()
    guard data.count <= 8_000_000 else { throw CocoaError(.fileReadCorruptFile) }
    let saved = try JSONDecoder().decode(Envelope.self, from: data)
    guard saved.version == 1, saved.entries.count <= 20, Set(saved.entries.map(\.id)).count == saved.entries.count,
      saved.entries.allSatisfy({ UUID(uuidString: $0.id)?.uuidString.lowercased() == $0.id && Self.valid($0.text) && ["mac", "phone"].contains($0.origin) && $0.timestamp.timeIntervalSince1970 >= 0 && ($0.credential?.utf8.count ?? 0) <= 512 }) else { throw CocoaError(.fileReadCorruptFile) }
    return saved.entries
  }
  static func valid(_ text: String) -> Bool { !text.isEmpty && !text.contains("\0") && text.utf8.count <= 65536 }
  func save(_ entries: [ClipboardHistoryEntry]) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temporary = directory.appendingPathComponent(".clipboard-\(UUID().uuidString)")
    do {
      let data = try JSONEncoder().encode(Envelope(version: 1, entries: entries))
      guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
      let handle = try FileHandle(forWritingTo: temporary)
      do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
      catch { try? handle.close(); throw error }
      var resource = temporary; var values = URLResourceValues(); values.isExcludedFromBackup = true; try resource.setResourceValues(values)
      if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
      else { try FileManager.default.moveItem(at: temporary, to: url) }
    } catch {
      if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
      throw error
    }
  }
  func delete() throws { try clearTemporary(); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}
@MainActor @Observable final class ClipboardHistory {
  private let storage: (any ClipboardHistoryStorage)?
  private var tail: Task<Void, Never>?
  private(set) var enabled = false
  private(set) var entries: [ClipboardHistoryEntry] = []
  private(set) var error: String?
  private var captures: [(ClipboardSample, String, String?)] = []
  private var recording = false
  private var preferenceRevision = 0
  var onChanged: () -> Void = {}
  // A delayed startup read must not overwrite a newer consent or identity-reset request.
  init(storage: (any ClipboardHistoryStorage)? = nil) {
    self.storage = storage
    command {
      let rows = try await Task.detached { try storage?.load() }.value
      if self.preferenceRevision == 0 { self.enabled = rows != nil; self.entries = rows ?? [] }; self.onChanged()
    }
  }
  private func command(_ block: @escaping @MainActor () async throws -> Void) {
    let previous = tail
    tail = Task { await previous?.value
      do { try await block(); error = nil }
      catch { self.error = "Could not update clipboard history. Clear history or try again." }
    }
  }
  func setEnabled(_ value: Bool) {
    error = nil
    preferenceRevision += 1; let revision = preferenceRevision
    if !value { enabled = false; captures = []; onChanged() }
    command {
      let rows = self.entries, storage = self.storage
      try await Task.detached { if value { try storage?.save(rows) } else { try storage?.delete() } }.value
      if revision == self.preferenceRevision { self.enabled = value }; if !value { self.entries = [] }; self.onChanged()
    }
  }
  func record(_ sample: ClipboardSample, origin: String, credential: String? = nil) {
    guard enabled, !sample.sensitive, !sample.excluded, ClipboardHistoryFile.valid(sample.text) else { return }
    // Bound pending content independently of the saved inventory while disk IO is stalled.
    if captures.count == 20 { captures.removeFirst() }
    captures.append((sample, origin, credential))
    guard !recording else { return }; recording = true
    command {
      defer { self.recording = false; self.captures = [] }
      while self.enabled, !self.captures.isEmpty {
        let (sample, origin, credential) = self.captures.removeFirst()
        let first = self.entries.first
        let row = ClipboardHistoryEntry(id: first?.text == sample.text && first?.origin == origin ? first!.id : UUID().uuidString.lowercased(), text: sample.text, origin: origin, timestamp: Date(), credential: credential)
        let rows = Array(([row] + self.entries.filter { $0.id != row.id }).prefix(20)), storage = self.storage
        try await Task.detached { try storage?.save(rows) }.value; if self.enabled { self.entries = rows }
      }
    }
  }

  func delete(_ id: String) { replace { $0.filter { $0.id != id } } }
  func clear() { command {
    let storage = self.storage, enabled = self.enabled
    try await Task.detached { if enabled { try storage?.save([]) } else { try storage?.delete() } }.value
    self.entries = []
  } }
  func reset() { entries = []; setEnabled(false) }
  func prune(_ credentials: Set<String>) { replace { $0.filter { $0.credential == nil || credentials.contains($0.credential!) } } }
  private func replace(_ transform: @escaping ([ClipboardHistoryEntry]) -> [ClipboardHistoryEntry]) { command {
    let rows = transform(self.entries), storage = self.storage, enabled = self.enabled
    guard rows != self.entries else { return }
    try await Task.detached { if enabled { try storage?.save(rows) } else { try storage?.delete() } }.value
    if self.enabled { self.entries = rows } else if !enabled { self.entries = [] }
  } }
}
