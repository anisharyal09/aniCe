// SPDX-License-Identifier: GPL-3.0-or-later
// Probes shared SMS relay fixtures and strict canonical validation.
import XCTest
import CryptoKit
@testable import aniCe

final class SmsWireTests: XCTestCase {
  private func request() -> String { UUID().uuidString.lowercased() }
  private func stream() -> String { UUID().uuidString.lowercased() }
  private func digest(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }

  func testSharedFixturesStayCanonicalWithinInventoryFloors() throws {
    let root = try SessionFixtures().root("sms-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(valid.count, 42); XCTAssertGreaterThanOrEqual(invalid.count, 70)
    var kinds = Set<Int64>()
    for row in valid {
      let bytes = try SessionFixtures().b(row, "bytes")
      let message = try XCTUnwrap(SmsMessage.decode(bytes), row["name"] as? String ?? "")
      XCTAssertEqual(try message.encode(), bytes)
      XCTAssertEqual(row["kind"] as? Int64, message.kind)
      kinds.insert(message.kind)
    }
    XCTAssertEqual(kinds, Set(1...14))
    for row in invalid {
      let name = row["name"] as? String ?? ""
      let bytes = try SessionFixtures().b(row, "bytes")
      if name == "wrong-tag" {
        XCTAssertNil(try SmsMessage.decode(bytes), name)
        continue
      }
      XCTAssertThrowsError(try SmsMessage.decode(bytes), name)
    }
    XCTAssertNil(try SmsMessage.decode(SessionCbor.encode(.array([.text("aniCe other"), .integer(1)]))))
    XCTAssertNil(try SmsMessage.decode(Data(repeating: 0x61, count: 4001)))
  }

  func testEveryKindRoundTripsAtDocumentedBounds() throws {
    let id = request(), stream = stream()
    let rows: [SmsMessage] = [
      SmsMessage(kind: 1, fields: [.integer(24576), .integer(8), .integer(50), .integer(50)]),
      SmsMessage(kind: 2, fields: [.text(id)]),
      SmsMessage(kind: 3, fields: [.text(id), .text("42"), .text("+15551234567"), .text(String(repeating: "s", count: 160)), .integer(9007199254740991), .integer(0)]),
      SmsMessage(kind: 4, fields: [.text(id), .integer(6)]),
      SmsMessage(kind: 5, fields: [.text(id), .text("addr:+15551234567"), .integer(9007199254740991), .text("live:" + String(repeating: "a", count: 32)), .integer(50)]),
      SmsMessage(kind: 6, fields: [.text(stream), .text(""), .text("live:" + String(repeating: "b", count: 32)), .text("42"), .text("+15551234567"), .integer(0), .integer(1), .bool(true), .integer(24576), .integer(8), .bytes(digest("x"))]),
      SmsMessage(kind: 7, fields: [.text(stream), .integer(7), .bytes(Data(repeating: 0, count: 3072))]),
      SmsMessage(kind: 8, fields: [.text(stream)]),
      SmsMessage(kind: 9, fields: [.text(stream), .integer(0)]),
      SmsMessage(kind: 10, fields: [.text(id), .integer(0), .integer(0), .text("")]),
      SmsMessage(kind: 11, fields: [.text(id), .text("42"), .text("+15551234567"), .integer(24576), .integer(8), .bytes(digest("x"))]),
      SmsMessage(kind: 12, fields: [.text(id), .integer(0), .bytes(Data([1]))]),
      SmsMessage(kind: 13, fields: [.text(id)]),
      SmsMessage(kind: 14, fields: [.text(id), .integer(0), .text("sms:9"), .integer(9007199254740991)]),
    ]
    for row in rows {
      let bytes = try row.encode()
      XCTAssertEqual(try SmsMessage.decode(bytes)?.encode(), bytes)
    }
    XCTAssertEqual(Set(rows.map(\.kind)), Set(1...14))
  }

  func testStrictValidationRejectsSemanticViolations() throws {
    func rejected(_ name: String, _ row: SmsMessage) {
      XCTAssertThrowsError(try row.encode(), name)
    }
    let id = request(), stream = stream(), hash = digest("x")
    rejected("unknown-kind", SmsMessage(kind: 15, fields: []))
    rejected("capability-floor", SmsMessage(kind: 1, fields: [.integer(24575), .integer(8), .integer(50), .integer(50)]))
    rejected("request-empty", SmsMessage(kind: 2, fields: [.text("")]))
    rejected("request-uppercase", SmsMessage(kind: 2, fields: [.text(id.uppercased())]))
    rejected("thread-empty", SmsMessage(kind: 3, fields: [.text(id), .text(""), .text("+1"), .text(""), .integer(0), .integer(0)]))
    rejected("address-long", SmsMessage(kind: 3, fields: [.text(id), .text("1"), .text(String(repeating: "a", count: 65)), .text(""), .integer(0), .integer(0)]))
    rejected("snippet-long", SmsMessage(kind: 3, fields: [.text(id), .text("1"), .text("+1"), .text(String(repeating: "s", count: 161)), .integer(0), .integer(0)]))
    rejected("result-out-of-range", SmsMessage(kind: 4, fields: [.text(id), .integer(7)]))
    rejected("limit-zero", SmsMessage(kind: 5, fields: [.text(id), .text("1"), .integer(0), .text(""), .integer(0)]))
    rejected("cursor-bogus", SmsMessage(kind: 5, fields: [.text(id), .text("1"), .integer(0), .text("bogus"), .integer(1)]))
    rejected("live-short-hex", SmsMessage(kind: 6, fields: [.text(stream), .text(""), .text("live:abc"), .text("42"), .text("+1"), .integer(0), .integer(0), .bool(false), .integer(1), .integer(1), .bytes(hash)]))
    rejected("live-uppercase-hex", SmsMessage(kind: 6, fields: [.text(stream), .text(""), .text("live:" + String(repeating: "A", count: 32)), .text("42"), .text("+1"), .integer(0), .integer(0), .bool(false), .integer(1), .integer(1), .bytes(hash)]))
    rejected("provider-id-too-long", SmsMessage(kind: 6, fields: [.text(stream), .text(""), .text("sms:" + String(repeating: "9", count: 20)), .text("42"), .text("+1"), .integer(0), .integer(0), .bool(false), .integer(1), .integer(1), .bytes(hash)]))
    rejected("provider-empty-digits", SmsMessage(kind: 6, fields: [.text(stream), .text(""), .text("sms:"), .text("42"), .text("+1"), .integer(0), .integer(0), .bool(false), .integer(1), .integer(1), .bytes(hash)]))
    rejected("message-id-prefix", SmsMessage(kind: 6, fields: [.text(stream), .text(""), .text("SMS:1"), .text("42"), .text("+1"), .integer(0), .integer(0), .bool(false), .integer(1), .integer(1), .bytes(hash)]))
    rejected("date-above-range", SmsMessage(kind: 6, fields: [.text(stream), .text(""), .text("sms:1"), .text("42"), .text("+1"), .integer(9007199254740992), .integer(0), .bool(false), .integer(1), .integer(1), .bytes(hash)]))
    rejected("direction-range", SmsMessage(kind: 6, fields: [.text(stream), .text(""), .text("sms:1"), .text("42"), .text("+1"), .integer(0), .integer(2), .bool(false), .integer(1), .integer(1), .bytes(hash)]))
    rejected("unread-not-bool", SmsMessage(kind: 6, fields: [.text(stream), .text(""), .text("sms:1"), .text("42"), .text("+1"), .integer(0), .integer(0), .integer(1), .integer(1), .integer(1), .bytes(hash)]))
    rejected("body-over-limit", SmsMessage(kind: 6, fields: [.text(stream), .text(""), .text("sms:1"), .text("42"), .text("+1"), .integer(0), .integer(0), .bool(false), .integer(24577), .integer(9), .bytes(hash)]))
    rejected("body-count-mismatch", SmsMessage(kind: 6, fields: [.text(stream), .text(""), .text("sms:1"), .text("42"), .text("+1"), .integer(0), .integer(0), .bool(false), .integer(6144), .integer(3), .bytes(hash)]))
    rejected("fragment-index-ceiling", SmsMessage(kind: 7, fields: [.text(stream), .integer(8), .bytes(Data([1]))]))
    rejected("fragment-empty", SmsMessage(kind: 7, fields: [.text(stream), .integer(0), .bytes(Data())]))
    rejected("fragment-oversize", SmsMessage(kind: 7, fields: [.text(stream), .integer(0), .bytes(Data(repeating: 1, count: 3073))]))
    rejected("begin-fields-truncated", SmsMessage(kind: 6, fields: [.text(stream), .text(""), .text("sms:1")]))
    rejected("send-begin-digest", SmsMessage(kind: 11, fields: [.text(id), .text("1"), .text("+1"), .integer(1), .integer(1), .bytes(Data([1]))]))
    rejected("send-result-id-with-code", SmsMessage(kind: 14, fields: [.text(id), .integer(5), .text("sms:1"), .integer(0)]))
    // A successful send without a provider lookup keeps an empty id; that is valid.
    XCTAssertNoThrow(try SmsMessage(kind: 14, fields: [.text(id), .integer(0), .text(""), .integer(1)]).encode())
    XCTAssertNoThrow(try SmsMessage(kind: 10, fields: [.text(id), .integer(0), .integer(0), .text("")]).encode())
  }

  func testMessageIdentifiersCompareByteWiseNotNumerically() {
    XCTAssertGreaterThan(smsCompareMessageIds("sms:99", "sms:100"), 0)
    XCTAssertLessThan(smsCompareMessageIds("live:" + String(repeating: "a", count: 32), "sms:9"), 0)
    XCTAssertEqual(smsCompareMessageIds("sms:7", "sms:7"), 0)
    XCTAssertLessThan(smsCompareMessageIds("sms:9", "sms:9a"), 0)
    XCTAssertTrue(SmsMessage.isMessageId("mms:9007199254740991"))
    XCTAssertTrue(SmsMessage.isMessageId("mms:90071992547409911"))
    XCTAssertFalse(SmsMessage.isMessageId("sms:" + String(repeating: "9", count: 20)))
    XCTAssertFalse(SmsMessage.isMessageId("sms:-1"))
    XCTAssertFalse(SmsMessage.isMessageId("live:" + String(repeating: "g", count: 32)))
  }

  func testAddressNormalizationAndClampingMatchTheContract() {
    XCTAssertEqual(smsNormalizedAddress("+1 (555) 123-4567"), "+15551234567")
    XCTAssertEqual(smsNormalizedAddress("  +44 20 7946 0958"), "+442079460958")
    XCTAssertEqual(smsNormalizedAddress("555-0100"), "5550100")
    XCTAssertEqual(smsNormalizedAddress("+"), "")
    XCTAssertEqual(smsNormalizedAddress(""), "")
    XCTAssertEqual(smsClampDate(-5), 0)
    XCTAssertEqual(smsClampDate(SmsMessage.maxDate + 1), SmsMessage.maxDate)
    XCTAssertEqual(smsSanitizeText("a\u{0}b"), "a\u{FFFD}b")
    XCTAssertEqual(smsTruncate(String(repeating: "a", count: 10), maxBytes: 4), "aaaa")
    XCTAssertEqual(smsTruncate(String(repeating: "é", count: 10), maxBytes: 5), "éé")
    XCTAssertEqual(smsTruncate(String(repeating: "😀", count: 10), maxBytes: 7), "😀")
    XCTAssertEqual(smsTruncate("short", maxBytes: 99), "short")
  }
}
