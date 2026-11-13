// SPDX-License-Identifier: GPL-3.0-or-later
// Rejects install records whose paths, pins or versions leave the updater's staging bounds.
import XCTest
@testable import aniCe

final class MacUpdateRecordTests: XCTestCase {
  private func record(nonce: String = UUID().uuidString, tag: String = "v0.4.0", code: Int = 40099,
    destination: String = "/Applications/aniCe.app", staging: String = "/Applications/.aniCe-update-abc",
    pins: [String] = [String(repeating: "a", count: 64)], created: Double = 1) -> MacUpdateRecord {
    MacUpdateRecord(nonce: nonce, targetTag: tag, targetCode: code, destination: destination, staging: staging,
      pins: pins, created: created, phase: .prepared)
  }

  func testLayoutRejectsOutOfBoundsRecords() {
    XCTAssertTrue(record().isValidLayout)
    XCTAssertFalse(record(code: 40098).isValidLayout)
    XCTAssertFalse(record(tag: "0.4.0").isValidLayout)
    XCTAssertFalse(record(destination: "/Applications/aniCe", staging: "/Applications/.aniCe-update-abc").isValidLayout)
    XCTAssertFalse(record(staging: "/tmp/.aniCe-update-abc").isValidLayout)
    XCTAssertFalse(record(staging: "/Applications/aniCe-update-abc").isValidLayout)
    XCTAssertFalse(record(nonce: "not-a-uuid").isValidLayout)
    XCTAssertFalse(record(pins: []).isValidLayout)
    XCTAssertFalse(record(pins: Array(repeating: String(repeating: "a", count: 64), count: 3)).isValidLayout)
    XCTAssertFalse(record(pins: [String(repeating: "A", count: 64)]).isValidLayout)
    XCTAssertFalse(record(pins: [String(repeating: "a", count: 63)]).isValidLayout)
    XCTAssertFalse(record(created: 0).isValidLayout)
  }

  func testWriteLoadRoundTripAndRejectsCorruption() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("record.json")
    let original = record()
    try original.write(to: url)
    XCTAssertEqual(MacUpdateRecord.load(from: url), original)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    try Data("{}".utf8).write(to: url)
    XCTAssertNil(MacUpdateRecord.load(from: url))
  }

  func testInstallingRecordIsConfirmedOnlyByTheMatchingRunningBuild() throws {
    let fixture = try recoveryFixture(.installing, created: Date().timeIntervalSince1970)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertNil(MacUpdateRecovery.confirmStartup(version: "0.4.0", destination: fixture.destination,
      recordURL: fixture.record))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.record.path))
  }

  func testRecentIncompleteRecordIsLeftForARunningHelper() throws {
    let fixture = try recoveryFixture(.installing, created: Date().timeIntervalSince1970)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertNil(MacUpdateRecovery.confirmStartup(version: "0.3.0", destination: fixture.destination,
      recordURL: fixture.record))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staging.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.record.path))
  }

  func testAbandonedPreparedOrInstallingRecordBecomesAVisibleFailure() throws {
    for phase in [MacUpdateRecord.Phase.prepared, .installing] {
      let fixture = try recoveryFixture(phase, created: Date().timeIntervalSince1970 - MacUpdateRecovery.abandonedAfter - 1)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      XCTAssertEqual(MacUpdateRecovery.confirmStartup(version: "0.3.0", destination: fixture.destination,
        recordURL: fixture.record), "The previous update did not complete. aniCe kept the installed version.")
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.record.path))
    }
  }

  func testRollbackMarksFailureBeforeRelaunchingTheRestoredBundle() throws {
    let fixture = try recoveryFixture(.installed)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let record = try XCTUnwrap(MacUpdateRecord.load(from: fixture.record))
    var events: [String] = []
    XCTAssertTrue(MacUpdateRecovery.restorePreviousBundle(record, recordURL: fixture.record,
      swap: { previous, destination in
        XCTAssertEqual(previous, record.bundleURL)
        XCTAssertEqual(destination, fixture.destination)
        events.append("swap")
        return true
      }, launch: { destination in
        XCTAssertEqual(destination, fixture.destination)
        XCTAssertEqual(MacUpdateRecord.load(from: fixture.record)?.phase, .failed)
        events.append("launch")
        return false
      }))
    XCTAssertEqual(events, ["swap", "launch"])
    XCTAssertEqual(MacUpdateRecovery.confirmStartup(version: "0.3.0", destination: fixture.destination,
      recordURL: fixture.record), "The previous update did not complete. aniCe kept the installed version.")
  }

  func testFailedRollbackPreservesRecoveryStateAndDoesNotLaunch() throws {
    let fixture = try recoveryFixture(.installed)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let record = try XCTUnwrap(MacUpdateRecord.load(from: fixture.record))
    XCTAssertFalse(MacUpdateRecovery.restorePreviousBundle(record, recordURL: fixture.record,
      swap: { _, _ in false }, launch: { _ in XCTFail("No bundle was restored"); return true }))
    XCTAssertEqual(MacUpdateRecord.load(from: fixture.record), record)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staging.path))
  }

  private func recoveryFixture(_ phase: MacUpdateRecord.Phase, created: Double = 1) throws
    -> (root: URL, destination: URL, staging: URL, record: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let destination = root.appendingPathComponent("aniCe.app", isDirectory: true)
    let staging = root.appendingPathComponent(".aniCe-update-test", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let record = root.appendingPathComponent("record.json")
    try MacUpdateRecord(nonce: UUID().uuidString, targetTag: "v0.4.0", targetCode: 40099,
      destination: destination.path, staging: staging.path, pins: [String(repeating: "a", count: 64)],
      created: created, phase: phase).write(to: record)
    return (root, destination, staging, record)
  }

  func testFreshInstalledRecordIsLeftForTheLaunchingBuild() throws {
    let fixture = try recoveryFixture(.installed, created: Date().timeIntervalSince1970)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertNil(MacUpdateRecovery.confirmStartup(version: "0.4.1", destination: fixture.destination,
      recordURL: fixture.record))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staging.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.record.path))

    XCTAssertNil(MacUpdateRecovery.confirmStartup(version: "0.4.0", destination: fixture.destination,
      recordURL: fixture.record))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.record.path))
  }

  func testAbandonedInstalledRecordForAnotherVersionIsDiscarded() throws {
    let fixture = try recoveryFixture(.installed,
      created: Date().timeIntervalSince1970 - MacUpdateRecovery.abandonedAfter - 1)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertNil(MacUpdateRecovery.confirmStartup(version: "0.4.1", destination: fixture.destination,
      recordURL: fixture.record))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.record.path))
  }

  func testConditionalRemovalLeavesARecordOwnedByAnotherInstall() throws {
    let fixture = try recoveryFixture(.installed)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let record = try XCTUnwrap(MacUpdateRecord.load(from: fixture.record))
    MacUpdateRecord.remove(ifOwnedBy: UUID().uuidString, from: fixture.record)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.record.path))
    MacUpdateRecord.remove(ifOwnedBy: record.nonce, from: fixture.record)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.record.path))
  }

  func testDestinationComparisonResolvesSymlinks() throws {
    let fixture = try recoveryFixture(.installed)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let link = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.destination)
    defer { try? FileManager.default.removeItem(at: link) }
    XCTAssertNil(MacUpdateRecovery.confirmStartup(version: "0.4.0", destination: link,
      recordURL: fixture.record))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.record.path))
  }

  func testRecoveryIgnoresRecordsOwnedByAnotherAppCopy() throws {
    let other = FileManager.default.temporaryDirectory.appendingPathComponent("aniCe-\(UUID().uuidString).app")
    for phase in [MacUpdateRecord.Phase.failed, .installed, .prepared] {
      let fixture = try recoveryFixture(phase,
        created: Date().timeIntervalSince1970 - MacUpdateRecovery.abandonedAfter - 1)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      XCTAssertNil(MacUpdateRecovery.confirmStartup(version: "0.4.0", destination: other,
        recordURL: fixture.record))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staging.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.record.path))
    }
  }

  func testFailedRecordReturnsMessageAndCleansStaging() throws {
    let fixture = try recoveryFixture(.failed)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertEqual(MacUpdateRecovery.confirmStartup(version: "0.4.0", destination: fixture.destination,
      recordURL: fixture.record), "The previous update did not complete. aniCe kept the installed version.")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.record.path))
  }

  func testFailedRecordWithMissingStagingStillClearsRecord() throws {
    let fixture = try recoveryFixture(.failed)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try FileManager.default.removeItem(at: fixture.staging)
    XCTAssertNotNil(MacUpdateRecovery.confirmStartup(version: "0.4.0", destination: fixture.destination,
      recordURL: fixture.record))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.record.path))
  }
}
