// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises independent clipboard vectors, native failure isolation and cross-transport idempotency without the real pasteboard.
import XCTest
import CryptoKit
@testable import aniCe

@MainActor final class ClipboardNativeFake: NativeClipboard {
  var automaticAccessAllowed = true
  var sample: ClipboardSample? = ClipboardSample(text: "local", token: "1")
  var fail = false
  var writes = 0
  var observer: (@MainActor () -> Void)?
  func read() -> ClipboardSample? { sample }
  func token() -> String? { sample?.token ?? "empty" }
  func write(_ text: String, sensitive: Bool) -> Bool {
    guard !fail else { return false }
    writes += 1; sample = ClipboardSample(text: text, sensitive: sensitive, excluded: true, token: "write-\(writes)"); observer?(); return true
  }
  func observe(_ enabled: Bool, changed: @escaping @MainActor () -> Void) { observer = enabled ? changed : nil }
}
@MainActor private final class ClipboardChannel: SecuredChannel {
  let descriptor: ChannelDescriptor
  var sent: [ClipboardMessage] = []
  var blocked = false
  var fail = false
  var attempts = 0
  init(_ transport: String = "lan") {
    descriptor = ChannelDescriptor(instance: UUID().uuidString, transport: transport, peer: try! DeviceIdentity(deviceId: "01234567-89ab-4cde-8fab-0123456789ab", deviceName: "Device", publicKey: P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)).publicKey.x963Representation))
  }
  func sendData(_ bytes: Data) async throws {
    attempts += 1
    if blocked { throw SessionBackpressure() }; if fail { throw SessionFailure.cancelled }
    sent.append(try XCTUnwrap(ClipboardMessage.decode(bytes)))
  }
}
@MainActor private final class ClipboardClock {
  private(set) var time: TimeInterval = 0
  private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
  func wait(_ duration: TimeInterval) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
        else { sleepers[id] = (time + duration, continuation) }
      }
    } onCancel: {
      Task { @MainActor in self.sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
    }
  }
  func waitingAt(_ deadline: TimeInterval) -> Bool { sleepers.values.contains { abs($0.0 - deadline) < 0.000001 } }
  func advance(_ duration: TimeInterval) {
    time += duration
    let due = sleepers.filter { $0.value.0 <= time }
    for id in due.keys { sleepers.removeValue(forKey: id) }
    for (_, value) in due { value.1.resume() }
  }
}
@MainActor private final class ClipboardHarness {
  let clock = ClipboardClock()
  var time: TimeInterval {
    get { clock.time }
    set { clock.advance(newValue - clock.time) }
  }
  let native = ClipboardNativeFake()
  lazy var owner = MacClipboardModel(native: native, now: { [clock] in clock.time }, wait: { [clock] in try await clock.wait($0) })
  let epoch = UUID().uuidString.lowercased()
  func ready(_ c: ClipboardChannel) async throws {
    owner.available(c)
    _ = await owner.handle(try ClipboardMessage(kind: 1, fields: [.text(epoch), .integer(65536), .integer(3072)]).encode(), on: c.descriptor)
    _ = await owner.handle(try ClipboardMessage(kind: 2, fields: [.integer(1), .bool(true)]).encode(), on: c.descriptor)
    for _ in 0..<10 { await Task.yield() }
  }
  @discardableResult func receive(_ c: ClipboardChannel, text: String = "hello", revision: Int64 = 1, id: String = UUID().uuidString.lowercased(), auto: Bool = false) async throws -> ClipboardMessage {
    let data = Data(text.utf8)
    let begin = ClipboardMessage(kind: 3, fields: [.text(epoch), .integer(revision), .text(id), .integer(auto ? 1 : 0), .bool(false), .integer(Int64(data.count)), .integer(Int64((data.count + 3071) / 3072)), .bytes(Data(SHA256.hash(data: data)))])
    _ = await owner.handle(try begin.encode(), on: c.descriptor)
    for index in 0..<Int(begin.number(6)) {
      let start = index * 3072
      _ = await owner.handle(try ClipboardMessage(kind: 4, fields: [.text(id), .integer(Int64(index)), .bytes(data.subdata(in: start..<min(start + 3072, data.count)))]).encode(), on: c.descriptor)
    }
    _ = await owner.handle(try ClipboardMessage.id(5, id).encode(), on: c.descriptor)
    return begin
  }
}
final class ClipboardTests: XCTestCase {
  func testIndependentCanonicalBytesAndInvalidInventory() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "clipboard-vectors", withExtension: "json"))
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let good = try XCTUnwrap(root["valid"] as? [[String: Any]]), bad = try XCTUnwrap(root["invalid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(good.count, 18); XCTAssertGreaterThanOrEqual(bad.count, 34)
    for row in good { let data = try SessionFixtures().b(row, "bytes"); XCTAssertEqual(try XCTUnwrap(ClipboardMessage.decode(data)).encode(), data) }
    for row in bad { XCTAssertThrowsError(try ClipboardMessage.decode(SessionFixtures().b(row, "bytes")), row["name"] as? String ?? "") }
    XCTAssertNil(try ClipboardMessage.decode(SessionCbor.encode(.array([.text("other")]))))
  }
  @MainActor private func until(_ test: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<2000 { if test() { return }; try await Task.sleep(for: .milliseconds(1)) }
    XCTFail("Clipboard condition did not resolve")
  }
  @MainActor func testDuplicateAcrossTransportsAndOlderRevisionNeverOverwrite() async throws {
    let h = ClipboardHarness(), lan = ClipboardChannel(), ble = ClipboardChannel("ble"); try await h.ready(lan); try await h.ready(ble)
    let begin = try await h.receive(lan); XCTAssertEqual(h.native.writes, 1)
    _ = await h.owner.handle(try begin.encode(), on: ble.descriptor)
    _ = await h.owner.handle(try ClipboardMessage.id(5, begin.text(2)).encode(), on: ble.descriptor)
    XCTAssertEqual(h.native.writes, 1)
    try await h.receive(ble, text: "new", revision: 2); try await h.receive(lan, text: "old", revision: 1)
    XCTAssertEqual(h.native.sample?.text, "new"); XCTAssertEqual(h.native.writes, 2); h.owner.invalidate()
  }
  @MainActor func testAutomaticDisabledRejectsAutomaticButAcceptsManual() async throws {
    let h = ClipboardHarness(), c = ClipboardChannel(); try await h.ready(c)
    try await h.receive(c, auto: true); XCTAssertEqual(h.native.writes, 0)
    try await h.receive(c, revision: 2); XCTAssertEqual(h.native.writes, 1); h.owner.invalidate()
  }
  @MainActor func testConflictBaselineSurvivesRetry() async throws {
    let h = ClipboardHarness(), c = ClipboardChannel(), ble = ClipboardChannel("ble"); try await h.ready(c); try await h.ready(ble)
    let original = try await h.receive(c)
    var fields = original.fields; fields[1] = .integer(2); fields[2] = .text(UUID().uuidString.lowercased())
    let begin = ClipboardMessage(kind: 3, fields: fields)
    _ = await h.owner.handle(try begin.encode(), on: c.descriptor)
    h.native.sample = ClipboardSample(text: "new local", token: "new")
    _ = await h.owner.handle(try begin.encode(), on: ble.descriptor)
    _ = await h.owner.handle(try ClipboardMessage(kind: 4, fields: [.text(begin.text(2)), .integer(0), .bytes(Data("hello".utf8))]).encode(), on: ble.descriptor)
    _ = await h.owner.handle(try ClipboardMessage.id(5, begin.text(2)).encode(), on: ble.descriptor)
    XCTAssertEqual(h.native.sample?.text, "new local"); XCTAssertEqual(h.native.writes, 1); h.owner.invalidate()
  }
  @MainActor func testCacheSaturationDoesNotEvictUnexpiredResults() async throws {
    let h = ClipboardHarness(), c = ClipboardChannel(); try await h.ready(c)
    let first = try await h.receive(c)
    for r in 2...32 { try await h.receive(c, revision: Int64(r)) }
    try await h.receive(c, revision: 33); XCTAssertEqual(h.native.writes, 32)
    _ = await h.owner.handle(try first.encode(), on: c.descriptor); XCTAssertEqual(h.native.writes, 32)
    h.time = 60; h.owner.expire(); try await h.receive(c, revision: 34); XCTAssertEqual(h.native.writes, 33); h.owner.invalidate()
  }
  @MainActor func testMaximumUnicodeAndNativeWriteFailure() async throws {
    let h = ClipboardHarness(), c = ClipboardChannel(); try await h.ready(c)
    h.owner.send(pasted: String(repeating: "é", count: 32769))
    XCTAssertFalse(h.owner.busy); XCTAssertFalse(c.sent.contains { $0.kind == 3 })
    let text = String(repeating: "x", count: 3071) + "👋" + String(repeating: "a", count: 65536 - 3075)
    try await h.receive(c, text: text); XCTAssertEqual(h.native.sample?.text, text)
    h.native.fail = true; try await h.receive(c, text: "failed", revision: 2)
    XCTAssertEqual(h.native.writes, 1)
    try await until { c.sent.filter { $0.kind == 6 }.count == 2 }
    XCTAssertEqual(c.sent.last { $0.kind == 6 }?.number(1), 5)
    h.owner.invalidate()
  }
  @MainActor func testIncompleteExpiryAndStaleChannel() async throws {
    let h = ClipboardHarness(), c = ClipboardChannel(); try await h.ready(c)
    let first = try await h.receive(c)
    var fields = first.fields; fields[1] = .integer(2); fields[2] = .text(UUID().uuidString.lowercased())
    let begin = ClipboardMessage(kind: 3, fields: fields)
    _ = await h.owner.handle(try begin.encode(), on: c.descriptor); h.time = 30; h.owner.expire()
    _ = await h.owner.handle(try ClipboardMessage.id(5, begin.text(2)).encode(), on: c.descriptor)
    XCTAssertEqual(h.native.writes, 1); h.owner.retired(c.descriptor)
    let result = await h.owner.handle(try first.encode(), on: c.descriptor)
    XCTAssertEqual(result, .discarded); h.owner.invalidate()
  }
  @MainActor func testLanFailureRetriesSameLogicalItemOnceOnBle() async throws {
    let h = ClipboardHarness(), lan = ClipboardChannel(), ble = ClipboardChannel("ble"); try await h.ready(lan); try await h.ready(ble)
    h.owner.send(pasted: "outgoing")
    try await until { lan.sent.contains { $0.kind == 5 } }
    let first = try XCTUnwrap(lan.sent.first { $0.kind == 3 }); h.owner.retired(lan.descriptor)
    try await until { ble.sent.contains { $0.kind == 5 } }
    XCTAssertEqual(first, ble.sent.first { $0.kind == 3 })
    _ = await h.owner.handle(try ClipboardMessage.result(first.text(2), 0).encode(), on: ble.descriptor)
    try await until { !h.owner.busy }; XCTAssertEqual(h.owner.status, "Clipboard delivered"); h.owner.invalidate()
  }
  @MainActor func testBlockedSendWaitsForCapacityAndCancellationOrDeadlinePreventsLateSubmission() async throws {
    for expire in [false, true] {
      let h = ClipboardHarness(), c = ClipboardChannel("ble"); try await h.ready(c); c.blocked = true
      h.owner.send(pasted: "blocked"); try await until { c.attempts > 2 && h.clock.waitingAt(30) }; XCTAssertTrue(h.owner.busy)
      let count = c.attempts; for _ in 0..<10 { await Task.yield() }; XCTAssertEqual(c.attempts, count)
      if expire {
        h.clock.advance(29.999); await Task.yield(); XCTAssertTrue(h.owner.busy)
        h.clock.advance(0.001); try await until { !h.owner.busy }
        XCTAssertEqual(h.owner.status, "Delivery unconfirmed")
      } else { h.owner.cancel() }
      XCTAssertFalse(h.owner.busy); c.blocked = false; h.owner.capacityAvailable(c.descriptor)
      for _ in 0..<10 { await Task.yield() }; XCTAssertFalse(c.sent.contains { $0.kind == 3 }); h.owner.invalidate()
      try await until { !h.clock.waitingAt(30) }
    }
  }
  @MainActor func testAccessDenialSensitiveAndGeneratedClipsDoNotAutoSend() async throws {
    let h = ClipboardHarness(), c = ClipboardChannel(); try await h.ready(c)
    h.native.automaticAccessAllowed = false; h.owner.setAutomatic(true)
    XCTAssertNil(h.native.observer); XCTAssertFalse(h.owner.busy)
    h.native.automaticAccessAllowed = true; h.native.sample = ClipboardSample(text: "secret", sensitive: true, token: "2")
    h.owner.refreshAccess(); h.native.observer?(); XCTAssertFalse(h.owner.busy)
    h.native.sample = ClipboardSample(text: "remote", excluded: true, token: "3"); h.native.observer?(); XCTAssertFalse(h.owner.busy)
    h.owner.invalidate()
  }
  @MainActor func testPreferencesIsolateFingerprintAndPruneOnlyRemovedPeer() throws {
    let storage = try XCTUnwrap(UserDefaults(suiteName: "clipboard.tests." + UUID().uuidString))
    defer { storage.removeObject(forKey: "clipboard.automatic") }
    let prefs = ClipboardPreferences(storage: storage); let a = ClipboardChannel().descriptor.peer
    let b = try! DeviceIdentity(deviceId: a.deviceId, deviceName: a.deviceName, publicKey: P256.Signing.PrivateKey().publicKey.x963Representation)
    XCTAssertFalse(prefs.enabled(a)); prefs.set(a, true); XCTAssertTrue(ClipboardPreferences(storage: storage).enabled(a)); XCTAssertFalse(prefs.enabled(b))
    prefs.set(b, true); prefs.prune([b]); XCTAssertFalse(prefs.enabled(a)); XCTAssertTrue(prefs.enabled(b)); prefs.clear(); XCTAssertFalse(prefs.enabled(b))
  }
  @MainActor func testMissingAcknowledgementRetriesExactlyOnce() async throws {
    let h = ClipboardHarness(), lan = ClipboardChannel(), ble = ClipboardChannel("ble"); try await h.ready(lan); try await h.ready(ble)
    h.owner.send(pasted: "lost ack")
    try await until { h.clock.waitingAt(2) }
    h.clock.advance(1.999); await Task.yield(); XCTAssertFalse(ble.sent.contains { $0.kind == 3 }); XCTAssertTrue(h.owner.busy)
    h.clock.advance(0.001)
    try await until { ble.sent.contains { $0.kind == 5 } && h.clock.waitingAt(4) }
    h.clock.advance(2); try await until { !h.owner.busy }
    XCTAssertEqual(lan.sent.filter { $0.kind == 3 }.count, 1); XCTAssertEqual(ble.sent.filter { $0.kind == 3 }.count, 1)
    XCTAssertEqual(h.owner.status, "Delivery unconfirmed")
    h.owner.invalidate()
  }
  @MainActor func testManualPreparationSurvivesAutomaticCopiesAndLatestPendingFollows() async throws {
    let h = ClipboardHarness(), c = ClipboardChannel(); try await h.ready(c)
    h.native.sample = ClipboardSample(text: "remote", excluded: true, token: "remote"); h.owner.setAutomatic(true)
    h.owner.send(pasted: "manual")
    h.native.sample = ClipboardSample(text: "discarded", token: "2"); h.native.observer?()
    h.native.sample = ClipboardSample(text: "latest", token: "3"); h.native.observer?()
    try await until { c.sent.contains { $0.kind == 5 } }
    let first = try XCTUnwrap(c.sent.first { $0.kind == 3 }); XCTAssertEqual(first.number(3), 0)
    _ = await h.owner.handle(try ClipboardMessage.result(first.text(2), 0).encode(), on: c.descriptor)
    try await until { c.sent.filter { $0.kind == 5 }.count == 2 }
    XCTAssertEqual(c.sent.filter { $0.kind == 4 }.compactMap { String(data: $0.bytes(2), encoding: .utf8) }, ["manual", "latest"])
    h.owner.invalidate()
  }
  @MainActor func testCacheSurvivesAllChannelsRetiringAndRejectsConflictingUuid() async throws {
    let h = ClipboardHarness(), c = ClipboardChannel(); try await h.ready(c)
    let begin = try await h.receive(c)
    var fields = begin.fields; fields[4] = .bool(true)
    let result = await h.owner.handle(try ClipboardMessage(kind: 3, fields: fields).encode(), on: c.descriptor)
    XCTAssertEqual(result, .discarded)
    h.owner.retired(c.descriptor); let next = ClipboardChannel(); try await h.ready(next)
    _ = await h.owner.handle(try begin.encode(), on: next.descriptor)
    _ = await h.owner.handle(try ClipboardMessage.id(5, begin.text(2)).encode(), on: next.descriptor)
    XCTAssertEqual(h.native.writes, 1); h.owner.invalidate()
  }
  @MainActor func testInvalidUtf8AndNulNeverWrite() async throws {
    let h = ClipboardHarness(), c = ClipboardChannel(); try await h.ready(c)
    for (index, data) in [Data([0xff]), Data([0])].enumerated() {
      let id = UUID().uuidString.lowercased()
      let begin = ClipboardMessage(kind: 3, fields: [.text(h.epoch), .integer(Int64(index + 1)), .text(id), .integer(0), .bool(false), .integer(1), .integer(1), .bytes(Data(SHA256.hash(data: data)))])
      _ = await h.owner.handle(try begin.encode(), on: c.descriptor)
      _ = await h.owner.handle(try ClipboardMessage(kind: 4, fields: [.text(id), .integer(0), .bytes(data)]).encode(), on: c.descriptor)
      _ = await h.owner.handle(try ClipboardMessage.id(5, id).encode(), on: c.descriptor)
    }
    XCTAssertEqual(h.native.writes, 0); h.owner.invalidate()
  }

  @MainActor func testDisablingAutomaticDuringPreparationReleasesSendAndManualStillWorks() async throws {
    let h = ClipboardHarness(), c = ClipboardChannel(); try await h.ready(c)
    h.owner.setAutomatic(true); XCTAssertTrue(h.owner.busy)
    h.owner.setAutomatic(false); XCTAssertFalse(h.owner.busy)
    h.owner.send(pasted: "manual after disabling")
    try await until { c.sent.contains { $0.kind == 5 } }
    XCTAssertEqual(c.sent.filter { $0.kind == 4 }.compactMap { String(data: $0.bytes(2), encoding: .utf8) }, ["manual after disabling"])
    h.owner.invalidate()
  }

  @MainActor func testValidMessagesInInvalidStatesNeverWriteOrPoisonNextItem() async throws {
    let scenarios = ["commit-before-begin", "fragment-before-begin", "incomplete-commit", "index-outside-item", "out-of-order", "conflicting-fragment", "digest-mismatch", "cancelled-item"]
    XCTAssertEqual(scenarios.count, 8)
    for scenario in scenarios {
      let h = ClipboardHarness(), c = ClipboardChannel(); try await h.ready(c)
      let id = UUID().uuidString.lowercased(), text = scenario == "out-of-order" ? String(repeating: "x", count: 3073) : "hello"
      let data = Data(text.utf8)
      let begin = ClipboardMessage(kind: 3, fields: [.text(h.epoch), .integer(1), .text(id), .integer(0), .bool(false), .integer(Int64(data.count)), .integer(Int64((data.count + 3071) / 3072)), .bytes(Data(SHA256.hash(data: data)))])
      func feed(_ m: ClipboardMessage) async throws -> DataHandling { await h.owner.handle(try m.encode(), on: c.descriptor) }
      func fragment(_ index: Int64, _ text: String) -> ClipboardMessage { ClipboardMessage(kind: 4, fields: [.text(id), .integer(index), .bytes(Data(text.utf8))]) }
      if scenario.hasSuffix("before-begin") {
        let result = try await feed(scenario.hasPrefix("commit") ? .id(5, id) : fragment(0, "hello"))
        XCTAssertEqual(result, .discarded, scenario)
      } else {
        _ = try await feed(begin)
        switch scenario {
        case "index-outside-item": _ = try await feed(fragment(1, "hello"))
        case "out-of-order": _ = try await feed(fragment(1, "x"))
        case "conflicting-fragment": _ = try await feed(fragment(0, "hello")); _ = try await feed(fragment(0, "world"))
        case "digest-mismatch": _ = try await feed(fragment(0, "world"))
        case "cancelled-item": _ = try await feed(.id(7, id)); _ = try await feed(fragment(0, "hello"))
        default: break
        }
        _ = try await feed(.id(5, id))
        try await until { c.sent.contains { $0.kind == 6 } }
        XCTAssertEqual(c.sent.last { $0.kind == 6 }?.number(1), scenario == "cancelled-item" ? 7 : 6, scenario)
      }
      XCTAssertEqual(h.native.writes, 0, scenario); XCTAssertEqual(h.native.sample?.text, "local", scenario)
      try await h.receive(c, text: "fresh after rejection", revision: 2)
      XCTAssertEqual(h.native.sample?.text, "fresh after rejection", scenario); XCTAssertEqual(h.native.writes, 1, scenario)
      h.owner.invalidate()
    }
  }
  @MainActor func testUnknownUnattemptedStaleAndCancelledResultsCannotFinishAnotherSend() async throws {
    let h = ClipboardHarness(), lan = ClipboardChannel(), ble = ClipboardChannel("ble"); try await h.ready(lan); try await h.ready(ble)
    h.owner.send(pasted: "first"); try await until { lan.sent.contains { $0.kind == 5 } }
    let first = try XCTUnwrap(lan.sent.first { $0.kind == 3 }).text(2)
    let applied = try ClipboardMessage.result(first, 0).encode()
    let unknown = await h.owner.handle(try ClipboardMessage.result(UUID().uuidString.lowercased(), 0).encode(), on: lan.descriptor)
    let unattempted = await h.owner.handle(applied, on: ble.descriptor)
    let stale = await h.owner.handle(applied, on: ChannelDescriptor(instance: "stale", transport: "lan", peer: lan.descriptor.peer))
    XCTAssertEqual(unknown, .discarded); XCTAssertEqual(unattempted, .discarded); XCTAssertEqual(stale, .discarded); XCTAssertTrue(h.owner.busy)
    h.owner.cancel()
    let cancelled = await h.owner.handle(applied, on: lan.descriptor); XCTAssertEqual(cancelled, .discarded)
    h.owner.send(pasted: "second"); try await until { lan.sent.filter { $0.kind == 5 }.count == 2 }
    let old = await h.owner.handle(applied, on: lan.descriptor); XCTAssertEqual(old, .discarded); XCTAssertTrue(h.owner.busy)
    let current = try XCTUnwrap(lan.sent.last { $0.kind == 3 }).text(2)
    _ = await h.owner.handle(try ClipboardMessage.result(current, 0).encode(), on: lan.descriptor)
    try await until { !h.owner.busy }; XCTAssertEqual(h.owner.status, "Clipboard delivered"); h.owner.invalidate()
  }

}
