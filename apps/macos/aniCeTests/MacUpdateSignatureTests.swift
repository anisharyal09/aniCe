// SPDX-License-Identifier: GPL-3.0-or-later
// Ensures the updater rejects unconfigured and incorrect signing identities.
import Foundation
import XCTest
@testable import aniCe

final class MacUpdateSignatureTests: XCTestCase {
  func testRequiresPinsAndRejectsWrongCertificate() {
    let bundle = Bundle.main.bundleURL
    XCTAssertThrowsError(try MacUpdateSignature.validate(bundle, identifier: "io.github.anisharyal09.anice", pins: []))
    XCTAssertThrowsError(try MacUpdateSignature.validate(bundle, identifier: "io.github.anisharyal09.anice", pins: [String(repeating: "0", count: 64)]))
    XCTAssertThrowsError(try MacUpdateSignature.validate(bundle, identifier: "wrong\"identifier", pins: [String(repeating: "0", count: 64)]))
  }

  func testPackagedHelperIsUniversalAndRejectsOtherFiles() throws {
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/aniCeUpdateHelper")
    try MacUpdateSignature.validateArchitectures(helper)
    XCTAssertThrowsError(try MacUpdateSignature.validateArchitectures(Bundle.main.bundleURL))
  }
}
