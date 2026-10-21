// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises independent clipboard vectors, native failure isolation and cross-transport idempotency without the real pasteboard.
import XCTest
import CryptoKit
import SwiftUI
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
private struct FailedHistoryStorage: ClipboardHistoryStorage {
  let entry = ClipboardHistoryEntry(id: UUID().uuidString.lowercased(), text: "preserved", origin: "phone", timestamp: Date(), credential: nil)
  func load() throws -> ClipboardHistoryState? { ClipboardHistoryState(entries: [entry]) }
  func save(_ entries: [ClipboardHistoryEntry], enabled: Bool, capacity: Int) throws { throw CocoaError(.fileWriteNoPermission) }
  func delete() throws { throw CocoaError(.fileWriteNoPermission) }
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
  private func savedCollectionEnabled(_ url: URL) -> Bool? {
    guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return root["enabled"] as? Bool
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

  @MainActor func testHistoryPersistenceBoundsExclusionsAndPruning() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = ClipboardHistoryFile(url: directory.appendingPathComponent("history.json"))
    let history = ClipboardHistory(storage: file)
    history.record(ClipboardSample(text: "disabled"), origin: "mac")
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    history.setEnabled(true); try await until { history.enabled }
    for i in 0..<25 { history.record(ClipboardSample(text: "item-\(i)"), origin: i % 2 == 0 ? "phone" : "mac", credential: i % 2 == 0 ? "peer" : nil) }
    try await until { history.entries.first?.text == "item-24" }; XCTAssertEqual(history.entries.count, 20)
    history.record(ClipboardSample(text: "item-24"), origin: "phone", credential: "peer")
    history.record(ClipboardSample(text: "secret", sensitive: true), origin: "mac")
    history.record(ClipboardSample(text: "generated", excluded: true), origin: "mac")
    history.record(ClipboardSample(text: String(repeating: "é", count: 32769)), origin: "mac")
    history.delete(history.entries.last!.id); try await until { history.entries.count == 19 }
    let reload = ClipboardHistory(storage: file); try await until { reload.enabled }
    XCTAssertEqual(reload.entries.count, 19); XCTAssertEqual(reload.entries.first?.text, "item-24")
    XCTAssertFalse(reload.entries.contains { $0.text == "secret" || $0.text == "generated" })
    let saved = history.entries
    history.setEnabled(false)
    try await until { self.savedCollectionEnabled(file.url) == false }
    XCTAssertEqual(history.entries, saved)
    history.record(ClipboardSample(text: "ignored while paused"), origin: "mac")
    let paused = ClipboardHistory(storage: file)
    try await until { !paused.entries.isEmpty }
    XCTAssertFalse(paused.enabled); XCTAssertEqual(paused.entries, saved)
    paused.delete(saved[0].id); try await until { paused.entries.count == saved.count - 1 }
    paused.clear(includePinned: true); try await until { paused.entries.isEmpty }
    XCTAssertFalse(try XCTUnwrap(file.load()).enabled)
  }
  @MainActor func testHistoryCorruptStorageAndWriteFailureRemainVisible() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.json")
    try Data("invalid".utf8).write(to: url)
    let history = ClipboardHistory(storage: ClipboardHistoryFile(url: url))
    try await until { history.error != nil }; XCTAssertFalse(history.enabled)
    history.clear(); try await until { history.error == nil }; XCTAssertTrue(try XCTUnwrap(ClipboardHistoryFile(url: url).load()).entries.isEmpty)
    try Data().write(to: directory.appendingPathComponent("blocked"))
    let blocked = ClipboardHistory(storage: ClipboardHistoryFile(url: directory.appendingPathComponent("blocked/history.json")))
    blocked.setEnabled(true); try await until { blocked.error != nil }; XCTAssertFalse(blocked.enabled)
  }
  @MainActor func testHistoryOnlyObservationAndCopyDoNotSend() async throws {
    let native = ClipboardNativeFake(), history = ClipboardHistory()
    let owner = MacClipboardModel(native: native, history: history)
    history.setEnabled(true); try await until { history.enabled }
    XCTAssertNotNil(native.observer); XCTAssertFalse(owner.automatic)
    native.observer?(); try await until { history.entries.count == 1 }
    owner.copyHistory(history.entries[0]); native.observer?()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(history.entries.count, 1); XCTAssertFalse(owner.busy)
    native.automaticAccessAllowed = false; owner.refreshAccess(); XCTAssertNil(native.observer)
    owner.invalidate(); history.setEnabled(false)
  }

  @MainActor func testIncomingHistoryOnlyRecordsAppliedItemsAndRetainsOriginOnCopy() async throws {
    let h = ClipboardHarness(), c = ClipboardChannel(); try await h.ready(c)
    h.owner.history.setEnabled(true); try await until { h.owner.history.enabled }
    let begin = try await h.receive(c, text: "from phone")
    try await until { h.owner.history.entries.count == 1 }
    XCTAssertEqual(h.owner.history.entries[0].origin, "phone")
    h.owner.copyHistory(h.owner.history.entries[0]); XCTAssertEqual(h.owner.history.entries[0].origin, "phone")
    _ = await h.owner.handle(try begin.encode(), on: c.descriptor)
    _ = await h.owner.handle(try ClipboardMessage.id(5, begin.text(2)).encode(), on: c.descriptor)
    h.native.fail = true; try await h.receive(c, text: "failed", revision: 2)
    XCTAssertEqual(h.owner.history.entries.map(\.text), ["from phone"])
    h.owner.prune([]); for _ in 0..<10 { await Task.yield() }; XCTAssertEqual(h.owner.history.entries.count, 1)
    h.owner.prune([], confirmedTrust: true); h.owner.invalidate(); XCTAssertEqual(h.owner.history.entries.count, 1)
    h.owner.invalidate()
  }
  @MainActor func testHistoryFailedWriteAndDeletePreserveRowsAndReportFailure() async throws {
    let history = ClipboardHistory(storage: FailedHistoryStorage())
    try await until { history.enabled }
    history.record(ClipboardSample(text: "new"), origin: "mac")
    try await until { history.error != nil }; XCTAssertEqual(history.entries.map(\.text), ["preserved"])
    history.setEnabled(false)
    try await until { history.error != nil }; XCTAssertFalse(history.enabled); XCTAssertEqual(history.entries.map(\.text), ["preserved"])
  }

  @MainActor func testRecentActivityDoesNotRefreshOnDuplicateAndCopyCannotTargetReplacement() async throws {
    let h = ClipboardHarness(), c = ClipboardChannel(); try await h.ready(c)
    let text = String(repeating: "x", count: 239) + "👋" + "full copy suffix"
    let begin = try await h.receive(c, text: text)
    let first = try XCTUnwrap(h.owner.recent)
    XCTAssertTrue(first.received); XCTAssertFalse(h.owner.history.enabled)
    XCTAssertEqual(first.textPreview, String(repeating: "x", count: 239) + "👋")
    h.time = 1
    _ = await h.owner.handle(try begin.encode(), on: c.descriptor)
    _ = await h.owner.handle(try ClipboardMessage.id(5, begin.text(2)).encode(), on: c.descriptor)
    XCTAssertEqual(h.owner.recent?.id, first.id)
    h.owner.setAutomatic(true)
    XCTAssertTrue(h.owner.copyActivity(first.id)); XCTAssertEqual(h.native.sample?.text, text)
    XCTAssertTrue(h.owner.history.entries.isEmpty); XCTAssertFalse(h.owner.busy)
    try await h.receive(c, text: "replacement", revision: 2)
    let second = try XCTUnwrap(h.owner.recent)
    XCTAssertFalse(h.owner.copyActivity(first.id))
    h.owner.dismissActivity(first.id); XCTAssertEqual(h.owner.recent?.id, second.id)
    h.native.fail = true
    XCTAssertFalse(h.owner.copyActivity(second.id)); XCTAssertEqual(h.owner.recent?.id, second.id)
    h.time = 301; h.owner.expire()
    XCTAssertNil(h.owner.recent); XCTAssertFalse(h.owner.copyActivity(second.id)); h.owner.invalidate()
  }

  @MainActor func testRecentOutgoingRequiresAppliedResultAndSuppressesMarkedContent() async throws {
    let h = ClipboardHarness(), c = ClipboardChannel(); try await h.ready(c)
    h.owner.send(pasted: "failed"); try await until { c.sent.contains { $0.kind == 5 } }
    XCTAssertNil(h.owner.recent)
    let failed = try XCTUnwrap(c.sent.first { $0.kind == 3 })
    _ = await h.owner.handle(try ClipboardMessage.result(failed.text(2), 5).encode(), on: c.descriptor)
    try await until { !h.owner.busy }; XCTAssertNil(h.owner.recent)
    h.owner.sendConfirmed(ClipboardSample(text: "secret", sensitive: true))
    try await until { c.sent.filter { $0.kind == 5 }.count == 2 }
    let sensitive = try XCTUnwrap(c.sent.last { $0.kind == 3 })
    _ = await h.owner.handle(try ClipboardMessage.result(sensitive.text(2), 0).encode(), on: c.descriptor)
    try await until { !h.owner.busy }
    XCTAssertNil(h.owner.recent?.sample); XCTAssertNil(h.owner.recent?.textPreview)
    XCTAssertFalse(try XCTUnwrap(h.owner.recent).received)
    try await h.receive(c)
    XCTAssertNotNil(h.owner.recent?.sample)
    h.owner.prune([], confirmedTrust: true); XCTAssertNil(h.owner.recent)
    h.owner.invalidate()
  }

  @MainActor func testRecentClipboardNativeLayouts() async throws {
    let h = ClipboardHarness(), c = ClipboardChannel(); try await h.ready(c)
    try await h.receive(c, text: "A long clipboard preview with 👋 Unicode that wraps naturally and keeps its native Copy action accessible.")
    let folder = URL(fileURLWithPath: "/tmp/anice-clipboard-quiet-renders", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var rendered = 0
    for compact in [false, true] {
      for scheme in [ColorScheme.light, .dark] {
        let content = VStack(alignment: .leading, spacing: 16) {
          ClipboardActivityView(model: h.owner, compact: compact, open: {})
          ClipboardSendButton(model: h.owner)
        }.padding(16).frame(width: compact ? 350 : 620).background(AniCePalette.surface(scheme)).environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: content)
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent("clipboard-\(compact)-\(scheme).png"))
        XCTAssertGreaterThan(host.bounds.height, 100); rendered += 1
      }
    }
    XCTAssertEqual(rendered, 4); h.owner.invalidate()
  }

  @MainActor func testClipboardHistoryAndPreferencesRenderInBothAppearances() async throws {
    let folder = URL(fileURLWithPath: "/tmp/anice-clipboard-history-renders", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = ClipboardHistoryFile(url: folder.appendingPathComponent("fixture-\(UUID().uuidString).json"))
    defer { try? file.delete() }
    let date = Date()
    try file.save([
      ClipboardHistoryEntry(id: UUID().uuidString.lowercased(), text: "A project update copied on the phone, with enough text to wrap onto another line.", origin: "phone", timestamp: date, credential: nil),
      ClipboardHistoryEntry(id: UUID().uuidString.lowercased(), text: "https://example.com/notes", origin: "mac", timestamp: date.addingTimeInterval(-60), credential: nil),
      ClipboardHistoryEntry(id: UUID().uuidString.lowercased(), text: "Earlier notes 👋", origin: "phone", timestamp: date.addingTimeInterval(-86400), credential: nil)
    ])
    let history = ClipboardHistory(storage: file)
    try await until { history.enabled }
    let peer = ClipboardChannel().descriptor.peer
    let preferences = ClipboardPreferences(); preferences.set(peer, true)
    let model = MacClipboardModel(native: ClipboardNativeFake(), history: history, preferences: preferences)
    model.select(peer)
    let record = PeerTrustRecord(peer: peer, localFingerprint: "fixture", method: .qr, pairedAt: date,
      transcriptHash: Data(repeating: 0, count: 32), active: true)
    var renders = 0
    for scheme in [ColorScheme.light, .dark] {
      for width: CGFloat in [350, 620] {
        let content = VStack(alignment: .leading, spacing: 20) {
          ClipboardSettingsView(model: model, peers: [record], showHistory: false)
          Divider()
          ClipboardHistoryView(model: model)
        }.padding(20).frame(width: width).background(AniCePalette.surface(scheme))
          .environment(\.colorScheme, scheme).tint(AniCePalette.primaryText(scheme))
        let host = NSHostingView(rootView: content)
        host.frame.size = host.fittingSize; host.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("history-\(Int(width))-\(scheme).png"))
        XCTAssertGreaterThan(host.bounds.height, 200); XCTAssertFalse(model.busy); renders += 1
      }
    }
    XCTAssertEqual(renders, 4); model.invalidate()
  }

  @MainActor func testClipboardHistoryCapacityPinningAndClearing() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = ClipboardHistoryFile(url: directory.appendingPathComponent("history.json"))
    let history = ClipboardHistory(storage: file, capacity: 20)
    history.setEnabled(true); try await until { history.enabled }

    for i in 0..<5 { history.record(ClipboardSample(text: "item-\(i)"), origin: "mac") }
    try await until { history.entries.count == 5 }

    let item2 = try XCTUnwrap(history.entries.first { $0.text == "item-2" })
    history.togglePin(item2.id)
    try await until { history.entries.first { $0.text == "item-2" }?.pinned == true }

    for i in 10..<35 { history.record(ClipboardSample(text: "overflow-\(i)"), origin: "mac") }
    try await until { history.entries.first?.text == "overflow-34" }

    XCTAssertTrue(history.entries.contains { $0.text == "item-2" && $0.pinned })
    XCTAssertEqual(history.entries.count, 21)

    history.setCapacity(50)
    try await until { history.capacity == 50 }

    history.clear(includePinned: false)
    try await until { history.entries.count == 1 }
    XCTAssertEqual(history.entries.first?.text, "item-2")
    XCTAssertTrue(history.entries.first?.pinned == true)

    history.clear(includePinned: true)
    try await until { history.entries.isEmpty }
  }

  @MainActor func testClipboardHistorySearchAndSmartPreviewDetection() async throws {
    let entryUrl = ClipboardHistoryEntry(id: UUID().uuidString.lowercased(), text: "https://anice.local/docs", origin: "mac", timestamp: Date(), credential: nil)
    XCTAssertTrue(entryUrl.isUrl)
    XCTAssertNil(entryUrl.hexColorValue)

    let entryColor = ClipboardHistoryEntry(id: UUID().uuidString.lowercased(), text: "#355B70", origin: "phone", timestamp: Date(), credential: nil)
    XCTAssertFalse(entryColor.isUrl)
    XCTAssertEqual(entryColor.hexColorValue, "#355B70")

    let entryText = ClipboardHistoryEntry(id: UUID().uuidString.lowercased(), text: "let greeting = \"Hello World\";", origin: "mac", timestamp: Date(), credential: nil)
    XCTAssertFalse(entryText.isUrl)
    XCTAssertNil(entryText.hexColorValue)

    let history = ClipboardHistory(capacity: 20)
    history.setEnabled(true); try await until { history.enabled }
    history.record(ClipboardSample(text: "Quick brown fox"), origin: "mac")
    history.record(ClipboardSample(text: "Lazy dog jumps"), origin: "phone")
    history.record(ClipboardSample(text: "FOX in socks"), origin: "mac")
    try await until { history.entries.count == 3 }

    let results = history.search(query: "fox")
    XCTAssertEqual(results.count, 2)
    XCTAssertTrue(results.allSatisfy { $0.text.localizedCaseInsensitiveContains("fox") })

    let emptySearch = history.search(query: "")
    XCTAssertEqual(emptySearch.count, 3)
  }

  func testTrayTypingNeverConsumesArrowOrFunctionKeyCharacters() {
    for code in 0xF700...0xF8FF {
      let scalar = UnicodeScalar(code)!
      XCTAssertFalse(PasteTrayKeyboard.searchCharacters.contains(scalar), "AppKit key \(code) must reach navigation")
    }
    for text in ["a", "Z", "1", "/", "?", "é", "क", "🙂"] {
      XCTAssertTrue(text.unicodeScalars.allSatisfy(PasteTrayKeyboard.searchCharacters.contains), text)
    }
    for scalar in "\t\r\n\u{7F}".unicodeScalars {
      XCTAssertFalse(PasteTrayKeyboard.searchCharacters.contains(scalar))
    }
  }

  func testTrayFiltersKeepPinnedOrderAndRejectNonmatchingOrigins() {
    let rows = (0..<6).map { index in
      ClipboardHistoryEntry(id: "row-\(index)", text: index == 4 ? "Other text" : "Hello 👋 \(index)",
        origin: index.isMultiple(of: 2) ? "mac" : "phone", timestamp: Date(), credential: nil,
        pinned: index == 2 || index == 3)
    }
    XCTAssertEqual(PasteTrayFilter.all.entries(in: rows, query: "  HELLO  ").map(\.id), ["row-2", "row-3", "row-0", "row-1", "row-5"])
    XCTAssertEqual(PasteTrayFilter.pinned.entries(in: rows, query: "").map(\.id), ["row-2", "row-3"])
    XCTAssertEqual(PasteTrayFilter.mac.entries(in: rows, query: "hello").map(\.id), ["row-2", "row-0"])
    XCTAssertEqual(PasteTrayFilter.phone.entries(in: rows, query: "👋").map(\.id), ["row-3", "row-1", "row-5"])
    XCTAssertTrue(PasteTrayFilter.all.entries(in: rows, query: "missing").isEmpty)
    XCTAssertTrue(PasteTrayFilter.all.entries(in: [], query: "").isEmpty)
  }

  @MainActor func testHistoryCopyFailurePreservesClipboardAndDoesNotSend() async throws {
    let h = ClipboardHarness(), channel = ClipboardChannel(); try await h.ready(channel)
    let entry = ClipboardHistoryEntry(id: "copy", text: "Saved item", origin: "mac", timestamp: Date(), credential: nil)
    let count = channel.sent.count
    h.native.fail = true
    XCTAssertFalse(h.owner.copyHistory(entry))
    XCTAssertEqual(h.native.sample?.text, "local")
    XCTAssertEqual(h.owner.status, "Could not copy text")
    h.native.fail = false
    XCTAssertTrue(h.owner.copyHistory(entry))
    XCTAssertEqual(h.native.sample?.text, "Saved item")
    XCTAssertEqual(channel.sent.count, count)
    h.owner.invalidate()
  }

  @MainActor func testTrayNativeRendersInBothThemesAndNarrowWidths() async throws {
    let folder = URL(fileURLWithPath: "/tmp/anice-tray-renders", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let history = ClipboardHistory()
    history.setEnabled(true); try await until { history.enabled }
    for text in ["A long note with Unicode 👋 and several lines\nSecond line\nThird line\nFourth line", "https://example.com/a/long/path", "#355B70", "func copy() { return true; }"] {
      history.record(ClipboardSample(text: text), origin: "mac")
    }
    try await until { history.entries.count == 4 }
    let model = MacClipboardModel(native: ClipboardNativeFake(), history: history)
    for collecting in [true, false] {
      history.setEnabled(collecting); try await until { history.enabled == collecting }
    for scheme in [ColorScheme.light, .dark] {
      for width: CGFloat in [560, 760] {
        let content = PasteTrayView(model: model, width: width, onDismiss: {}, onSelect: { _ in })
          .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: content)
        host.frame.size = host.fittingSize; host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.width, width); XCTAssertEqual(host.bounds.height, 292)
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:]))
          .write(to: folder.appendingPathComponent("tray-\(Int(width))-\(scheme)-\(collecting).png"))
      }
    }
    }
    model.invalidate()
  }

  @MainActor func testPinnedItemSurvivesAbsoluteHistoryLimit() async throws {
    let history = ClipboardHistory(capacity: 100)
    history.setEnabled(true); try await until { history.enabled }
    history.record(ClipboardSample(text: "Keep this"), origin: "mac")
    try await until { history.entries.count == 1 }
    let id = try XCTUnwrap(history.entries.first?.id)
    history.togglePin(id); try await until { history.entries.first?.pinned == true }
    for index in 0..<100 { history.record(ClipboardSample(text: "New item \(index)"), origin: "mac") }
    try await until { history.entries.first?.text == "New item 99" }
    XCTAssertEqual(history.entries.count, 100)
    XCTAssertTrue(history.entries.contains { $0.id == id && $0.pinned })
  }

  @MainActor func testPausedCapacityAndLegacyHistoryRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = ClipboardHistoryFile(url: directory.appendingPathComponent("history.json"))
    let history = ClipboardHistory(storage: file)
    history.setCapacity(100); try await until { history.capacity == 100 }
    history.setEnabled(true); try await until { history.enabled }
    for index in 0..<105 { history.record(ClipboardSample(text: "row-\(index)"), origin: "mac") }
    try await until { history.entries.first?.text == "row-104" }
    XCTAssertEqual(history.entries.count, 100)
    history.setEnabled(false); try await until { self.savedCollectionEnabled(file.url) == false }
    let paused = ClipboardHistory(storage: file)
    try await until { paused.entries.count == 100 }
    XCTAssertFalse(paused.enabled); XCTAssertEqual(paused.capacity, 100)
    paused.setCapacity(50); try await until { paused.capacity == 50 }
    XCTAssertEqual(paused.entries.count, 50); XCTAssertEqual(paused.entries.first?.text, "row-104")
    paused.setCapacity(0); paused.setCapacity(101); XCTAssertEqual(paused.capacity, 50)
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
    legacy.removeValue(forKey: "enabled"); legacy.removeValue(forKey: "capacity")
    try JSONSerialization.data(withJSONObject: legacy).write(to: file.url)
    XCTAssertTrue(try XCTUnwrap(file.load()).enabled)
    legacy["capacity"] = 101
    try JSONSerialization.data(withJSONObject: legacy).write(to: file.url)
    XCTAssertThrowsError(try file.load())
  }

  @MainActor func testPausingDuringDelayedLoadKeepsSavedItemsAndConsentOff() async throws {
    struct DelayedStorage: ClipboardHistoryStorage {
      let file: ClipboardHistoryFile
      let entered: DispatchSemaphore
      let release: DispatchSemaphore
      func load() throws -> ClipboardHistoryState? {
        entered.signal()
        guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileReadUnknown) }
        return try file.load()
      }
      func save(_ entries: [ClipboardHistoryEntry], enabled: Bool, capacity: Int) throws { try file.save(entries, enabled: enabled, capacity: capacity) }
      func delete() throws { try file.delete() }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = ClipboardHistoryFile(url: directory.appendingPathComponent("history.json"))
    try file.save([ClipboardHistoryEntry(id: UUID().uuidString.lowercased(), text: "Keep", origin: "mac", timestamp: Date(), credential: nil)])
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let history = ClipboardHistory(storage: DelayedStorage(file: file, entered: entered, release: release))
    try await until { entered.wait(timeout: .now()) == .success }
    history.setEnabled(false); release.signal()
    try await until { self.savedCollectionEnabled(file.url) == false }
    XCTAssertFalse(history.enabled); XCTAssertEqual(history.entries.map(\.text), ["Keep"])
  }

  @MainActor func testFullTrayPreviewKeepsLongUnicodeTextScrollableInBothThemes() throws {
    let folder = URL(fileURLWithPath: "/tmp/anice-tray-preview-renders", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let text = String(repeating: "Full clipboard text 👋\nA second line with https://example.com and code { }\n", count: 150)
    let entry = ClipboardHistoryEntry(id: UUID().uuidString.lowercased(), text: text, origin: "phone", timestamp: Date(), credential: nil)
    for scheme in [ColorScheme.light, .dark] {
      for width: CGFloat in [560, 760] {
        let content = PasteTrayExpandedPreview(entry: entry).padding(16)
          .frame(width: width, height: 320)
          .background(AniCePalette.surface(scheme))
          .foregroundStyle(AniCePalette.primaryText(scheme))
          .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: content)
        host.frame.size = host.fittingSize; host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.width, width); XCTAssertEqual(host.bounds.height, 320)
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:]))
          .write(to: folder.appendingPathComponent("preview-\(Int(width))-\(scheme).png"))
      }
    }
  }

  @MainActor func testClipboardPauseAndResume() async throws {
    let native = ClipboardNativeFake(), history = ClipboardHistory()
    let model = MacClipboardModel(native: native, history: history)
    XCTAssertFalse(model.isPaused)
    XCTAssertNil(model.pauseDeadline)
    XCTAssertNil(model.pauseStatusText)

    model.pause(for: .untilTurnedOn)
    XCTAssertTrue(model.isPaused)
    XCTAssertNil(model.pauseDeadline)
    XCTAssertEqual(model.pauseStatusText, "Paused until turned on")

    model.pause(for: .minutes11)
    XCTAssertTrue(model.isPaused)
    XCTAssertNotNil(model.pauseDeadline)
    XCTAssertEqual(model.pauseStatusText, "Paused (11m)")

    model.pause(for: .hours3)
    XCTAssertTrue(model.isPaused)
    XCTAssertEqual(model.pauseStatusText, "Paused (3h)")

    model.resume()
    XCTAssertFalse(model.isPaused)
    XCTAssertNil(model.pauseDeadline)
    XCTAssertNil(model.pauseStatusText)
    model.invalidate()
  }

  @MainActor func testMultiDeleteAndCopyText() async throws {
    let native = ClipboardNativeFake(), history = ClipboardHistory()
    history.setEnabled(true); try await until { history.enabled }
    for i in 1...5 {
      history.record(ClipboardSample(text: "Item \(i)"), origin: "mac")
    }
    try await until { history.entries.count == 5 }
    let model = MacClipboardModel(native: native, history: history)

    // Test copyText functionality
    XCTAssertTrue(model.copyText("Combined text\nItem 2"))
    XCTAssertEqual(native.sample?.text, "Combined text\nItem 2")
    XCTAssertEqual(model.status, "Copied")

    // Test atomic multi-item deletion via model
    let toDelete = Set([history.entries[1].id, history.entries[3].id])
    model.deleteHistory(ids: toDelete)
    try await until { history.entries.count == 3 }
    let remainingTexts = history.entries.map(\.text)
    XCTAssertFalse(remainingTexts.contains("Item 2"))
    XCTAssertFalse(remainingTexts.contains("Item 4"))
    XCTAssertTrue(remainingTexts.contains("Item 5"))
    XCTAssertTrue(remainingTexts.contains("Item 3"))
    XCTAssertTrue(remainingTexts.contains("Item 1"))

    model.invalidate()
  }

}
