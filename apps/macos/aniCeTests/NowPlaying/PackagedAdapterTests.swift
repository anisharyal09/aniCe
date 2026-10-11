// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies native session security and presentation readiness against fixtures and adversarial transitions.
import CryptoKit
import AppKit
import Foundation
import XCTest
import SwiftUI
import Observation

@testable import aniCe

final class NowPlayingGateTests: XCTestCase, @unchecked Sendable {
  func testSandboxRemovalKeepsOriginalJournalDirectory() {
    let home = URL(fileURLWithPath: "/Users/test account", isDirectory: true)
    let directory = MacAppStorage.directory(home: home)
    XCTAssertEqual(directory.path, "/Users/test account/Library/Containers/io.github.anisharyal09.anice/Data/Library/Application Support/aniCe")
    XCTAssertNotEqual(directory.path, home.appendingPathComponent("Library/Application Support/aniCe").path)
  }

  func testPackagedWatchRejectsStaleAndOversizedCommandsAndExitsOnEOF() throws {
    let resources = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("NowPlaying")
    let library = resources.appendingPathComponent("libaniCeNowPlaying.dylib")
    XCTAssertTrue(FileManager.default.fileExists(atPath: library.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("GPL-LICENSE.txt").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("THIRD_PARTY_NOTICES.md").path))
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = [resources.appendingPathComponent("now-playing.pl").path, library.path, "watch_all"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let first = expectation(description: "initial native snapshot")
    let rejected = expectation(description: "stale and oversized requests rejected")
    rejected.expectedFulfillmentCount = 2
    let ended = expectation(description: "EOF terminates adapter")
    let lock = NSLock()
    let buffer = GateBuffer()
    output.fileHandleForReading.readabilityHandler = { file in
      let bytes = file.availableData
      lock.lock()
      defer { lock.unlock() }
      buffer.lines.append(bytes)
      guard buffer.lines.count <= 17 * 1024 * 1024 else { XCTFail("unbounded adapter output"); return }
      while let newline = buffer.lines.firstIndex(of: 10) {
        let line = buffer.lines.prefix(upTo: newline)
        buffer.lines.removeSubrange(...newline)
        guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
          XCTFail("invalid native reply"); continue
        }
        if let sent = row["sent"] as? Bool {
          XCTAssertFalse(sent)
          if buffer.rejectionCount < 2 { buffer.rejectionCount += 1; rejected.fulfill() }
        } else if !buffer.firstReceived {
          buffer.firstReceived = true
          XCTAssertNil(row["error"], "native loader did not produce a snapshot")
          XCTAssertNotNil(row["sources"])
          first.fulfill()
        }
      }
    }
    process.terminationHandler = { _ in ended.fulfill() }
    try process.run()
    defer {
      output.fileHandleForReading.readabilityHandler = nil
      try? input.fileHandleForWriting.close()
      if process.isRunning { process.terminate() }
    }
    wait(for: [first], timeout: 8)
    let stale = "play 2147483647 00000000-0000-0000-0000-000000000000 toggle\n"
    try input.fileHandleForWriting.write(contentsOf: Data((String(repeating: "x", count: 2049) + "\n" + stale).utf8))
    wait(for: [rejected], timeout: 5)
    try input.fileHandleForWriting.close()
    wait(for: [ended], timeout: 3)
    XCTAssertEqual(process.terminationStatus, 0)
  }
}

/// Mutable pipe state is protected by the test reader's lock.
private final class GateBuffer: @unchecked Sendable {
  var lines = Data()
  var firstReceived = false
  var rejectionCount = 0
}

