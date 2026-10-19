// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises capability gating, live assembly, provider paging, reply delivery and data lifetime.
import XCTest
import CryptoKit
@testable import aniCe

@MainActor final class SmsNotifierSpy: SmsNotifying {
  var notes: [SmsNotification] = []
  var outcome: SmsPostOutcome = .submitted
  var pause: CheckedContinuation<SmsPostOutcome, Never>?
  var suspendPost = false
  func post(_ note: SmsNotification) async -> SmsPostOutcome {
    notes.append(note)
    if suspendPost { return await withCheckedContinuation { pause = $0 } }
    return outcome
  }
}

@MainActor final class SmsClock {
  var time: TimeInterval = 0
  func advance(_ seconds: TimeInterval) { time += seconds }
}

@MainActor
final class SmsModelTests: XCTestCase {
  private func make(_ spy: SmsNotifierSpy, _ clock: SmsClock) -> MacSmsModel {
    MacSmsModel(notifier: spy, now: { clock.time }, wait: { _ in throw CancellationError() })
  }

  private func capability() throws -> Data {
    try SmsMessage(kind: 1, fields: [.integer(24576), .integer(8), .integer(50), .integer(50)]).encode()
  }

  private func records(_ kind: Int64, _ fields: [SessionCBOR]) throws -> Data {
    try SmsMessage(kind: kind, fields: fields).encode()
  }

  private func until(_ label: String, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(2)
    while !condition() && Date() < deadline {
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertTrue(condition(), "timed out waiting for \(label)")
  }

  private func sent(_ channel: MockSecuredChannel, _ kind: Int64) -> [SmsMessage] {
    (try? channel.sentData.compactMap { try SmsMessage.decode($0) }.filter { $0.kind == kind }) ?? []
  }

  private func lastSent(_ channel: MockSecuredChannel, _ kind: Int64) throws -> SmsMessage? {
    try channel.sentData.compactMap { try SmsMessage.decode($0) }.last { $0.kind == kind }
  }

  private func handle(_ model: MacSmsModel, _ bytes: Data, _ channel: MockSecuredChannel) async -> DataHandling {
    await model.handle(bytes, on: channel.descriptor)
  }

  private func expect(_ expected: DataHandling, _ bytes: Data, _ channel: MockSecuredChannel, _ model: MacSmsModel) async {
    let result = await model.handle(bytes, on: channel.descriptor)
    XCTAssertEqual(result, expected)
  }

  @discardableResult
  private func ready(_ model: MacSmsModel, _ channel: MockSecuredChannel) async throws -> DeviceIdentity {
    model.available(channel)
    let handled = await model.handle(try capability(), on: channel.descriptor)
    XCTAssertEqual(handled, .handled)
    await until("capability") { model.supports(channel.descriptor.peer) }
    return channel.descriptor.peer
  }

  private func stream(_ streamId: String, requestId: String = "", messageId: String, threadId: String = "sms:42",
    address: String = "+15551234567", dateMillis: Int64 = 1_700_000_000_000, direction: Int64 = 0,
    unread: Bool = false, body: String, corruptDigest: Bool = false) throws -> (begin: Data, fragments: [Data], commit: Data) {
    let data = Data(body.utf8)
    let count = (data.count + 3071) / 3072
    let digest = corruptDigest ? Data(repeating: 0, count: 32) : Data(SHA256.hash(data: data))
    let begin = try records(6, [.text(streamId), .text(requestId), .text(messageId), .text(threadId), .text(address),
      .integer(dateMillis), .integer(direction), .bool(unread), .integer(Int64(data.count)), .integer(Int64(count)), .bytes(digest)])
    let fragments = try (0..<count).map { index -> Data in
      let start = index * 3072
      return try records(7, [.text(streamId), .integer(Int64(index)),
        .bytes(data.subdata(in: start..<min(start + 3072, data.count)))])
    }
    return (begin, fragments, try records(8, [.text(streamId)]))
  }

  private func deliver(_ model: MacSmsModel, _ channel: MockSecuredChannel,
    _ parts: [Data], expected: DataHandling = .handled) async {
    for part in parts {
      let result = await model.handle(part, on: channel.descriptor)
      XCTAssertEqual(result, expected)
    }
  }

  private func key(_ peer: DeviceIdentity) -> String { peer.deviceId + ":" + peer.fingerprint }

  private func lastResult(_ channel: MockSecuredChannel) -> Int64? { (try? lastSent(channel, 9))??.number(1) }

  // MARK: - Gates, capability and dispatch

  @MainActor func testCapabilityGateAndUnrecognizedKinds() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    model.available(channel)
    await until("advertised capability") { self.sent(channel, 1).count == 1 }
    let advertised = try XCTUnwrap(try lastSent(channel, 1))
    XCTAssertEqual(advertised.number(0), 24576); XCTAssertEqual(advertised.number(1), 8)
    XCTAssertEqual(advertised.number(2), 50); XCTAssertEqual(advertised.number(3), 50)
    XCTAssertFalse(model.supports(channel.descriptor.peer))
    let gated = await model.handle(try records(3, [.text(UUID().uuidString.lowercased()), .text("42"),
      .text("+15551234567"), .text("hi"), .integer(0), .integer(0)]), on: channel.descriptor)
    XCTAssertEqual(gated, .discarded)
    _ = try await ready(model, channel)
    await expect(.discarded, Data("nonsense".utf8), channel, model)
    let wrongTag = try SessionCbor.encode(.array([.text("aniCe other"), .integer(1), .integer(3), .array([])]))
    await expect(.unrecognized, wrongTag, channel, model)
    await expect(.unrecognized, try records(2, [.text(UUID().uuidString.lowercased())]), channel, model)
    await expect(.unrecognized, try records(5, [.text(UUID().uuidString.lowercased()), .text("1"),
      .integer(0), .text(""), .integer(50)]), channel, model)
    await expect(.unrecognized, try records(9, [.text(UUID().uuidString.lowercased()), .integer(0)]), channel, model)
    await expect(.unrecognized, try records(12, [.text(UUID().uuidString.lowercased()), .integer(0),
      .bytes(Data([1]))]), channel, model)
    await expect(.unrecognized, try records(13, [.text(UUID().uuidString.lowercased())]), channel, model)
    await expect(.unrecognized, Data(repeating: 0x61, count: 4001), channel, model)
    let stale = MockSecuredChannel(instance: "stale", transport: "lan", peer: channel.descriptor.peer)
    await expect(.discarded, try capability(), stale, model)
    XCTAssertFalse(model.connected(MockSecuredChannel().descriptor.peer))
    XCTAssertTrue(spy.notes.isEmpty)
  }

  @MainActor func testCapabilityRecordIsAnsweredSoAPhoneThatMissedOurHelloRecovers() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    model.available(channel)
    await until("advertised capability") { !sent(channel, 1).isEmpty }
    // The phone re-advertises because it never saw our capability: answer it on that link, so a hello
    // lost in transit costs a retry instead of parking live messages until the channel is rebuilt.
    let answered = await model.handle(try capability(), on: channel.descriptor)
    XCTAssertEqual(answered, .handled)
    await until("capability answered") { sent(channel, 1).count == 2 }
    let hello = try XCTUnwrap(try lastSent(channel, 1))
    XCTAssertEqual(hello.number(0), 24576); XCTAssertEqual(hello.number(1), 8)
    XCTAssertEqual(hello.number(2), 50); XCTAssertEqual(hello.number(3), 50)
    XCTAssertTrue(model.supports(channel.descriptor.peer))
    XCTAssertTrue(spy.notes.isEmpty)
  }

  // MARK: - Live assembly and dedupe

  @MainActor func testLiveMessageIsAcknowledgedOnceNotifiedOnceAndDeduped() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    XCTAssertTrue(model.connected(peer)); XCTAssertTrue(model.supports(peer))
    let liveId = "live:" + String(repeating: "b", count: 32)
    let streamId = UUID().uuidString.lowercased()
    let parts = try stream(streamId, messageId: liveId, unread: true, body: "Dinner at 8?")
    await deliver(model, channel, [parts.begin] + parts.fragments + [parts.commit])
    await until("live acknowledgement") { self.sent(channel, 9).count == 1 }
    let ack = try XCTUnwrap(try lastSent(channel, 9))
    XCTAssertEqual(ack.text(0), streamId); XCTAssertEqual(ack.number(1), 0)
    XCTAssertEqual(spy.notes.count, 1)
    XCTAssertEqual(spy.notes[0].identifier, smsNotificationPrefix + liveId)
    XCTAssertEqual(spy.notes[0].address, "+15551234567")
    XCTAssertEqual(spy.notes[0].threadIdentifier, "+15551234567")
    XCTAssertFalse(spy.notes[0].failure)
    XCTAssertEqual(model.messages(peer, address: "+15551234567").map(\.messageId), [liveId])
    XCTAssertEqual(model.threads(peer).count, 1)
    XCTAssertEqual(model.threads(peer)[0].unreadCount, 1)
    XCTAssertEqual(model.threads(peer)[0].snippet, "Dinner at 8?")
    // The one-retry-on-the-other-channel rule re-sends the same stream: acknowledge again, never duplicate or re-notify.
    await deliver(model, channel, [parts.begin] + parts.fragments + [parts.commit])
    await until("retry acknowledgement") { self.sent(channel, 9).count == 2 }
    XCTAssertEqual(spy.notes.count, 1)
    XCTAssertEqual(model.messages(peer, address: "+15551234567").count, 1)
    // A different message id carrying identical content inside the merge tolerance is the same message.
    let other = try stream(UUID().uuidString.lowercased(), messageId: "sms:1", body: "Dinner at 8?")
    await deliver(model, channel, [other.begin] + other.fragments + [other.commit])
    await until("content duplicate acknowledgement") { self.sent(channel, 9).count == 3 }
    XCTAssertEqual(try lastSent(channel, 9)?.number(1), 0)
    XCTAssertEqual(spy.notes.count, 1)
    XCTAssertEqual(model.messages(peer, address: "+15551234567").count, 1)
    let line = model.diagnostics(peer)
    XCTAssertTrue(line.contains("Local network"), line)
    XCTAssertTrue(line.contains("3 live received"), line)
    XCTAssertTrue(line.contains("1 Submitted to macOS"), line)
    XCTAssertTrue(line.contains("2 already seen"), line)
  }

  @MainActor func testBluetoothLinksAdvertiseSmallerCapsAndWaitLonger() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "ble")
    let peer = try await ready(model, channel)
    await until("advertised capability") { !sent(channel, 1).isEmpty }
    let advertised = try XCTUnwrap(sent(channel, 1).first)
    XCTAssertEqual(advertised.number(2), 20); XCTAssertEqual(advertised.number(3), 10)
    let line = model.diagnostics(peer)
    XCTAssertTrue(line.contains("Bluetooth"), line)
    model.refreshMessages(peer, address: "+15551234567")
    await until("history request") { self.sent(channel, 5).count == 1 }
    let request = try XCTUnwrap(try lastSent(channel, 5))
    // Every conversation opens at the 10-row first page; the panel offers older pages from its cursor.
    XCTAssertEqual(request.number(4), 10)
    // A Bluetooth page keeps its 60-second deadline where the local-network 30-second one would have expired.
    clock.advance(31)
    model.expire()
    XCTAssertNotEqual(model.status(peer), "Your phone did not answer")
    clock.advance(30)
    model.expire()
    XCTAssertEqual(model.status(peer), "Your phone did not answer")
  }

  @MainActor func testUnreadCountsNeverDecreaseAndAddressesNormalize() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    let first = try stream(UUID().uuidString.lowercased(), messageId: "sms:2", address: "+1 (555) 123-4567",
      dateMillis: 200, unread: true, body: "one")
    await deliver(model, channel, [first.begin] + first.fragments + [first.commit])
    await until("first live") { model.messages(peer, address: "+15551234567").count == 1 }
    let second = try stream(UUID().uuidString.lowercased(), messageId: "sms:3", address: "+15551234567",
      dateMillis: 100, unread: true, body: "two")
    await deliver(model, channel, [second.begin] + second.fragments + [second.commit])
    await until("second live") { model.messages(peer, address: "+15551234567").count == 2 }
    let cards = model.threads(peer)
    XCTAssertEqual(cards.count, 1)
    XCTAssertEqual(cards[0].key, "+15551234567")
    XCTAssertEqual(cards[0].dateMillis, 200)
    XCTAssertEqual(cards[0].unreadCount, 2)
    XCTAssertEqual(cards[0].snippet, "one")
    XCTAssertEqual(model.messages(peer, address: "+15551234567").map(\.messageId), ["sms:2", "sms:3"])
    // Re-read messages never decrement the unread count even when the provider copy arrives later.
    XCTAssertEqual(spy.notes.count, 2)
  }

  // Alphanumeric sender IDs (banks, alerts, service senders) are first-class conversations.
  @MainActor func testAlphanumericSenderIDsKeepTheirOwnConversationsRowsAndNotifications() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    XCTAssertEqual(smsNormalizedAddress(" acme bank "), "ACME BANK")
    XCTAssertEqual(smsNormalizedAddress("ACME BANK"), "ACME BANK")
    XCTAssertEqual(smsNormalizedAddress("+1 (555) 123-4567"), "+15551234567")
    XCTAssertNotEqual(smsNormalizedAddress("ACME BANK"), smsNormalizedAddress("AUTH XYZ"))
    let firstId = "live:" + String(repeating: "c", count: 32)
    let parts = try stream(UUID().uuidString.lowercased(), messageId: firstId, address: "ACME BANK", unread: true, body: "Your OTP is 42")
    await deliver(model, channel, [parts.begin] + parts.fragments + [parts.commit])
    await until("sender acknowledgement") { self.sent(channel, 9).count == 1 }
    XCTAssertEqual(model.threads(peer).map(\.address), ["ACME BANK"])
    XCTAssertEqual(model.threads(peer)[0].unreadCount, 1)
    XCTAssertEqual(model.threads(peer)[0].snippet, "Your OTP is 42")
    XCTAssertEqual(spy.notes.map(\.address), ["ACME BANK"])
    XCTAssertEqual(spy.notes[0].threadIdentifier, "ACME BANK")
    XCTAssertFalse(spy.notes[0].failure)
    // An identical body and timestamp from another sender ID is a separate message, card and notification.
    let secondId = "live:" + String(repeating: "d", count: 32)
    let other = try stream(UUID().uuidString.lowercased(), messageId: secondId, address: "AUTH XYZ", unread: true, body: "Your OTP is 42")
    await deliver(model, channel, [other.begin] + other.fragments + [other.commit])
    await until("second sender acknowledgement") { self.sent(channel, 9).count == 2 }
    XCTAssertEqual(model.threads(peer).map(\.address).sorted(), ["ACME BANK", "AUTH XYZ"])
    XCTAssertEqual(spy.notes.count, 2)
    XCTAssertEqual(model.messages(peer, address: "ACME BANK").map(\.messageId), [firstId])
    XCTAssertEqual(model.messages(peer, address: "AUTH XYZ").map(\.messageId), [secondId])
    // Provider history merges under the same address-form conversation and still wins over the live copy.
    model.requestMessages(peer, address: "ACME BANK")
    await until("sender history request") { self.sent(channel, 5).count == 1 }
    let request = try XCTUnwrap(try lastSent(channel, 5))
    XCTAssertEqual(request.text(1), "addr:ACME BANK")
    XCTAssertEqual(request.number(4), Int64(SmsMessage.defaultPageSize))
    let record = try stream(UUID().uuidString.lowercased(), requestId: request.text(0), messageId: "sms:41",
      threadId: "addr:ACME BANK", address: "acme bank", unread: true, body: "Your OTP is 42")
    await deliver(model, channel, [record.begin] + record.fragments + [record.commit])
    await deliver(model, channel, [try records(10, [.text(request.text(0)), .integer(0), .integer(0), .text("")])])
    XCTAssertEqual(model.messages(peer, address: "ACME BANK").map(\.messageId), ["sms:41"])
    XCTAssertEqual(spy.notes.count, 2)
    // Replies keep the stored sender text and the address-form thread id.
    model.send(peer, address: "ACME BANK", text: "thanks")
    await until("sender reply") { self.sent(channel, 11).count == 1 }
    let begin = try XCTUnwrap(try lastSent(channel, 11))
    XCTAssertEqual(begin.text(1), "addr:ACME BANK"); XCTAssertEqual(begin.text(2), "ACME BANK")
  }

  @MainActor func testFragmentIntegrityRejectsConflictsAndNeverAssemblesBadBodies() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    let bigId = UUID().uuidString.lowercased()
    let big = try stream(bigId, messageId: "sms:4", body: String(repeating: "x", count: 5000))
    await deliver(model, channel, [big.begin])
    await deliver(model, channel, [big.fragments[0]])
    let conflict = await model.handle(try records(7, [.text(bigId), .integer(0),
      .bytes(Data(repeating: 9, count: 3072))]), on: channel.descriptor)
    XCTAssertEqual(conflict, .handled)
    await until("conflict acknowledgement") { self.lastResult(channel) == 6 }
    // An identical duplicate of an accepted fragment is idempotent and never acknowledged on its own.
    let second = try stream(UUID().uuidString.lowercased(), messageId: "sms:5", body: String(repeating: "y", count: 5000))
    await deliver(model, channel, [second.begin, second.fragments[0], second.fragments[0]])
    XCTAssertEqual(sent(channel, 9).count, 1)
    await deliver(model, channel, [second.commit])
    await until("unfinished acknowledgement") { self.lastResult(channel) == 6 }
    // A digest mismatch is invalid and no body reaches a notification or the conversation.
    let bad = try stream(UUID().uuidString.lowercased(), messageId: "sms:6", body: "forged", corruptDigest: true)
    await deliver(model, channel, [bad.begin] + bad.fragments + [bad.commit])
    await until("digest acknowledgement") { self.sent(channel, 9).count == 3 }
    XCTAssertEqual(try lastSent(channel, 9)?.number(1), 6)
    XCTAssertTrue(spy.notes.isEmpty)
    XCTAssertTrue(model.messages(peer, address: "+15551234567").isEmpty)
    // Wrong-size fragments for the computed layout are invalid.
    let sizedId = UUID().uuidString.lowercased()
    let sized = try stream(sizedId, messageId: "sms:7", body: String(repeating: "z", count: 4000))
    await deliver(model, channel, [sized.begin])
    let badFragment = await model.handle(try records(7, [.text(sizedId), .integer(0),
      .bytes(Data(repeating: 1, count: 100))]), on: channel.descriptor)
    XCTAssertEqual(badFragment, .handled)
    await until("size acknowledgement") { self.sent(channel, 9).count == 4 }
    XCTAssertEqual(try lastSent(channel, 9)?.number(1), 6)
    // Fragments for unknown streams are discarded and invent no acknowledgement.
    let unknown = await model.handle(try records(7, [.text(UUID().uuidString.lowercased()), .integer(0),
      .bytes(Data(repeating: 1, count: 10))]), on: channel.descriptor)
    XCTAssertEqual(unknown, .discarded)
    await Task.yield()
    XCTAssertEqual(sent(channel, 9).count, 4)
  }

  @MainActor func testHistoryRecordsWithoutAnAcceptingRequestAreDiscarded() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    let stale = try stream(UUID().uuidString.lowercased(), requestId: UUID().uuidString.lowercased(),
      messageId: "sms:8", body: "not mine")
    await deliver(model, channel, [stale.begin], expected: .discarded)
    await deliver(model, channel, [stale.fragments[0], stale.commit], expected: .discarded)
    XCTAssertTrue(spy.notes.isEmpty)
    XCTAssertTrue(model.messages(peer, address: "+15551234567").isEmpty)
    XCTAssertTrue(sent(channel, 9).isEmpty)
  }

  @MainActor func testExpiredReplyDoesNotDrainFragmentsWhenCapacityReturns() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    await until("capability submitted") { self.sent(channel, 1).count >= 2 }
    channel.onSendData = { _ in throw SessionBackpressure() }
    model.send(peer, address: "+1555", text: String(repeating: "x", count: 24_576))
    await until("begin attempted") { self.sent(channel, 11).count == 1 }
    clock.advance(31)
    model.expire()
    channel.onSendData = nil
    model.capacityAvailable(channel.descriptor)
    await Task.yield()
    XCTAssertTrue(sent(channel, 12).isEmpty)
    XCTAssertTrue(sent(channel, 13).isEmpty)
    XCTAssertFalse(model.sending(peer))
    XCTAssertEqual(model.status(peer), "Not confirmed; it may have been sent")
  }

  @MainActor func testAnUnadvertisedLanDoesNotStealBleRequests() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let ble = MockSecuredChannel(transport: "ble")
    let peer = try await ready(model, ble)
    let lan = MockSecuredChannel(instance: "new-lan", transport: "lan", peer: peer)
    model.available(lan)
    model.requestThreads(peer)
    await until("BLE request") { self.sent(ble, 2).count == 1 }
    XCTAssertTrue(sent(lan, 2).isEmpty)
    XCTAssertTrue(model.diagnostics(peer).contains("Bluetooth"))
  }

  @MainActor func testNotificationFailureDoesNotCountAsSubmittedAndRetryCanNotify() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    spy.outcome = .failed
    let parts = try stream(UUID().uuidString.lowercased(), messageId: "live:" + String(repeating: "e", count: 32), body: "test")
    await deliver(model, channel, [parts.begin] + parts.fragments + [parts.commit])
    XCTAssertTrue(model.diagnostics(peer).contains("0 Submitted to macOS"))
    spy.outcome = .submitted
    await deliver(model, channel, [parts.begin] + parts.fragments + [parts.commit])
    XCTAssertTrue(model.diagnostics(peer).contains("1 Submitted to macOS"))
    XCTAssertEqual(model.messages(peer, address: "+15551234567").count, 1)
    XCTAssertEqual(spy.notes.count, 2)
  }

  @MainActor func testLastRetirementDuringNotificationSubmissionCannotRepopulateState() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    spy.suspendPost = true
    let parts = try stream(UUID().uuidString.lowercased(), messageId: "live:" + String(repeating: "f", count: 32), body: "test")
    await deliver(model, channel, [parts.begin] + parts.fragments)
    let commit = Task { await model.handle(parts.commit, on: channel.descriptor) }
    await until("notification submitted") { spy.pause != nil }
    model.retired(channel.descriptor)
    spy.pause?.resume(returning: .submitted)
    _ = await commit.value
    XCTAssertTrue(model.messages(peer, address: "+15551234567").isEmpty)
    XCTAssertTrue(model.threads(peer).isEmpty)
  }

  // MARK: - Thread list and provider paging

  @MainActor func testThreadsLoadGroupAndOrderWithProviderIdentityWinning() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    model.requestThreads(peer)
    await until("thread request") { self.sent(channel, 2).count == 1 }
    let requestId = try XCTUnwrap(try lastSent(channel, 2)).text(0)
    _ = await handle(model, try records(3, [.text(requestId), .text("sms:42"), .text("+1 (555) 123-4567"),
      .text("hi"), .integer(500), .integer(2)]), channel)
    _ = await handle(model, try records(3, [.text(requestId), .text("sms:7"), .text("+15559990000"),
      .text("older"), .integer(100), .integer(0)]), channel)
    _ = await handle(model, try records(3, [.text(requestId), .text("sms:9"), .text("+15559990000"),
      .text("newer"), .integer(800), .integer(0)]), channel)
    // A duplicate address record replaces the card instead of appending one.
    _ = await handle(model, try records(3, [.text(requestId), .text("sms:44"), .text("+15551234567"),
      .text("newest"), .integer(900), .integer(0)]), channel)
    let done = await model.handle(try records(4, [.text(requestId), .integer(0)]), on: channel.descriptor)
    XCTAssertEqual(done, .handled)
    let cards = model.threads(peer)
    XCTAssertEqual(cards.map(\.key), ["+15551234567", "+15559990000"])
    XCTAssertEqual(cards[0].threadId, "sms:44")
    XCTAssertEqual(cards[0].snippet, "newest")
    XCTAssertEqual(cards[0].address, "+15551234567")
    XCTAssertEqual(model.status(peer), "2 conversations")
    // Stale thread completions are discarded rather than clearing fresh state.
    let stale = await model.handle(try records(4, [.text(UUID().uuidString.lowercased()), .integer(6)]), on: channel.descriptor)
    XCTAssertEqual(stale, .discarded)
    XCTAssertEqual(model.threads(peer).count, 2)
    XCTAssertFalse(model.busy(peer))
  }

  @MainActor func testThreadListRefreshReplacesSnapshotKeepsLiveCardsAndDropsLateRecords() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    model.requestThreads(peer)
    await until("first request") { self.sent(channel, 2).count == 1 }
    let first = try XCTUnwrap(try lastSent(channel, 2))
    _ = await handle(model, try records(3, [.text(first.text(0)), .text("sms:42"), .text("+15551234567"),
      .text("hi"), .integer(500), .integer(0)]), channel)
    _ = await handle(model, try records(3, [.text(first.text(0)), .text("sms:7"), .text("AUTH XYZ"),
      .text("alert"), .integer(400), .integer(1)]), channel)
    _ = await handle(model, try records(4, [.text(first.text(0)), .integer(0)]), channel)
    XCTAssertEqual(model.threads(peer).map(\.key).sorted(), ["+15551234567", "AUTH XYZ"])
    // A card a live message created survives the next snapshot even when the phone does not report it.
    let liveId = "live:" + String(repeating: "e", count: 32)
    let live = try stream(UUID().uuidString.lowercased(), messageId: liveId, address: "ACME BANK", unread: true, body: "live only")
    await deliver(model, channel, [live.begin] + live.fragments + [live.commit])
    await until("live card") { model.threads(peer).contains { $0.key == "ACME BANK" } }
    // The phone deleted the AUTH XYZ conversation: the refresh snapshot replaces the list.
    model.requestThreads(peer)
    await until("second request") { self.sent(channel, 2).count == 2 }
    let second = try XCTUnwrap(try lastSent(channel, 2))
    _ = await handle(model, try records(3, [.text(second.text(0)), .text("sms:42"), .text("+15551234567"),
      .text("newest"), .integer(900), .integer(0)]), channel)
    _ = await handle(model, try records(4, [.text(second.text(0)), .integer(0)]), channel)
    XCTAssertEqual(model.threads(peer).map(\.key).sorted(), ["+15551234567", "ACME BANK"])
    XCTAssertEqual(model.threads(peer).first { $0.key == "+15551234567" }?.snippet, "newest")
    // A late record from the finished first request is discarded and cannot re-add the deleted card.
    let late = await model.handle(try records(3, [.text(first.text(0)), .text("sms:7"), .text("AUTH XYZ"),
      .text("late"), .integer(1000), .integer(0)]), on: channel.descriptor)
    XCTAssertEqual(late, .discarded)
    XCTAssertEqual(model.threads(peer).map(\.key).sorted(), ["+15551234567", "ACME BANK"])
  }

  @MainActor func testHistoryPageMergesProviderCopyAndPrefersItOverLive() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    let liveId = "live:" + String(repeating: "c", count: 32)
    let live = try stream(UUID().uuidString.lowercased(), messageId: liveId, threadId: "addr:+15551234567",
      dateMillis: 1_700_000_000_000, body: "ping")
    await deliver(model, channel, [live.begin] + live.fragments + [live.commit])
    await until("live message") { model.messages(peer, address: "+15551234567").count == 1 }
    XCTAssertEqual(spy.notes.count, 1)
    // The live-only conversation asks the provider with the address fallback first and gets an empty terminal page.
    model.requestMessages(peer, address: "+15551234567")
    await until("address history request") { self.sent(channel, 5).count == 1 }
    let first = try XCTUnwrap(try lastSent(channel, 5))
    XCTAssertEqual(first.text(1), "addr:+15551234567")
    XCTAssertEqual(first.number(2), 0); XCTAssertEqual(first.text(3), "")
    await deliver(model, channel, [try records(10, [.text(first.text(0)), .integer(0), .integer(0), .text("")])])
    XCTAssertFalse(model.more(peer, address: "+15551234567"))
    // Once the thread list reports a provider identity, the next request uses it.
    model.requestThreads(peer)
    await until("thread request") { self.sent(channel, 2).count == 1 }
    let threads = try XCTUnwrap(try lastSent(channel, 2))
    _ = await handle(model, try records(3, [.text(threads.text(0)), .text("sms:42"), .text("+15551234567"),
      .text("ping"), .integer(1_700_000_000_000), .integer(0)]), channel)
    _ = await handle(model, try records(4, [.text(threads.text(0)), .integer(0)]), channel)
    model.requestMessages(peer, address: "+15551234567")
    await until("provider history request") { self.sent(channel, 5).count == 2 }
    let second = try XCTUnwrap(try lastSent(channel, 5))
    XCTAssertEqual(second.text(1), "sms:42")
    let requestId = second.text(0)
    let provider = try stream(UUID().uuidString.lowercased(), requestId: requestId, messageId: "sms:500",
      threadId: "sms:42", dateMillis: 1_700_000_000_000, direction: 0, body: "ping")
    await deliver(model, channel, [provider.begin] + provider.fragments + [provider.commit])
    // Provider records never notify, and the provider copy replaces the live copy.
    XCTAssertEqual(spy.notes.count, 1)
    await deliver(model, channel, [try records(10, [.text(requestId), .integer(0), .integer(0), .text("")])])
    let rows = model.messages(peer, address: "+15551234567")
    XCTAssertEqual(rows.map(\.messageId), ["sms:500"])
    XCTAssertEqual(rows[0].direction, 0)
    // A duplicate live copy of the merged provider record is acknowledged without re-notifying.
    let dupe = try stream(UUID().uuidString.lowercased(), messageId: liveId, threadId: "sms:42",
      dateMillis: 1_700_000_000_000, body: "ping")
    await deliver(model, channel, [dupe.begin] + dupe.fragments + [dupe.commit])
    await until("duplicate acknowledgement") { self.sent(channel, 9).count == 2 }
    XCTAssertEqual(try lastSent(channel, 9)?.number(1), 0)
    XCTAssertEqual(spy.notes.count, 1)
    XCTAssertEqual(model.messages(peer, address: "+15551234567").count, 1)
  }

  // A live event that lands after the panel already fetched the provider copy still announces the message:
  // only a delivered notification suppresses the next one, never a provider row.
  @MainActor func testProviderCopyFirstStillAnnouncesTheLateLiveMessage() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    model.requestThreads(peer)
    await until("thread request") { self.sent(channel, 2).count == 1 }
    let threads = try XCTUnwrap(try lastSent(channel, 2))
    _ = await handle(model, try records(3, [.text(threads.text(0)), .text("sms:42"), .text("+15551234567"),
      .text("Your code is 4242"), .integer(1_700_000_000_000), .integer(1)]), channel)
    _ = await handle(model, try records(4, [.text(threads.text(0)), .integer(0)]), channel)
    // The user opens the conversation: the provider row arrives before the relay's live copy does.
    model.refreshMessages(peer, address: "+15551234567")
    await until("history request") { self.sent(channel, 5).count == 1 }
    let request = try XCTUnwrap(try lastSent(channel, 5))
    let provider = try stream(UUID().uuidString.lowercased(), requestId: request.text(0), messageId: "sms:77",
      threadId: "sms:42", unread: true, body: "Your code is 4242")
    await deliver(model, channel, [provider.begin] + provider.fragments + [provider.commit])
    await until("provider row") { model.messages(peer, address: "+15551234567").count == 1 }
    XCTAssertTrue(spy.notes.isEmpty)
    // The delayed live copy keeps the provider row and announces the message exactly once.
    let live = try stream(UUID().uuidString.lowercased(), messageId: "live:" + String(repeating: "e", count: 32),
      threadId: "sms:42", unread: true, body: "Your code is 4242")
    await deliver(model, channel, [live.begin] + live.fragments + [live.commit])
    await until("late live notification") { spy.notes.count == 1 }
    XCTAssertEqual(spy.notes[0].body, "Your code is 4242")
    XCTAssertEqual(model.messages(peer, address: "+15551234567").count, 1)
    let line = model.diagnostics(peer)
    XCTAssertTrue(line.contains("1 live received"), line)
    XCTAssertTrue(line.contains("1 Submitted to macOS"), line)
    XCTAssertTrue(line.contains("1 already seen"), line)
    // A redelivery of the same live stream never announces a second banner.
    await deliver(model, channel, [live.begin] + live.fragments + [live.commit])
    await until("redelivery acknowledgement") { self.sent(channel, 9).count == 2 }
    XCTAssertEqual(spy.notes.count, 1)
    XCTAssertEqual(model.messages(peer, address: "+15551234567").count, 1)
  }
  @MainActor func testHistoryOrderingUsesByteWiseDescendingIdsAndPagingCursors() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    model.requestThreads(peer)
    await until("thread request") { self.sent(channel, 2).count == 1 }
    let threads = try XCTUnwrap(try lastSent(channel, 2))
    _ = await handle(model, try records(3, [.text(threads.text(0)), .text("sms:42"), .text("+15551234567"),
      .text("hi"), .integer(1_700_000_000_000), .integer(0)]), channel)
    _ = await handle(model, try records(4, [.text(threads.text(0)), .integer(0)]), channel)
    model.requestMessages(peer, address: "+15551234567")
    await until("history request") { self.sent(channel, 5).count == 1 }
    let request = try XCTUnwrap(try lastSent(channel, 5))
    let requestId = request.text(0)
    for messageId in ["sms:100", "sms:9", "sms:11"] {
      let record = try stream(UUID().uuidString.lowercased(), requestId: requestId, messageId: messageId,
        threadId: "sms:42", dateMillis: 1_700_000_000_000, body: "body \(messageId)")
      await deliver(model, channel, [record.begin] + record.fragments + [record.commit])
    }
    await deliver(model, channel, [try records(10, [.text(requestId), .integer(0), .integer(1_699_000_000_000), .text("sms:120")])])
    XCTAssertTrue(model.more(peer, address: "+15551234567"))
    XCTAssertEqual(model.messages(peer, address: "+15551234567").map(\.messageId), ["sms:9", "sms:11", "sms:100"])
    XCTAssertEqual(model.status(peer), "Older messages available")
    model.requestMessages(peer, address: "+15551234567")
    await until("older page request") { self.sent(channel, 5).count == 2 }
    let older = try XCTUnwrap(try lastSent(channel, 5))
    XCTAssertEqual(older.number(2), 1_699_000_000_000)
    XCTAssertEqual(older.text(3), "sms:120")
    XCTAssertEqual(older.number(4), Int64(SmsMessage.defaultPageSize))
    await deliver(model, channel, [try records(10, [.text(older.text(0)), .integer(0), .integer(0), .text("")])])
    XCTAssertFalse(model.more(peer, address: "+15551234567"))
    XCTAssertEqual(model.status(peer), "All messages loaded")
  }

  @MainActor func testNonZeroHistoryResultNeverAdvancesCursorAndNamesPermission() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    model.requestMessages(peer, address: "+15551234567")
    await until("history request") { self.sent(channel, 5).count == 1 }
    let request = try XCTUnwrap(try lastSent(channel, 5))
    let failed = await model.handle(try records(10, [.text(request.text(0)), .integer(1), .integer(999), .text("sms:1")]), on: channel.descriptor)
    XCTAssertEqual(failed, .handled)
    XCTAssertEqual(model.status(peer), "Allow SMS access on your phone to read messages")
    XCTAssertFalse(model.more(peer, address: "+15551234567"))
    model.requestMessages(peer, address: "+15551234567")
    await until("retry request") { self.sent(channel, 5).count == 2 }
    let retry = try XCTUnwrap(try lastSent(channel, 5))
    XCTAssertEqual(retry.number(2), 0); XCTAssertEqual(retry.text(3), "")
    XCTAssertNotEqual(retry.text(0), request.text(0))
    // A stale completion for the abandoned request is discarded rather than advancing anything.
    let stale = await model.handle(try records(10, [.text(request.text(0)), .integer(0), .integer(5), .text("sms:5")]), on: channel.descriptor)
    XCTAssertEqual(stale, .discarded)
    XCTAssertFalse(model.more(peer, address: "+15551234567"))
    XCTAssertTrue(model.messages(peer, address: "+15551234567").isEmpty)
  }

  @MainActor func testReopeningConversationRefreshesNewestWithoutRewindingOlderPaging() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    model.requestThreads(peer)
    await until("thread request") { self.sent(channel, 2).count == 1 }
    let threads = try XCTUnwrap(try lastSent(channel, 2))
    _ = await handle(model, try records(3, [.text(threads.text(0)), .text("sms:42"), .text("+15551234567"),
      .text("hi"), .integer(1_700_000_000_000), .integer(0)]), channel)
    _ = await handle(model, try records(4, [.text(threads.text(0)), .integer(0)]), channel)
    // First open: the request asks for the newest page and leaves an older-message cursor behind.
    model.refreshMessages(peer, address: "+15551234567")
    await until("first open") { self.sent(channel, 5).count == 1 }
    let first = try XCTUnwrap(try lastSent(channel, 5))
    XCTAssertEqual(first.number(2), 0); XCTAssertEqual(first.text(3), "")
    let older = try stream(UUID().uuidString.lowercased(), requestId: first.text(0), messageId: "sms:100",
      threadId: "sms:42", dateMillis: 1_700_000_000_000, body: "older page")
    await deliver(model, channel, [older.begin] + older.fragments + [older.commit])
    await deliver(model, channel, [try records(10, [.text(first.text(0)), .integer(0), .integer(1_699_000_000_000), .text("sms:120")])])
    XCTAssertTrue(model.more(peer, address: "+15551234567"))
    // Reopening asks for the newest page again instead of the stored older cursor...
    model.refreshMessages(peer, address: "+15551234567")
    await until("refresh request") { self.sent(channel, 5).count == 2 }
    let refresh = try XCTUnwrap(try lastSent(channel, 5))
    XCTAssertEqual(refresh.number(2), 0); XCTAssertEqual(refresh.text(3), "")
    // ...so a message missed during the live relay shows up while the older cursor stays usable.
    let missed = try stream(UUID().uuidString.lowercased(), requestId: refresh.text(0), messageId: "sms:600",
      threadId: "sms:42", dateMillis: 1_700_000_500_000, body: "missed message")
    await deliver(model, channel, [missed.begin] + missed.fragments + [missed.commit])
    await deliver(model, channel, [try records(10, [.text(refresh.text(0)), .integer(0), .integer(1_699_999_999_000), .text("sms:610")])])
    XCTAssertEqual(model.messages(peer, address: "+15551234567").map(\.messageId).sorted(), ["sms:100", "sms:600"])
    XCTAssertTrue(model.more(peer, address: "+15551234567"))
    XCTAssertEqual(model.status(peer), "Older messages available")
    // "Load older messages" still starts from the cursor the refresh must not have rewound.
    model.requestMessages(peer, address: "+15551234567")
    await until("older page request") { self.sent(channel, 5).count == 3 }
    let page = try XCTUnwrap(try lastSent(channel, 5))
    XCTAssertEqual(page.number(2), 1_699_000_000_000)
    XCTAssertEqual(page.text(3), "sms:120")
    await deliver(model, channel, [try records(10, [.text(page.text(0)), .integer(0), .integer(0), .text("")])])
    XCTAssertFalse(model.more(peer, address: "+15551234567"))
    XCTAssertEqual(model.status(peer), "All messages loaded")
  }

  @MainActor func testThreadPermissionAndStoreFailuresReportActionableText() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    model.requestThreads(peer)
    await until("thread request") { self.sent(channel, 2).count == 1 }
    let request = try XCTUnwrap(try lastSent(channel, 2))
    _ = await handle(model, try records(4, [.text(request.text(0)), .integer(1)]), channel)
    XCTAssertEqual(model.status(peer), "Allow SMS access on your phone to read conversations")
    model.requestThreads(peer)
    await until("thread retry") { self.sent(channel, 2).count == 2 }
    let retry = try XCTUnwrap(try lastSent(channel, 2))
    _ = await handle(model, try records(4, [.text(retry.text(0)), .integer(5)]), channel)
    XCTAssertEqual(model.status(peer), "Conversations are unavailable")
    XCTAssertFalse(model.busy(peer))
  }

  // MARK: - Channel lifecycle

  @MainActor func testMidPageChannelLossAbortsPageAndKeepsCompletedCursor() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let lan = MockSecuredChannel(instance: "lan-1", transport: "lan")
    let ble = MockSecuredChannel(instance: "ble-1", transport: "ble", peer: lan.descriptor.peer)
    let peer = try await ready(model, lan)
    model.available(ble)
    let handled = await model.handle(try capability(), on: ble.descriptor)
    XCTAssertEqual(handled, .handled)
    XCTAssertTrue(model.connected(peer))
    model.requestMessages(peer, address: "+15551234567")
    await until("history request") { self.sent(lan, 5).count == 1 }
    let request = try XCTUnwrap(try lastSent(lan, 5))
    let record = try stream(UUID().uuidString.lowercased(), requestId: request.text(0), messageId: "sms:60",
      threadId: "sms:42", body: "partial")
    await deliver(model, lan, [record.begin] + record.fragments + [record.commit])
    // The page dies with the link: no historyDone, so the cursor stays, the request is aborted and the status is actionable.
    model.retired(lan.descriptor)
    XCTAssertTrue(model.connected(peer))
    XCTAssertFalse(model.busy(peer))
    XCTAssertEqual(model.status(peer), "Connection lost while loading messages")
    XCTAssertEqual(model.messages(peer, address: "+15551234567").count, 1)
    model.requestMessages(peer, address: "+15551234567")
    await until("failover history request") { self.sent(ble, 5).count == 1 }
    let retry = try XCTUnwrap(try lastSent(ble, 5))
    XCTAssertEqual(retry.number(2), 0); XCTAssertEqual(retry.text(3), "")
    XCTAssertNotEqual(retry.text(0), request.text(0))
    XCTAssertEqual(model.status(peer), "Loading messages…")
    // A late record from the aborted page cannot merge into the retry.
    let late = try stream(UUID().uuidString.lowercased(), requestId: request.text(0), messageId: "sms:61",
      threadId: "sms:42", body: "late")
    await deliver(model, ble, [late.begin, late.fragments[0], late.commit], expected: .discarded)
    XCTAssertEqual(model.messages(peer, address: "+15551234567").count, 1)
  }

  @MainActor func testPeerDataClearsOnLastRetirementAndOnInvalidate() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let lan = MockSecuredChannel(instance: "lan-1", transport: "lan")
    let ble = MockSecuredChannel(instance: "ble-1", transport: "ble", peer: lan.descriptor.peer)
    let peer = try await ready(model, lan)
    model.available(ble)
    _ = await model.handle(try capability(), on: ble.descriptor)
    let message = try stream(UUID().uuidString.lowercased(), messageId: "sms:70", body: "keep me")
    await deliver(model, lan, [message.begin] + message.fragments + [message.commit])
    await until("live message") { model.threads(peer).count == 1 }
    model.retired(lan.descriptor)
    XCTAssertEqual(model.threads(peer).count, 1)
    XCTAssertEqual(model.messages(peer, address: "+15551234567").count, 1)
    model.retired(ble.descriptor)
    XCTAssertFalse(model.connected(peer))
    XCTAssertTrue(model.threads(peer).isEmpty)
    XCTAssertTrue(model.messages(peer, address: "+15551234567").isEmpty)
    XCTAssertEqual(spy.notes.count, 1)
    XCTAssertEqual(model.status(peer), "Connect your phone to relay messages")
    XCTAssertFalse(model.busy(peer))
    model.invalidate()
    XCTAssertEqual(spy.notes.count, 1)
  }

  @MainActor func testUnansweredRequestsAndRepliesExpireWithAlerts() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    model.requestThreads(peer)
    await until("thread request") { self.sent(channel, 2).count == 1 }
    XCTAssertTrue(model.busy(peer))
    clock.advance(31)
    model.expire()
    XCTAssertFalse(model.busy(peer))
    XCTAssertEqual(model.status(peer), "Your phone did not answer")
    model.send(peer, address: "+15551234567", text: "hello")
    await until("send stream") { self.sent(channel, 13).count == 1 }
    clock.advance(31)
    model.expire()
    XCTAssertFalse(model.sending(peer))
    XCTAssertEqual(model.status(peer), "Not confirmed; it may have been sent")
    await until("failure alert") { spy.notes.contains { $0.failure } }
    XCTAssertEqual(spy.notes.last?.address, "+15551234567")
    XCTAssertTrue(spy.notes.last?.failure ?? false)
    // Ten-minute dedupe marks expire so the same content can be delivered as a new message afterwards.
    let first = try stream(UUID().uuidString.lowercased(), messageId: "live:" + String(repeating: "d", count: 32), body: "repeat")
    await deliver(model, channel, [first.begin] + first.fragments + [first.commit])
    await until("first repeat") { spy.notes.count == 2 }
    clock.advance(601)
    model.expire()
    let second = try stream(UUID().uuidString.lowercased(), messageId: "live:" + String(repeating: "e", count: 32), body: "repeat")
    await deliver(model, channel, [second.begin] + second.fragments + [second.commit])
    await until("second repeat") { spy.notes.count == 3 }
  }

  // MARK: - Outgoing replies

  @MainActor func testSendStreamsAtBoundsAndEchoesProviderIdentity() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    model.send(peer, address: "+1 (555) 123-4567", text: String(repeating: "a", count: 30000))
    await until("send stream") { self.sent(channel, 13).count == 1 }
    let begin = try XCTUnwrap(try lastSent(channel, 11))
    XCTAssertEqual(begin.text(1), "addr:+15551234567")
    XCTAssertEqual(begin.text(2), "+1 (555) 123-4567")
    XCTAssertEqual(begin.number(3), 24576)
    XCTAssertEqual(begin.number(4), 8)
    let fragments = sent(channel, 12)
    XCTAssertEqual(fragments.count, 8)
    XCTAssertEqual(fragments[0].bytes(2).count, 3072)
    XCTAssertEqual(fragments[7].bytes(2).count, 24576 - 7 * 3072)
    XCTAssertEqual(try XCTUnwrap(try lastSent(channel, 13)).text(0), begin.text(0))
    XCTAssertEqual(model.status(peer), "Sending…")
    XCTAssertTrue(model.sending(peer))
    // A second reply cannot start while one is in flight.
    model.send(peer, address: "+15551234567", text: "again")
    XCTAssertEqual(model.status(peer), "A reply is already in flight")
    XCTAssertEqual(sent(channel, 11).count, 1)
    let result = try records(14, [.text(begin.text(0)), .integer(0), .text("sms:123"), .integer(1_700_000_000_500)])
    let echoed = await model.handle(result, on: channel.descriptor)
    XCTAssertEqual(echoed, .handled)
    XCTAssertFalse(model.sending(peer))
    XCTAssertEqual(model.status(peer), "Sent")
    let rows = model.messages(peer, address: "+15551234567")
    XCTAssertEqual(rows.map(\.messageId), ["sms:123"])
    XCTAssertEqual(rows[0].direction, 1)
    XCTAssertEqual(rows[0].body, String(repeating: "a", count: 24576))
    XCTAssertTrue(spy.notes.isEmpty)
  }

  @MainActor func testSendFailuresAreReportedInlineAndByAlert() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    let expected: [(Int64, String, Bool)] = [(1, "Allow SMS on your phone to send replies", true),
                                             (5, "Not confirmed; it may have been sent", true),
                                             (6, "The reply was rejected", false)]
    var alertCount = 0
    for (index, row) in expected.enumerated() {
      model.send(peer, address: "+15551234567", text: "hello \(row.0)")
      await until("send \(row.0)") { self.sent(channel, 13).count == index + 1 }
      let request = try XCTUnwrap(try lastSent(channel, 11))
      let result = try records(14, [.text(request.text(0)), .integer(row.0), .text(""), .integer(0)])
      let handled = await model.handle(result, on: channel.descriptor)
      XCTAssertEqual(handled, .handled)
      XCTAssertEqual(model.status(peer), row.1)
      XCTAssertFalse(model.sending(peer))
      if row.2 { alertCount += 1 }
      await until("alert \(row.0)") { spy.notes.filter(\.failure).count == alertCount }
    }
    // A send result that matches nothing is ignored.
    let orphan = await model.handle(try records(14, [.text(UUID().uuidString.lowercased()), .integer(0),
      .text("sms:1"), .integer(0)]), on: channel.descriptor)
    XCTAssertEqual(orphan, .discarded)
    // Empty drafts and empty addresses never produce a stream or a false success.
    let before = channel.sentData.count
    model.send(peer, address: "+15551234567", text: "")
    XCTAssertEqual(model.status(peer), "Write a message first")
    model.send(peer, address: "  ", text: "hi")
    XCTAssertEqual(model.status(peer), "Choose a conversation first")
    XCTAssertEqual(channel.sentData.count, before)
  }

  @MainActor func testNotificationReplyFastFailsWithoutChannelAndClampsText() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let peer = MockSecuredChannel().descriptor.peer
    let target = SmsReplyRequest(peerKey: key(peer), peerName: peer.deviceName, address: "+15551234567",
      threadId: "sms:42", text: "from the banner")
    await model.reply(target)
    XCTAssertEqual(model.status(peer), "Connect your phone to send replies")
    await until("fast-fail alert") { spy.notes.filter(\.failure).count == 1 }
    let channel = MockSecuredChannel(transport: "lan", peer: peer)
    _ = try await ready(model, channel)
    await model.reply(SmsReplyRequest(peerKey: key(peer), peerName: peer.deviceName, address: "+15551234567",
      threadId: "sms:42", text: String(repeating: "😀", count: 7000)))
    await until("reply stream") { self.sent(channel, 13).count == 1 }
    let begin = try XCTUnwrap(try lastSent(channel, 11))
    XCTAssertEqual(begin.text(1), "sms:42")
    XCTAssertEqual(begin.number(3), 24576)
    XCTAssertEqual(begin.number(4), 8)
    XCTAssertEqual(sent(channel, 12).count, 8)
    XCTAssertEqual(spy.notes.filter(\.failure).count, 1)
  }

  @MainActor func testThreadsRequestParksUntilCapabilityThenIssuesOnce() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    model.retired(channel.descriptor)
    let fresh = MockSecuredChannel(instance: "fresh", transport: "lan", peer: peer)
    model.available(fresh)
    model.requestThreads(peer)
    XCTAssertTrue(sent(fresh, 2).isEmpty)
    XCTAssertEqual(model.status(peer), "Waiting for your phone")
    model.requestMessages(peer, address: "+15551234567")
    XCTAssertTrue(sent(fresh, 5).isEmpty)
    XCTAssertEqual(model.status(peer), "Connect your phone to read messages")
    let advertised = await model.handle(try capability(), on: fresh.descriptor)
    XCTAssertEqual(advertised, .handled)
    await until("parked thread request") { self.sent(fresh, 2).count == 1 }
    // One in-flight request per kind: refreshes while a request is unanswered are ignored.
    model.requestThreads(peer)
    await Task.yield()
    XCTAssertEqual(sent(fresh, 2).count, 1)
    let outstanding = try XCTUnwrap(try lastSent(fresh, 2))
    _ = await handle(model, try records(4, [.text(outstanding.text(0)), .integer(0)]), fresh)
    XCTAssertFalse(model.busy(peer))
    model.requestThreads(peer)
    await until("refreshed thread request") { self.sent(fresh, 2).count == 2 }
    XCTAssertEqual(model.status(peer), "Loading conversations…")
    model.requestThreads(peer)
    await Task.yield()
    XCTAssertEqual(sent(fresh, 2).count, 2)
  }

  @MainActor func testSmsNeverTouchesDisk() async throws {
    let spy = SmsNotifierSpy(), clock = SmsClock(), model = make(spy, clock)
    let channel = MockSecuredChannel(transport: "lan")
    let peer = try await ready(model, channel)
    model.send(peer, address: "+15551234567", text: "hello")
    let message = try stream(UUID().uuidString.lowercased(), messageId: "sms:90", body: "no disk")
    await deliver(model, channel, [message.begin] + message.fragments + [message.commit])
    await until("message row") { !model.messages(peer, address: "+15551234567").isEmpty }
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/aniCe")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
    XCTAssertFalse(names.contains { $0.lowercased().contains("sms") || $0.lowercased().contains("message") })
  }
}
