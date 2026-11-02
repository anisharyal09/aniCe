// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies Phone-to-Mac input codecs against independent positive and negative fixtures.
import XCTest
@testable import aniCe

final class PhoneInputTests: XCTestCase {
  func testIndependentFixturesRoundTripAndRejectMalformedBounds() throws {
    let root = try SessionFixtures().root("phone-input-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])
    XCTAssertEqual(valid.count, 12)
    XCTAssertGreaterThanOrEqual(invalid.count, 29)

    for row in valid {
      let bytes = try SessionFixtures().b(row, "bytes")
      let message = try XCTUnwrap(PhoneInputMessage.decode(bytes))
      XCTAssertEqual(try message.encode(), bytes)
    }

    for row in invalid {
      XCTAssertThrowsError(
        try PhoneInputMessage.decode(SessionFixtures().b(row, "bytes")),
        row["name"] as? String ?? "")
    }
  }

  func testUnrelatedDataRemainsAvailableToOtherHandlers() throws {
    let bytes = try SessionCbor.encode(.array([.text("other feature")]))
    XCTAssertNil(try PhoneInputMessage.decode(bytes))
  }
}
