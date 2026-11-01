// SPDX-License-Identifier: GPL-3.0-or-later
// Validates and atomically persists transfer recovery checkpoints.
import Foundation
import Darwin

// Checkpoints contain logical work and file references; fresh channels always authenticate independently.
struct TransferCheckpoint: Codable, Sendable {
  var version = 1
  let localFingerprint: String
  let peerId: String
  let peerFingerprint: String
  let batch: TransferBatch
  let receiving: Bool
  var index: Int
  var offset: Int64
  let folder: URL?
  var partial: URL?
  let transport: String
  let expiresAt: Date
  var stage = 0
  var fileIdentity = ""

  func validate() throws {
    let hex = Set("0123456789abcdef")
    guard version == 1, localFingerprint.count == 64, peerFingerprint.count == 64,
      localFingerprint.allSatisfy({ hex.contains($0) }), peerFingerprint.allSatisfy({ hex.contains($0) }),
      UUID(uuidString: peerId) != nil, (1...128).contains(batch.files.count),
      batch.files.indices.contains(index), Set(batch.files.map(\.id)).count == batch.files.count,
      offset >= 0, offset <= batch.files[index].size, ["lan", "ble"].contains(transport),
      expiresAt.timeIntervalSince1970.isFinite, (0...4).contains(stage) else { throw CocoaError(.fileReadCorruptFile) }
    var total: Int64 = 0
    for file in batch.files {
      guard file.size >= 0, file.sha256.count == 32, (1...255).contains(file.name.utf8.count),
        file.name != ".", file.name != "..", !file.name.contains("/"), !file.name.contains("\\"),
        !file.name.unicodeScalars.contains(where: { $0.value < 32 }),
        file.localURL == nil || file.localURL?.isFileURL == true else { throw CocoaError(.fileReadCorruptFile) }
      let next = total.addingReportingOverflow(file.size)
      guard !next.overflow else { throw CocoaError(.fileReadCorruptFile) }
      total = next.partialValue
    }
    guard total == batch.totalBytes else { throw CocoaError(.fileReadCorruptFile) }
    guard stage != 1 || !receiving, stage != 2 || receiving,
      stage != 3 || (receiving && index == batch.files.count - 1 && offset == batch.files[index].size),
      stage != 4 || (receiving && offset == batch.files[index].size) else { throw CocoaError(.fileReadCorruptFile) }
  }
}

actor TransferRecoveryStore {
  private let url: URL
  init(_ url: URL) { self.url = url }

  func load() throws -> TransferCheckpoint? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard (1...1048576).contains(size) else { throw CocoaError(.fileReadCorruptFile) }
    let saved = try JSONDecoder().decode(TransferCheckpoint.self, from: Data(contentsOf: url))
    try saved.validate()
    return saved
  }

  func save(_ snapshot: TransferCheckpoint) throws {
    try snapshot.validate()
    let bytes = try JSONEncoder().encode(snapshot)
    guard bytes.count <= 1048576 else { throw CocoaError(.fileWriteUnknown) }
    let folder = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = folder.appendingPathComponent("checkpoint-\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close()
      guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    } catch {
      try? handle.close()
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  func clear() throws {
    if unlink(url.path) != 0, errno != ENOENT { throw CocoaError(.fileWriteUnknown) }
  }
}
