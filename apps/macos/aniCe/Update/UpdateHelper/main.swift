// SPDX-License-Identifier: GPL-3.0-or-later
// Detached installer: swaps in a verified bundle and restores the previous one if launch never confirms.
import AppKit
import Darwin
import Foundation

func argument(_ name: String) -> String? {
  let arguments = CommandLine.arguments
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
}

func fail(_ record: MacUpdateRecord, keepingStaging: Bool = false) -> Never {
  var record = record
  record.phase = .failed
  if (try? record.write()) == nil { MacUpdateRecord.remove(ifOwnedBy: record.nonce) }
  if !keepingStaging { try? FileManager.default.removeItem(at: record.stagingURL) }
  exit(1)
}

func isRunning(_ pid: Int32) -> Bool {
  if kill(pid, 0) == 0 { return true }
  return errno == EPERM
}

func installRecordExists() -> Bool {
  FileManager.default.fileExists(atPath: MacUpdateRecord.recordURL.path)
}

func bundleInfo(_ url: URL) -> NSDictionary? {
  NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
}

// An atomic exchange leaves a complete app at the destination even if this process dies mid-swap.
func swapBundles(_ first: URL, _ second: URL) -> Bool {
  first.withUnsafeFileSystemRepresentation { a in
    second.withUnsafeFileSystemRepresentation { b in
      guard let a, let b else { return false }
      return renameatx_np(AT_FDCWD, a, AT_FDCWD, b, UInt32(RENAME_SWAP)) == 0
    }
  }
}

func openApp(_ url: URL) -> Bool {
  let launcher = Process()
  launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  launcher.arguments = ["-n", url.path]
  guard (try? launcher.run()) != nil else { return false }
  launcher.waitUntilExit()
  return launcher.terminationStatus == 0
}

func restorePreviousApp(_ record: MacUpdateRecord) -> Never {
  guard MacUpdateRecovery.restorePreviousBundle(record, swap: swapBundles, launch: openApp) else {
    fail(record, keepingStaging: true)
  }
  try? FileManager.default.removeItem(at: record.stagingURL)
  exit(1)
}

// A launch can succeed even when the new build crashes before its main window appears.
func runningApp(at destination: URL, excluding pid: Int32) -> NSRunningApplication? {
  NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.anisharyal09.anice")
    .first {
      $0.processIdentifier != pid &&
        $0.bundleURL.map { MacUpdateRecord.canonical($0) == MacUpdateRecord.canonical(destination) } == true
    }
}

guard let nonce = argument("--nonce"), let pid = argument("--wait-pid").flatMap(Int32.init), pid > 1,
  var record = MacUpdateRecord.load(), record.nonce == nonce, record.phase == .prepared else { exit(2) }

let lock = open(MacUpdateRecord.lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(3) }
defer { close(lock) }

// A concurrent helper or a still-running app must leave the installed bundle untouched.
let deadline = Date().addingTimeInterval(60)
while isRunning(pid) {
  guard Date() < deadline else { exit(4) }
  usleep(200_000)
}

let destination = URL(fileURLWithPath: record.destination, isDirectory: true)
guard let staged = bundleInfo(record.bundleURL),
  staged["CFBundleIdentifier"] as? String == "io.github.anisharyal09.anice",
  staged["CFBundleShortVersionString"] as? String == String(record.targetTag.dropFirst()),
  staged["CFBundleVersion"] as? String == String(record.targetCode),
  (bundleInfo(destination)?["CFBundleIdentifier"] as? String) == "io.github.anisharyal09.anice",
  let installedCode = (bundleInfo(destination)?["CFBundleVersion"] as? String).flatMap(Int.init),
  record.targetCode > installedCode else { fail(record) }

do {
  try MacUpdateSignature.validate(record.bundleURL, identifier: "io.github.anisharyal09.anice",
    pins: Set(record.pins))
} catch { fail(record) }

record.phase = .installing
do { try record.write() } catch { fail(record) }

guard swapBundles(record.bundleURL, destination) else { fail(record) }
record.phase = .installed
try? record.write()

if !openApp(destination) {
  // The staged path now holds the previous bundle; exchange it back before giving up.
  restorePreviousApp(record)
}

// The new build proves startup by clearing its install record from the main window.
let startupDeadline = Date().addingTimeInterval(30)
while Date() < startupDeadline {
  if !installRecordExists() { exit(0) }
  usleep(250_000)
}
// Confirmation can arrive between the final poll and the rollback; never undo a confirmed launch.
guard installRecordExists() else { exit(0) }
if let launchedApp = runningApp(at: destination, excluding: pid) {
  _ = launchedApp.terminate()
  let terminationDeadline = Date().addingTimeInterval(5)
  while !launchedApp.isTerminated && Date() < terminationDeadline { usleep(100_000) }
  if !launchedApp.isTerminated { _ = launchedApp.forceTerminate() }
}
guard installRecordExists() else { exit(0) }
restorePreviousApp(record)
