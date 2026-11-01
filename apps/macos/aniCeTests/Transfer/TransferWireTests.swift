// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies independent transfer wire fixtures, canonical encoding and strict boundary enforcement.
import Foundation
import XCTest
import CryptoKit
@testable import aniCe

final class TransferWireTests: XCTestCase {
  func test512ChunkRequiresCapability4AndRejectsLegacyBudget() throws {
    let batch = UUID().uuidString, file = UUID().uuidString
    let chunk = TransferMessage.chunk(batch: batch, file: file, offset: 0, data: Data(repeating: 7, count: 524288))
    let encoded = try chunk.encode(maximumChunkBytes: 524288)
    XCTAssertLessThanOrEqual(encoded.count, 524416)
    XCTAssertEqual(try TransferMessage.decode(encoded, maximumChunkBytes: 524288)?.bytes(3).count, 524288)
    XCTAssertThrowsError(try TransferMessage.decode(encoded, maximumChunkBytes: 262016))
    XCTAssertThrowsError(try TransferMessage.capability(version: 3, maxChunkBytes: 524288, maxWindow: 8).encode(maximumChunkBytes: 524288))
    XCTAssertNoThrow(try TransferMessage.capability(version: 4, maxChunkBytes: 524288, maxWindow: 8).encode(maximumChunkBytes: 524288))
    let key = Data(0..<32), iv = Data(0..<12), id = Data(32..<64)
    let plain = Data((0..<524416).map { UInt8($0 % 251) })
    let record = try SessionRecordCodec.seal(key: key, iv: iv, id: id, direction: 1, kind: .data, sequence: 0, plaintext: plain, profile: .lanTransfer512)
    XCTAssertEqual(SHA256.hash(data: record).map { String(format: "%02x", $0) }.joined(), "f2a4082a1560c2724d92707557f435e4a81ce5d20350f1cfe91a50507e4fa7ed")
    XCTAssertThrowsError(try SessionRecordCodec.open(key: key, iv: iv, id: id, direction: 1, expected: 0, record: record, profile: .lanTransfer))
  }
  func testLargeChunksRequireExplicitLanBudget() throws {
    let batch = UUID().uuidString, file = UUID().uuidString
    let message = TransferMessage.chunk(batch: batch, file: file, offset: 0, data: Data(repeating: 7, count: 262016))
    XCTAssertThrowsError(try message.encode())
    let encoded = try message.encode(maximumChunkBytes: 262016)
    XCTAssertNil(try SessionControl.application(encoded, maximumBytes: 262144))
    XCTAssertEqual(try TransferMessage.decode(encoded, maximumChunkBytes: 262016)?.bytes(3).count, 262016)
    XCTAssertThrowsError(try TransferMessage.decode(encoded))
    XCTAssertThrowsError(try TransferMessage.chunk(batch: batch, file: file, offset: 0, data: Data(repeating: 0, count: 262017)).encode(maximumChunkBytes: 262016))
    let capability = try TransferMessage.capability(version: 3, maxChunkBytes: 262016, maxWindow: 8).encode(maximumChunkBytes: 262016)
    XCTAssertThrowsError(try TransferMessage.decode(capability))
    XCTAssertThrowsError(try TransferMessage.capability(version: 3, maxChunkBytes: 262016, maxWindow: 9).encode(maximumChunkBytes: 262016))
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
