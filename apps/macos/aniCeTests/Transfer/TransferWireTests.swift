// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies independent transfer wire fixtures, canonical encoding and strict boundary enforcement.
import Foundation
import XCTest
@testable import aniCe

final class TransferWireTests: XCTestCase {
  func testIndependentFixturesCanonicalEncodingAndNegativeInventory() throws {
    let helper = SessionFixtures()
    let root = try helper.root("transfer-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])

    XCTAssertGreaterThanOrEqual(valid.count, 12, "Valid inventory floor failed")
    XCTAssertGreaterThanOrEqual(invalid.count, 20, "Invalid inventory floor failed")

    for row in valid {
      let bytes = try helper.b(row, "bytes")
      let message = try XCTUnwrap(TransferMessage.decode(bytes), "Failed to decode \(row["name"] ?? "")")
      XCTAssertEqual(message.kind, (row["kind"] as? NSNumber)?.int64Value)
      XCTAssertEqual(try message.encode(), bytes)
    }

    for row in invalid {
      let bytes = try helper.b(row, "bytes")
      XCTAssertThrowsError(try TransferMessage.decode(bytes), row["name"] as? String ?? "")
    }
  }
}
