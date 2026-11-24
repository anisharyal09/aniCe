// SPDX-License-Identifier: GPL-3.0-or-later
// Tests reverse audio envelopes against independent fixtures without starting native playback.
import Foundation
import XCTest
@testable import aniCe

final class PhoneAudioWireTests: XCTestCase {
  func testReverseTagDoesNotAuthorizeTheExistingListeningDirection() throws {
    let original = try PrivateListeningMessage.audio(
      streamID: "01234567-89ab-4cde-8fab-0123456789ab", sequence: 1, pcm: Data(count: 3840))
    let reverse = PhoneAudioMessage(kind: original.kind, fields: original.fields)
    XCTAssertNil(try PrivateListeningMessage.decode(reverse.encode()))
    XCTAssertNil(try PhoneAudioMessage.decode(original.encode()))
    XCTAssertEqual(try PhoneAudioMessage.decode(reverse.encode()), reverse)
    XCTAssertThrowsError(try PhoneAudioMessage(kind: 5, fields: []).encode())
  }

  func testMalformedPcmAndOverflowRemainRejected() {
    let id = "01234567-89ab-4cde-8fab-0123456789ab"
    XCTAssertThrowsError(try PhoneAudioMessage(kind: 3, fields: [
      .text(id), .integer(1), .integer(0), .bytes(Data(count: 3839))]).encode())
    XCTAssertThrowsError(try PhoneAudioMessage(kind: 3, fields: [
      .text(id), .integer(Int64.max), .integer(0), .bytes(Data(count: 3840))]).encode())
  }

  func testIndependentFixturesStayCanonicalAndIsolateTheReverseTag() throws {
    let root = try fixtures("phone-audio-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])
    let unrecognized = try XCTUnwrap(root["unrecognized"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(valid.count, 35)
    XCTAssertGreaterThanOrEqual(invalid.count, 100)
    XCTAssertGreaterThanOrEqual(unrecognized.count, 4)
    var kinds = Set<Int64>()
    for row in valid {
      let name = row["name"] as? String ?? ""
      let encoded = try SessionFixtures().b(row, "bytes")
      let message = try XCTUnwrap(PhoneAudioMessage.decode(encoded), name)
      XCTAssertEqual(message.kind, try XCTUnwrap(row["kind"] as? NSNumber).int64Value, name)
      XCTAssertEqual(try message.encode(), encoded, name)
      XCTAssertLessThanOrEqual(encoded.count, 4000, name)
      kinds.insert(message.kind)
    }
    XCTAssertEqual(kinds, Set(0...4))
    for row in invalid {
      let name = row["name"] as? String ?? ""
      XCTAssertThrowsError(try PhoneAudioMessage.decode(SessionFixtures().b(row, "bytes")), name) {
        XCTAssertTrue($0 is PrivateListeningWireError || $0 as? SessionFailure == .malformed, name)
      }
    }
    for row in unrecognized {
      let name = row["name"] as? String ?? ""
      XCTAssertNil(try PhoneAudioMessage.decode(SessionFixtures().b(row, "bytes")), name)
    }
  }

  private func fixtures(_ name: String) throws -> [String: Any] {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(
      forResource: name, withExtension: "json"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }
}
