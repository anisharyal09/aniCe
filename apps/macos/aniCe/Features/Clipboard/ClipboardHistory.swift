// SPDX-License-Identifier: GPL-3.0-or-later
// Persists opt-in bounded clipboard history through serialized private-file operations.
import Foundation
import Observation

/// Represents a single bounded clipboard text entry with origin metadata and optional pinned status.
struct ClipboardHistoryEntry: Codable, Identifiable, Sendable, Equatable {
  let id: String
  let text: String
  let origin: String
  let timestamp: Date
  let credential: String?
  var pinned: Bool

  init(id: String, text: String, origin: String, timestamp: Date, credential: String?, pinned: Bool = false) {
    self.id = id
    self.text = text
    self.origin = origin
    self.timestamp = timestamp
    self.credential = credential
    self.pinned = pinned
  }

  enum CodingKeys: String, CodingKey {
    case id, text, origin, timestamp, credential, pinned
  }

  // Backward compatibility: files saved before pinning default pinned to false.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    text = try container.decode(String.self, forKey: .text)
    origin = try container.decode(String.self, forKey: .origin)
    timestamp = try container.decode(Date.self, forKey: .timestamp)
    credential = try container.decodeIfPresent(String.self, forKey: .credential)
    pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
  }

  // Compact encoding: omit pinned key when false to preserve legacy envelope shape.
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(text, forKey: .text)
    try container.encode(origin, forKey: .origin)
    try container.encode(timestamp, forKey: .timestamp)
    try container.encodeIfPresent(credential, forKey: .credential)
    if pinned {
      try container.encode(pinned, forKey: .pinned)
    }
  }

  /// Fast-path detection for http/https links without network fetching or URI resolution.
  var isUrl: Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return false }
    return URL(string: trimmed)?.scheme != nil
  }

  /// Validates CSS hex color syntax (#RGB, #RGBA, #RRGGBB, #RRGGBBAA) for swatch rendering.
  var hexColorValue: String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("#") else { return nil }
    let hex = String(trimmed.dropFirst())
    guard [3, 4, 6, 8].contains(hex.count),
      hex.allSatisfy({ $0.isHexDigit }) else { return nil }
    return trimmed
  }
}
struct ClipboardHistoryState: Sendable {
  let entries: [ClipboardHistoryEntry]
  var enabled = true
  var capacity: Int? = nil
}
protocol ClipboardHistoryStorage: Sendable {
  func load() throws -> ClipboardHistoryState?
  func save(_ entries: [ClipboardHistoryEntry], enabled: Bool, capacity: Int) throws
  func delete() throws
}
/// Serializes history entries to private application support directory excluded from backup.
struct ClipboardHistoryFile: ClipboardHistoryStorage {
  let url: URL
  private struct Envelope: Codable { let version: Int; let entries: [ClipboardHistoryEntry]; let enabled: Bool?; let capacity: Int? }
  private func clearTemporary() throws {
    let directory = url.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      where item.lastPathComponent.hasPrefix(".clipboard-") && UUID(uuidString: String(item.lastPathComponent.dropFirst(11))) != nil {
      try FileManager.default.removeItem(at: item)
    }
  }
  func load() throws -> ClipboardHistoryState? {
    try clearTemporary()
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    let data = try handle.read(upToCount: 8_000_001) ?? Data()
    guard data.count <= 8_000_000 else { throw CocoaError(.fileReadCorruptFile) }
    let saved = try JSONDecoder().decode(Envelope.self, from: data)
    // Enforce version 1 schema and upper envelope limit of 100 entries.
    guard saved.version == 1, saved.entries.count <= 100, Set(saved.entries.map(\.id)).count == saved.entries.count,
      saved.entries.allSatisfy({ UUID(uuidString: $0.id)?.uuidString.lowercased() == $0.id && Self.valid($0.text) && ["mac", "phone"].contains($0.origin) && $0.timestamp.timeIntervalSince1970 >= 0 && ($0.credential?.utf8.count ?? 0) <= 512 }) else { throw CocoaError(.fileReadCorruptFile) }
    guard saved.capacity == nil || [20, 50, 100].contains(saved.capacity!) else { throw CocoaError(.fileReadCorruptFile) }
    return ClipboardHistoryState(entries: saved.entries, enabled: saved.enabled ?? true, capacity: saved.capacity)
  }
  static func valid(_ text: String) -> Bool { !text.isEmpty && !text.contains("\0") && text.utf8.count <= 65536 }
  func save(_ entries: [ClipboardHistoryEntry], enabled: Bool = true, capacity: Int = 20) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temporary = directory.appendingPathComponent(".clipboard-\(UUID().uuidString)")
    do {
      let data = try JSONEncoder().encode(Envelope(version: 1, entries: entries, enabled: enabled, capacity: capacity))
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
/// Serially manages bounded clipboard history, capacity trimming, pinning, and instant search on the MainActor.
@MainActor @Observable final class ClipboardHistory {
  private let storage: (any ClipboardHistoryStorage)?
  private let preferences: UserDefaults?
  private var tail: Task<Void, Never>?
  private(set) var enabled = false
  private(set) var entries: [ClipboardHistoryEntry] = []
  private(set) var error: String?
  private(set) var capacity: Int
  private var captures: [(ClipboardSample, String, String?)] = []
  private var recording = false
  private var preferenceRevision = 0
  var onChanged: () -> Void = {}
  // Delayed startup reads must not overwrite a newer collection preference.
  // Preferences instance is injected to isolate test executions from shared process UserDefaults.
  init(storage: (any ClipboardHistoryStorage)? = nil, capacity: Int? = nil, preferences: UserDefaults? = nil) {
    self.storage = storage
    self.preferences = preferences
    let saved = preferences?.integer(forKey: "clipboard.historyCapacity") ?? 0
    self.capacity = capacity ?? ([20, 50, 100].contains(saved) ? saved : 20)
    command {
      let saved = try await Task.detached { try storage?.load() }.value
      self.entries = saved?.entries ?? []
      if self.preferenceRevision == 0 { self.enabled = saved?.enabled ?? false }
      if capacity == nil, let savedCapacity = saved?.capacity { self.capacity = savedCapacity }
      self.onChanged()
    }
  }
  func setCapacity(_ value: Int) {
    guard [20, 50, 100].contains(value) else { return }
    command {
      let limit = min(value, 100 - self.entries.filter(\.pinned).count)
      var count = 0
      let rows = self.entries.filter { entry in
        if entry.pinned { return true }
        count += 1; return count <= limit
      }
      let storage = self.storage, enabled = self.enabled
      try await Task.detached { try storage?.save(rows, enabled: enabled, capacity: value) }.value
      self.capacity = value; self.entries = rows
      self.preferences?.set(value, forKey: "clipboard.historyCapacity")
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
      let rows = self.entries, storage = self.storage, capacity = self.capacity
      try await Task.detached { try storage?.save(rows, enabled: value, capacity: capacity) }.value
      if revision == self.preferenceRevision { self.enabled = value }; self.onChanged()
    }
  }
  func record(_ sample: ClipboardSample, origin: String, credential: String? = nil) {
    guard enabled, !sample.sensitive, !sample.excluded, ClipboardHistoryFile.valid(sample.text) else { return }
    // Bound pending content independently of the saved inventory while disk IO is stalled.
    if captures.count >= 100 { captures.removeFirst() }
    captures.append((sample, origin, credential))
    guard !recording else { return }; recording = true
    command {
      defer { self.recording = false; self.captures = [] }
      while self.enabled, !self.captures.isEmpty {
        let (sample, origin, credential) = self.captures.removeFirst()
        let existing = self.entries.first { $0.text == sample.text && $0.origin == origin }
        let row = ClipboardHistoryEntry(
          id: existing?.id ?? UUID().uuidString.lowercased(),
          text: sample.text,
          origin: origin,
          timestamp: Date(),
          credential: credential,
          pinned: existing?.pinned ?? false
        )
        let withoutRow = self.entries.filter { $0.id != row.id }
        let updated = [row] + withoutRow
        // Priority retention: keep all pinned items, plus newest unpinned items up to configured capacity.
        let unpinnedLimit = min(self.capacity, 100 - updated.filter(\.pinned).count)
        var unpinnedCount = 0
        let filtered = updated.filter { entry in
          if entry.pinned { return true }
          if unpinnedCount < unpinnedLimit {
            unpinnedCount += 1
            return true
          }
          return false
        }
        // Bound absolute total at 100 items matching the envelope storage limit.
        let rows = Array(filtered.prefix(100))
        let storage = self.storage, capacity = self.capacity
        try await Task.detached { try storage?.save(rows, enabled: true, capacity: capacity) }.value
        self.entries = rows
      }
    }
  }
  func togglePin(_ id: String) {
    replace { entries in
      entries.map { entry in
        if entry.id == id {
          return ClipboardHistoryEntry(
            id: entry.id,
            text: entry.text,
            origin: entry.origin,
            timestamp: entry.timestamp,
            credential: entry.credential,
            pinned: !entry.pinned
          )
        }
        return entry
      }
    }
  }
  /// Case-insensitive in-memory substring search over bounded history inventory.
  func search(query: String) -> [ClipboardHistoryEntry] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return entries }
    return entries.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
  }
  func delete(_ id: String) { replace { $0.filter { $0.id != id } } }
  // Retains pinned items by default when clearing unpinned history.
  func clear(includePinned: Bool = false) { replace { includePinned ? [] : $0.filter(\.pinned) } }
  private func replace(_ transform: @escaping ([ClipboardHistoryEntry]) -> [ClipboardHistoryEntry]) { command {
    let rows = transform(self.entries), storage = self.storage, enabled = self.enabled, capacity = self.capacity
    try await Task.detached { try storage?.save(rows, enabled: enabled, capacity: capacity) }.value
    self.entries = rows
  } }
}
