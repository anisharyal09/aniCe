// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies audio-sharing CBOR, PCM layout and timeline bounds against independent adversarial fixtures.
import Foundation
import XCTest
@testable import aniCe

final class AudioSharingWireTests: XCTestCase {
  private let streamID = "01234567-89ab-4cde-8fab-0123456789ab"

  private func fixtures() throws -> [String: Any] {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(
      forResource: "vectors", withExtension: "json"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }

  func testIndependentFixturesAndCanonicalBytes() throws {
    let root = try fixtures()
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])
    let unrecognized = try XCTUnwrap(root["unrecognized"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(valid.count, 45)
    XCTAssertGreaterThanOrEqual(invalid.count, 145)
    XCTAssertGreaterThanOrEqual(unrecognized.count, 3)
    var kinds = Set<Int64>()
    for row in valid {
      let bytes = try SessionFixtures().b(row, "bytes")
      let name = row["name"] as? String ?? ""
      let message = try XCTUnwrap(AudioSharingMessage.decode(bytes), name)
      XCTAssertEqual(message.kind, try XCTUnwrap(row["kind"] as? NSNumber).int64Value, name)
      XCTAssertEqual(try message.encode(), bytes, name)
      XCTAssertLessThanOrEqual(bytes.count, 4000, name)
      kinds.insert(message.kind)
    }
    XCTAssertEqual(kinds, Set(0...5))
    for row in invalid {
      let name = row["name"] as? String ?? ""
      XCTAssertThrowsError(try AudioSharingMessage.decode(SessionFixtures().b(row, "bytes")), name) {
        XCTAssertTrue($0 is AudioSharingWireError || $0 as? SessionFailure == .malformed, name)
      }
    }
    for row in unrecognized {
      XCTAssertNil(try AudioSharingMessage.decode(SessionFixtures().b(row, "bytes")),
        row["name"] as? String ?? "")
    }
  }

  func testIndependentPCMLayoutAndSlicedData() throws {
    let root = try fixtures()
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let row = try XCTUnwrap(valid.first { $0["name"] as? String == "audio-pcm16-stereo" })
    let encoded = try SessionFixtures().b(row, "bytes")
    var padded = Data(repeating: 0xaa, count: 7)
    padded.append(encoded)
    let message = try XCTUnwrap(AudioSharingMessage.decode(padded.dropFirst(7)))
    XCTAssertEqual(message.text(0), streamID)
    XCTAssertEqual(message.number(1), 1)
    XCTAssertEqual(message.number(2), 0)
    XCTAssertEqual(message.bytes(3).count, 3840)
    // Interleaved signed samples: [0,0], [32767,-32768], [-1,1], [12345,-12345].
    XCTAssertEqual(Array(message.bytes(3).prefix(16)),
      [0, 0, 0, 0, 255, 127, 0, 128, 255, 255, 1, 0, 57, 48, 199, 207])
    XCTAssertEqual(try message.encode(), encoded)
  }

  func testFactoriesPreserveTheFinalPacketEndAndSmallRecordBudget() throws {
    let maximum = AudioSharingMessage.maximumSequence
    let message = try AudioSharingMessage.audio(streamID: streamID, sequence: maximum,
      pcm: Data(repeating: 0, count: 3840))
    XCTAssertEqual(maximum, 9607679205057058)
    XCTAssertEqual(message.number(2), (maximum - 1) * 960)
    XCTAssertEqual(message.number(2) + 960, maximum * 960)
    XCTAssertLessThanOrEqual(message.number(2) + 960, Int64.max)
    XCTAssertEqual(try message.encode().count, 3927)
    for sequence in [Int64.min, -1, 0, maximum + 1, Int64.max] {
      XCTAssertThrowsError(try AudioSharingMessage.audio(streamID: streamID,
        sequence: sequence, pcm: Data(count: 3840))) {
        XCTAssertTrue($0 is AudioSharingWireError)
      }
    }
    for size in [0, 3839, 3841, 4000] {
      XCTAssertThrowsError(try AudioSharingMessage.audio(streamID: streamID,
        sequence: 1, pcm: Data(count: size)))
    }
    XCTAssertThrowsError(try AudioSharingMessage.start(streamID: streamID.uppercased()).encode())
    let start = AudioSharingMessage.start(streamID: UUID().uuidString.lowercased())
    XCTAssertEqual(try AudioSharingMessage.decode(start.encode()), start)
    let capability = AudioSharingMessage.capability(enabled: false)
    XCTAssertEqual(try AudioSharingMessage.decode(capability.encode()), capability)
  }

  func testEncodingRejectsInvalidLocallyConstructedShapes() throws {
    let bad = [
      AudioSharingMessage(kind: 3, fields: [.integer(1)]),
      AudioSharingMessage(kind: 3, fields: [.text(streamID), .integer(Int64.max),
        .integer(0), .bytes(Data(count: 3840))]),
      AudioSharingMessage(kind: 3, fields: [.text(streamID), .integer(2),
        .integer(961), .bytes(Data(count: 3840))]),
      AudioSharingMessage(kind: 0, fields: [.integer(48000), .integer(2),
        .integer(16), .integer(960), .integer(1)]),
      AudioSharingMessage(kind: 5, fields: [.text(streamID), .integer(0), .integer(2),
        .integer(1), .integer(960), .integer(0), .integer(1)]),
      AudioSharingMessage(kind: 5, fields: [.text(streamID), .integer(1), .integer(5),
        .integer(1), .integer(960), .integer(48001), .integer(0)]),
    ]
    for message in bad {
      XCTAssertThrowsError(try message.encode()) { XCTAssertTrue($0 is AudioSharingWireError) }
    }
  }
}
