// SPDX-License-Identifier: GPL-3.0-or-later
// Publishes verified transfer partials without overwriting destination files.
import Foundation
import Darwin

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
