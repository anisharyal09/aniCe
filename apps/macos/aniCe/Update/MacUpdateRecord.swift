// SPDX-License-Identifier: GPL-3.0-or-later
// Durable, nonce-bound install record shared by the app and the detached update helper.
import Foundation

struct MacUpdateRecord: Codable, Equatable {
  enum Phase: String, Codable { case prepared, installing, installed, failed }

  let nonce: String
  let targetTag: String
  let targetCode: Int
  let destination: String
  let staging: String
  let pins: [String]
  let created: Double
  var phase: Phase

  static let directory: URL = {
    #if ANICE_TRANSFER_PREVIEW
    let path = "Library/Application Support/aniCe Transfer Preview/Update"
    #elseif ANICE_PREVIEW
    let path = "Library/Application Support/aniCe Preview/Update"
    #else
    let path = "Library/Application Support/aniCe/Update"
    #endif
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path, isDirectory: true)
  }()
  static let recordURL = directory.appendingPathComponent("record.json")
  static let lockURL = directory.appendingPathComponent("install.lock")

  var stagingURL: URL { URL(fileURLWithPath: staging, isDirectory: true) }
  var bundleURL: URL { stagingURL.appendingPathComponent("aniCe.app", isDirectory: true) }

  // /tmp is a symlink to /private/tmp; compare where the paths actually land, not how they were spelled.
  static func canonical(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  // Bounds every path the helper and recovery cleanup may touch.
  var isValidLayout: Bool {
    func isPin(_ pin: String) -> Bool {
      pin.count == 64 && pin.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    guard UUID(uuidString: nonce) != nil, let version = UpdateVersion.parse(targetTag), version.code == targetCode,
      destination.hasPrefix("/"), destination.hasSuffix(".app"), staging.hasPrefix("/"),
      Self.canonical(URL(fileURLWithPath: staging).deletingLastPathComponent())
        == Self.canonical(URL(fileURLWithPath: destination).deletingLastPathComponent()),
      URL(fileURLWithPath: staging).lastPathComponent.hasPrefix(".aniCe-update-"),
      (1...2).contains(pins.count), pins.allSatisfy(isPin), created > 0 else { return false }
    return true
  }

  static func load(from url: URL = recordURL) -> Self? {
    guard let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(Self.self, from: data),
      record.isValidLayout else { return nil }
    return record
  }

  func write(to url: URL = recordURL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = directory.appendingPathComponent(".record-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
      attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
    let handle = try FileHandle(forWritingTo: temporary)
    do {
      try handle.write(contentsOf: try JSONEncoder().encode(self))
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
    guard rename(temporary.path, url.path) == 0 else {
      try? FileManager.default.removeItem(at: temporary)
      throw POSIXError(.EIO)
    }
  }

  static func remove(from url: URL = recordURL) { try? FileManager.default.removeItem(at: url) }

  // A failed launch must not delete a record another install already replaced.
  static func remove(ifOwnedBy nonce: String, from url: URL = recordURL) {
    guard load(from: url)?.nonce == nonce else { return }
    remove(from: url)
  }
}

enum MacUpdateRecovery {
  // Persist failure before relaunch so the restored app can report it on its first window.
  static func restorePreviousBundle(_ record: MacUpdateRecord,
    recordURL: URL = MacUpdateRecord.recordURL,
    swap: (URL, URL) -> Bool, launch: (URL) -> Bool) -> Bool {
    let destination = URL(fileURLWithPath: record.destination, isDirectory: true)
    guard swap(record.bundleURL, destination) else { return false }
    var failed = record
    failed.phase = .failed
    if (try? failed.write(to: recordURL)) == nil {
      MacUpdateRecord.remove(ifOwnedBy: failed.nonce, from: recordURL)
    }
    _ = launch(destination)
    return true
  }

  // The helper declares .installing before an atomic exchange; a record older than this is abandoned.
  static let abandonedAfter: TimeInterval = 300

  // The record proves a swap happened; only a running main window confirms the new build started.
  static func confirmStartup(version: String?, destination: URL = Bundle.main.bundleURL,
    recordURL: URL = MacUpdateRecord.recordURL) -> String? {
    guard let record = MacUpdateRecord.load(from: recordURL) else { return nil }
    let sameDestination = MacUpdateRecord.canonical(URL(fileURLWithPath: record.destination))
      == MacUpdateRecord.canonical(destination)
    let matches = sameDestination && version == String(record.targetTag.dropFirst())
    func discardAndRemove() {
      // Remove the record first: it is the helper's startup-confirmation signal. Staging is best effort.
      MacUpdateRecord.remove(from: recordURL)
      try? FileManager.default.removeItem(at: record.stagingURL)
    }
    switch record.phase {
    case .installed where sameDestination
        && (matches || record.created < Date().timeIntervalSince1970 - abandonedAfter),
      .installing where matches:
      // The helper may have died after exchanging the bundles, or a later reinstall replaced the target.
      discardAndRemove()
      return nil
    case .failed where sameDestination:
      discardAndRemove()
      return "The previous update did not complete. aniCe kept the installed version."
    case .prepared where sameDestination, .installing where sameDestination:
      // A helper that never exchanged the bundles leaves the old app and an abandoned staging copy.
      guard record.created < Date().timeIntervalSince1970 - abandonedAfter else { return nil }
      discardAndRemove()
      return "The previous update did not complete. aniCe kept the installed version."
    case .prepared, .installing, .installed, .failed:
      // Another copy of aniCe owns this record; leave its recovery state untouched.
      return nil
    }
  }
}
