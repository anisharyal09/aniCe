// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies independent transfer wire fixtures, canonical encoding and strict boundary enforcement.
import Foundation
import XCTest
@testable import aniCe

final class TransferWireTests: XCTestCase {
  func testLargeChunksRequireExplicitLanBudget() throws {
    let batch = UUID().uuidString, file = UUID().uuidString
    let message = TransferMessage.chunk(batch: batch, file: file, offset: 0, data: Data(repeating: 7, count: 131072))
    XCTAssertThrowsError(try message.encode())
    let encoded = try message.encode(maximumChunkBytes: 131072)
    XCTAssertNil(try SessionControl.application(encoded, maximumBytes: 262144))
    XCTAssertEqual(try TransferMessage.decode(encoded, maximumChunkBytes: 131072)?.bytes(3).count, 131072)
    XCTAssertThrowsError(try TransferMessage.decode(encoded))
    XCTAssertThrowsError(try TransferMessage.chunk(batch: batch, file: file, offset: 0, data: Data(repeating: 0, count: 131073)).encode(maximumChunkBytes: 131072))
    let capability = try TransferMessage.capability(version: 2, maxChunkBytes: 131072, maxWindow: 8).encode(maximumChunkBytes: 131072)
    XCTAssertThrowsError(try TransferMessage.decode(capability))
    XCTAssertThrowsError(try TransferMessage.capability(version: 2, maxChunkBytes: 131072, maxWindow: 9).encode(maximumChunkBytes: 131072))
    XCTAssertThrowsError(try SessionCbor.decode(encoded))
  }

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
