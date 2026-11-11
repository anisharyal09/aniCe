// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies release tag bounds and prerelease ordering.
import XCTest
@testable import aniCe

final class UpdateVersionTests: XCTestCase {
  func testPrereleasesSortBeforeFinalRelease() throws {
    let tags = ["v0.4.0-alpha.1", "v0.4.0-alpha.19", "v0.4.0-beta.1", "v0.4.0-beta.19", "v0.4.0-rc.1", "v0.4.0-rc.19", "v0.4.0", "v0.4.1-alpha.1"]
    let versions = try tags.map { try XCTUnwrap(UpdateVersion.parse($0)) }
    XCTAssertEqual(versions, versions.sorted())
    XCTAssertEqual(UpdateVersion.parse("v0.4.0-beta.1")?.code, 40021)
    XCTAssertEqual(UpdateVersion.parse("v0.4.0")?.code, 40099)
  }

  func testRejectsInvalidTags() {
    for tag in ["0.4.0", "v01.0.0", "v0.100.0", "v0.0.100", "v2001.0.0", "v0.0.1-beta.0", "v0.0.1-alpha.20", "v0.0.1-rc", "v0.0.1+build", "v0.0.1\n"] {
      XCTAssertNil(UpdateVersion.parse(tag), tag)
    }
  }
}
