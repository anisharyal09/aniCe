// SPDX-License-Identifier: GPL-3.0-or-later
// Checks install eligibility, atomic swap support and readable failure messages.
import XCTest
@testable import aniCe

final class MacUpdateInstallTests: XCTestCase {
  func testTranslocatedAndUnsignedBuildsCannotInstall() {
    let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/A1/aniCe.app")
    XCTAssertEqual(MacUpdateInstall.problem(destination: translocated),
      MacAppStorage.isPreview ? MacUpdateInstall.Error.previewBuild.localizedDescription :
        "Move aniCe to Applications before installing an update.")
    if MacUpdateInstall.pins() == nil {
      XCTAssertNotNil(MacUpdateInstall.problem(destination: FileManager.default.temporaryDirectory
        .appendingPathComponent("aniCe.app")))
    }
  }

  func testAtomicSwapSupportLeavesNoProbeFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    XCTAssertTrue(MacUpdateInstall.supportsAtomicSwap(in: directory))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
  }

  func testUpdateFailuresExplainRecoveryInsteadOfErrorCodes() {
    let failures: [Swift.Error] = [
      MacUpdateInstall.Error.pinsUnavailable, MacUpdateInstall.Error.unsupportedLocation,
      MacUpdateInstall.Error.unsupportedVolume, MacUpdateInstall.Error.helperMissing,
      MacUpdateInstall.Error.launchFailed, MacUpdateInstall.Error.previewBuild,
      MacUpdateStaging.Error.invalidDownload, MacUpdateStaging.Error.invalidBundle,
      MacUpdateStaging.Error.extractionFailed, MacUpdateStaging.Error.stagingUnavailable,
      MacUpdateArchive.Error.invalid("test"), MacUpdateSignature.Error.invalidConfiguration,
      MacUpdateSignature.Error.invalidArchitecture,
      MacUpdateSignature.Error.invalidCode(-1), MacUpdateSignature.Error.wrongCertificate,
    ]
    XCTAssertEqual(failures.count, 15)
    for failure in failures {
      XCTAssertFalse(failure.localizedDescription.contains("couldn’t be completed"))
      XCTAssertFalse(failure.localizedDescription.isEmpty)
    }
  }
}
