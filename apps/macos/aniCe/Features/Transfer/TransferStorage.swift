// SPDX-License-Identifier: GPL-3.0-or-later
// Owns transfer source reads, verified receiver staging and non-overwriting publication.

import Foundation
import CryptoKit
import Darwin

// Each received file has one storage actor; checked writes precede ACK credit.
actor TransferReceiveStorage {
  private var handle: FileHandle?
  private var partial: URL?
  private var folder: URL?
  private var hasher = SHA256()
  private var preservePartial = false

  static func checkCapacity(_ folder: URL, bytes: Int64) async throws {
    try await Task.detached {
      let available = try folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
      if let available, Double(bytes) + 64 * 1048576 > Double(available) { throw CocoaError(.fileWriteOutOfSpace) }
    }.value
  }

  func create(folder: URL, batch: String, file: String) throws -> URL {
    let started = SessionTiming.start()
    defer { SessionTiming.end(self, "storage_create", started, direction: "receive") }
    assert(!Thread.isMainThread)
    let url = folder.appendingPathComponent(".anice-\(batch)-\(file)-\(UUID().uuidString).part")
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    self.folder = folder
    partial = url
    handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    return url
  }

  func write(_ data: Data) throws {
    let started = SessionTiming.start()
    defer { SessionTiming.end(self, "storage_write", started, bytes: data.count, direction: "receive") }
    assert(!Thread.isMainThread)
    try Task.checkCancellation()
    guard let handle else { throw CocoaError(.fileWriteUnknown) }
    try handle.write(contentsOf: data)
    hasher.update(data: data)
  }

  func flush() throws {
    let started = SessionTiming.start()
    defer { SessionTiming.end(self, "storage_flush", started, direction: "receive") }
    try handle?.synchronize()
  }

  func fileIdentity() throws -> String {
    let started = SessionTiming.start()
    defer { SessionTiming.end(self, "storage_fileIdentity", started, direction: "receive") }
    guard let partial else { throw CocoaError(.fileReadUnknown) }
    return try Self.identity(partial)
  }

  private static func identity(_ url: URL) throws -> String {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let device = attributes[.systemNumber] as? NSNumber,
      let inode = attributes[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
    return "\(device):\(inode)"
  }

  static func discardOwned(folder: URL, partial: URL, batch: String, file: String) throws {
    guard FileManager.default.fileExists(atPath: partial.path) else { return }
    guard partial.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path,
      partial.lastPathComponent.hasPrefix(".anice-\(batch)-\(file)-"), partial.pathExtension == "part",
      try partial.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { throw CocoaError(.fileReadCorruptFile) }
    try FileManager.default.removeItem(at: partial)
  }

  static func published(folder: URL, file: TransferFile, identity expected: String) throws -> URL? {
    var ambiguous = false, checked = 0
    for suffix in 0..<TransferPublisher.maximumSuffix {
      let target = folder.appendingPathComponent(TransferPublisher.suffixed(file.name, suffix))
      guard FileManager.default.fileExists(atPath: target.path),
        try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { continue }
      let owned = try !expected.isEmpty && identity(target) == expected
      guard try target.resourceValues(forKeys: [.fileSizeKey]).fileSize.map({ Int64($0) }) == file.size else {
        if owned { throw CocoaError(.fileReadCorruptFile) }
        continue
      }
      if !owned { checked += 1; if checked > 32 { ambiguous = true; continue } }
      let reader = try FileHandle(forReadingFrom: target)
      defer { try? reader.close() }
      var digest = SHA256(), size: Int64 = 0
      while let bytes = try reader.read(upToCount: 131072), !bytes.isEmpty {
        digest.update(data: bytes); size += Int64(bytes.count)
      }
      guard size == file.size, Data(digest.finalize()) == file.sha256 else {
        if owned { throw CocoaError(.fileReadCorruptFile) }
        continue
      }
      if owned { return target }
      ambiguous = true
    }
    if ambiguous { throw NSError(domain: "aniCe.TransferRecovery", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "The file may already be saved. Check the destination before sending it again."]) }
    return nil
  }

  func restore(folder: URL, partial: URL, batch: String, file: String, length: Int64) throws {
    let started = SessionTiming.start()
    defer { SessionTiming.end(self, "storage_restore", started, direction: "receive") }
    guard length >= 0,
      partial.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path,
      partial.lastPathComponent.hasPrefix(".anice-\(batch)-\(file)-"), partial.pathExtension == "part",
      try partial.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { throw CocoaError(.fileReadCorruptFile) }
    let descriptor = open(partial.path, O_RDWR | O_NOFOLLOW)
    guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
    let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      var remaining = length
      while remaining > 0 {
        guard let bytes = try writer.read(upToCount: Int(min(remaining, 1 << 20))), !bytes.isEmpty else {
          throw CocoaError(.fileReadCorruptFile)
        }
        hasher.update(data: bytes); remaining -= Int64(bytes.count)
      }
      try writer.truncate(atOffset: UInt64(length))
      try writer.seek(toOffset: UInt64(length))
    } catch { try? writer.close(); throw error }
    self.folder = folder; self.partial = partial; handle = writer
  }

  /// Flushes and hashes exactly `length` bytes of the retained partial. The receiver sends this
  /// digest so the sender can prove its own source prefix before switching transports.
  func prefixDigest(_ length: Int64) throws -> Data {
    let started = SessionTiming.start()
    defer { SessionTiming.end(self, "storage_prefixDigest", started, direction: "receive") }
    assert(!Thread.isMainThread)
    guard length >= 0, let handle, let partial else { throw CocoaError(.fileReadUnknown) }
    try handle.synchronize()
    let reader = try FileHandle(forReadingFrom: partial)
    defer { try? reader.close() }
    var digest = SHA256()
    var remaining = length
    while remaining > 0 {
      guard let block = try reader.read(upToCount: Int(min(remaining, 1 << 20))), !block.isEmpty else {
        throw CocoaError(.fileReadUnknown)
      }
      digest.update(data: block)
      remaining -= Int64(block.count)
    }
    return Data(digest.finalize())
  }

  /// Flushes the retained prefix and verifies that exactly `length` bytes on disk match
  /// `expected`. The sender's resume hash proves its source and this receiver's partial agree.
  func matchesPrefix(_ length: Int64, expected: Data) throws -> Bool {
    try prefixDigest(length) == expected
  }

  func finish(name: String, expected: Data) throws -> (digest: Data, url: URL) {
    let started = SessionTiming.start()
    defer { SessionTiming.end(self, "storage_finish", started, direction: "receive") }
    assert(!Thread.isMainThread)
    guard let handle, let partial, let folder else { throw CocoaError(.fileWriteUnknown) }
    let digest = Data(hasher.finalize())
    guard digest == expected else { throw SessionFailure.authentication }
    preservePartial = true
    try handle.synchronize()
    try handle.close()
    self.handle = nil
    let publishedURL = try TransferPublisher.publish(partial, as: name, in: folder)
    self.partial = nil
    return (digest: digest, url: publishedURL)
  }

  func discard() {
    let started = SessionTiming.start()
    defer { SessionTiming.end(self, "storage_discard", started, direction: "receive") }
    assert(!Thread.isMainThread)
    do {
      try handle?.close(); handle = nil
      if !preservePartial, let partial, FileManager.default.fileExists(atPath: partial.path) {
        try FileManager.default.removeItem(at: partial)
      }
    } catch { NSLog("Transfer partial cleanup failed: %@", error.localizedDescription) }
  }
}

actor TransferSendStorage {
  private let handle: FileHandle
  private let closeHandle: @Sendable (FileHandle) throws -> Void
  private init(_ url: URL, close: @escaping @Sendable (FileHandle) throws -> Void) throws {
    handle = try FileHandle(forReadingFrom: url); closeHandle = close
  }
  static func open(_ url: URL, skipping offset: Int64 = 0,
    close: @escaping @Sendable (FileHandle) throws -> Void) async throws -> TransferSendStorage {
    let storage = try await Task.detached { try TransferSendStorage(url, close: close) }.value
    if offset > 0 { try await storage.skip(offset) }
    return storage
  }
  private func skip(_ offset: Int64) throws {
    assert(!Thread.isMainThread)
    var remaining = offset
    while remaining > 0 {
      guard let block = try handle.read(upToCount: Int(min(remaining, 1 << 20))), !block.isEmpty else {
        throw CocoaError(.fileReadCorruptFile)
      }
      remaining -= Int64(block.count)
    }
  }
  /// SHA-256 over exactly the first `length` source bytes, used to prove a resume prefix.
  static func prefixDigest(_ url: URL, length: Int64) async throws -> Data {
    try await Task.detached(priority: .utility) {
      guard length >= 0 else { throw CocoaError(.fileReadUnknown) }
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var digest = SHA256()
      var remaining = length
      while remaining > 0 {
        guard let block = try handle.read(upToCount: Int(min(remaining, 1 << 20))), !block.isEmpty else {
          throw CocoaError(.fileReadCorruptFile)
        }
        digest.update(data: block)
        remaining -= Int64(block.count)
      }
      return Data(digest.finalize())
    }.value
  }
  func readChunk(_ count: Int, batch: String, file: String, offset: Int64, maximumChunk: Int) throws -> Data {
    assert(!Thread.isMainThread)
    try Task.checkCancellation()
    // FileHandle normally fills the request. Keep that buffer instead of copying it into a second Data.
    var bytes = try handle.read(upToCount: count) ?? Data()
    while bytes.count < count {
      guard let next = try handle.read(upToCount: count - bytes.count), !next.isEmpty else { break }
      bytes.append(next)
    }
    guard bytes.count == count else { throw CocoaError(.fileReadCorruptFile) }
    let encoded = try TransferMessage.chunk(batch: batch, file: file, offset: offset, data: bytes)
      .encode(maximumChunkBytes: maximumChunk)
    try Task.checkCancellation()
    return encoded
  }
  func close() {
    assert(!Thread.isMainThread)
    do { try closeHandle(handle) } catch { NSLog("Transfer source close failed: %@", error.localizedDescription) }
  }
}

// MARK: - Verified file publication

/// Publishes a verified partial into its destination folder without overwriting anything.
///
/// The link is what decides the name, so a collision is resolved by the filesystem refusing the
/// link rather than by a check-then-act on an existence probe. A hard link is an implementation
/// detail of publication, not a requirement of the transfer, so a destination that cannot hold one
/// (iCloud Drive, an external or network volume) publishes by copying. The digest is verified
/// before this runs, so neither mode can publish unverified bytes.
enum TransferPublisher {
  /// Suffix attempts before publication is reported as impossible.
  static let maximumSuffix = 10000

  /// `name` for suffix `0`, otherwise `base (suffix).ext`.
  static func suffixed(_ name: String, _ suffix: Int) -> String {
    guard suffix > 0 else { return name }
    let ns = name as NSString
    let ext = ns.pathExtension
    let base = ns.deletingPathExtension
    return ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
  }

  /// The real POSIX reason, so a failure is diagnosable instead of reported as an unknown save error.
  private static func failure(_ code: Int32, _ url: URL) -> Error {
    let reason = String(cString: strerror(code))
    return NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(code),
      userInfo: [NSLocalizedDescriptionKey: "\(reason) (\(url.lastPathComponent))"]
    )
  }

  /// The link primitive, so a volume that cannot hold hard links is verifiable without one.
  @discardableResult
  static func publish(
    _ partial: URL,
    as name: String,
    in folder: URL,
    hardLink: (String, String) -> Int32 = { Darwin.link($0, $1) }
  ) throws -> URL {
    var suffix = 0
    var linking = true
    while suffix <= maximumSuffix {
      let target = folder.appendingPathComponent(suffixed(name, suffix))
      if linking {
        if hardLink(partial.path, target.path) == 0 {
          guard unlink(partial.path) == 0 else { throw failure(errno, partial) }
          return target
        }
        let code = errno
        if code == EEXIST {
          suffix += 1
          continue
        }
        // Only a volume that cannot express a link switches modes; any other error is real.
        guard code == EXDEV || code == ENOTSUP || code == EPERM || code == EMLINK else {
          // The destination is what could not be published, so it is what the failure names — the
          // staging partial is a random name the user never chose and cannot act on.
          throw failure(code, target)
        }
        linking = false
        suffix = 0
        continue
      }
      // O_EXCL makes the destination decision atomic and non-overwriting.
      let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
      if descriptor < 0 {
        let code = errno
        // A name already in use advances the suffix rather than discarding an already verified
        // transfer. An existing symlink is one: the system reports it as EEXIST or, under
        // O_NOFOLLOW, as ELOOP.
        if code == EEXIST || code == ELOOP {
          suffix += 1
          continue
        }
        throw failure(code, target)
      }
      do {
        // The destination handle owns the descriptor, so creating it before anything that can throw
        // means an unwind still closes the descriptor instead of leaking it.
        let destination = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let source = try FileHandle(forReadingFrom: partial)
        while let block = try source.read(upToCount: 1 << 20), !block.isEmpty {
          try destination.write(contentsOf: block)
        }
        try source.close()
        try destination.synchronize()
        try destination.close()
      } catch {
        // A half-written copy is not a published file; the verified partial survives for recovery.
        try? FileManager.default.removeItem(at: target)
        throw error
      }
      try FileManager.default.removeItem(at: partial)
      return target
    }
    throw failure(EEXIST, folder.appendingPathComponent(name))
  }
}
