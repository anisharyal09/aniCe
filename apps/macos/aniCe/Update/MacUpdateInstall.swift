// SPDX-License-Identifier: GPL-3.0-or-later
// Stages a release and launches the detached helper; installation requires a signed release build.
import Darwin
import Foundation

enum MacUpdateInstall {
  enum Error: LocalizedError {
    case pinsUnavailable, unsupportedLocation, unsupportedVolume, helperMissing, launchFailed, previewBuild

    var errorDescription: String? {
      switch self {
      case .pinsUnavailable:
        return "This build cannot verify update signatures. Open the release on GitHub to install manually."
      case .unsupportedLocation:
        return "aniCe cannot replace itself in this folder. Move aniCe to Applications or install the update manually."
      case .unsupportedVolume:
        return "This volume does not support automatic app replacement. Move aniCe to a local disk or install the update manually."
      case .helperMissing:
        return "The update helper is missing from this build. Open the release on GitHub to install manually."
      case .launchFailed:
        return "The update helper did not start. Try again or install the update manually."
      case .previewBuild:
        return "Preview copies do not install release updates. Use the installed aniCe app to test updating."
      }
    }
  }

  static let pinsKey = "AniceUpdateCertificatePins"
  static let helperIdentifier = "io.github.anisharyal09.anice.update-helper"

  static func pins() -> Set<String>? {
    let raw = Bundle.main.infoDictionary?[pinsKey] as? String ?? ""
    let pins = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      .filter { !$0.isEmpty })
    guard (1...2).contains(pins.count),
      pins.allSatisfy({ $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } })
    else { return nil }
    return pins
  }

  static func problem(destination: URL = Bundle.main.bundleURL) -> String? {
    if MacAppStorage.isPreview { return Error.previewBuild.localizedDescription }
    let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
    if destination.path.contains("/AppTranslocation/") {
      return "Move aniCe to Applications before installing an update."
    }
    guard pins() != nil else {
      return "Automatic installation is available in signed release builds; open the release to download manually."
    }
    let parent = destination.deletingLastPathComponent()
    guard FileManager.default.isWritableFile(atPath: parent.path) else {
      return "aniCe cannot replace itself in this folder; open the release to install manually."
    }
    return nil
  }

  // An atomic exchange keeps one complete app at the destination if the machine stops mid-install.
  // Volumes without RENAME_SWAP must fail before the helper quits the app, not after.
  static func supportsAtomicSwap(in directory: URL) -> Bool {
    let manager = FileManager.default
    let first = directory.appendingPathComponent(".aniCe-swap-\(UUID().uuidString)")
    let second = directory.appendingPathComponent(".aniCe-swap-\(UUID().uuidString)")
    guard manager.createFile(atPath: first.path, contents: Data()),
      manager.createFile(atPath: second.path, contents: Data()) else {
      try? manager.removeItem(at: first)
      try? manager.removeItem(at: second)
      return false
    }
    defer {
      try? manager.removeItem(at: first)
      try? manager.removeItem(at: second)
    }
    return first.withUnsafeFileSystemRepresentation { a in
      second.withUnsafeFileSystemRepresentation { b in
        guard let a, let b else { return false }
        return renameatx_np(AT_FDCWD, a, AT_FDCWD, b, UInt32(RENAME_SWAP)) == 0
      }
    }
  }

  static func launch(_ release: AvailableMacRelease, destination: URL = Bundle.main.bundleURL,
    progress: @escaping @Sendable (Int64, Int64?) async -> Void) async throws {
    guard !MacAppStorage.isPreview else { throw Error.previewBuild }
    guard let pins = pins() else { throw Error.pinsUnavailable }
    // Swap the bundle the symlink points at, never a link placed beside it.
    let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
    guard problem(destination: destination) == nil else { throw Error.unsupportedLocation }
    guard supportsAtomicSwap(in: destination.deletingLastPathComponent()) else { throw Error.unsupportedVolume }
    let prepared = try await MacUpdateStaging.prepare(release, beside: destination, pins: pins, progress: progress)
    let record = MacUpdateRecord(nonce: UUID().uuidString, targetTag: release.version.tag,
      targetCode: release.version.code, destination: destination.path, staging: prepared.directory.path,
      pins: pins.sorted(), created: Date().timeIntervalSince1970, phase: .prepared)
    do {
      try record.write()
      let helper = prepared.directory.appendingPathComponent("aniCeUpdateHelper")
      let source = destination.appendingPathComponent("Contents/Helpers/aniCeUpdateHelper")
      guard FileManager.default.fileExists(atPath: source.path) else { throw Error.helperMissing }
      try FileManager.default.copyItem(at: source, to: helper)
      try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: helper.path)
      try MacUpdateSignature.validate(helper, identifier: helperIdentifier, pins: pins)
      let process = Process()
      process.executableURL = helper
      process.arguments = ["--nonce", record.nonce, "--wait-pid", String(ProcessInfo.processInfo.processIdentifier)]
      try process.run()
      // The helper blocks on our process; an immediate exit means it could not start installing.
      try? await Task.sleep(for: .milliseconds(300))
      guard process.isRunning else { throw Error.launchFailed }
    } catch {
      MacUpdateRecord.remove(ifOwnedBy: record.nonce)
      try? FileManager.default.removeItem(at: prepared.directory)
      throw error
    }
  }
}
