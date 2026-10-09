// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest

@testable import aniCe

private actor ChannelMailbox {
  var messages = [Data]()
  var data = [Data]()
  var secured = 0
  func append(_ message: Data) { messages.append(message) }
  func take() -> Data { messages.removeFirst() }
  func record(_ bytes: Data) { data.append(bytes) }
  func secure() { secured += 1 }
}
private actor ChannelFailureProbe {
  private let kind: UInt8
  private let server: Bool
  private(set) var injected = false
  init(_ kind: UInt8, _ server: Bool) {
    self.kind = kind
    self.server = server
  }
  func check(_ bytes: Data, _ fromServer: Bool) throws {
    if bytes.first == kind, server == fromServer {
      injected = true
      throw SessionFailure.authentication
    }
  }
}
private actor ChannelSubmissionGate {
  private var resume: CheckedContinuation<Void, Never>?
  private(set) var entered = false
  func pause() async {
    entered = true
    await withCheckedContinuation { resume = $0 }
  }
  func release() {
    resume?.resume()
    resume = nil
  }
}
private final class ChannelClock: @unchecked Sendable {
  private let lock = NSLock()
  private var instant: TimeInterval = 0
  func read() -> TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return instant
  }
  func set(_ value: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    instant = value
  }
}
final class SessionChannelTests: XCTestCase, @unchecked Sendable {
  private let helper = SessionTests()
  private func b(_ v: [String: Any], _ name: String) throws -> Data { try helper.b(v, name) }
  private func reject(_ reason: SessionFailure, _ action: () async throws -> Void) async throws {
    do {
      try await action()
      XCTFail("Expected \(reason)")
    } catch let error as SessionFailure { XCTAssertEqual(error, reason) }
  }
  func testIndependentControlFixturesAndDispatcherBounds() throws {
    let root = try helper.root("control-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(valid.count, 3)
    XCTAssertGreaterThanOrEqual(invalid.count, 15)
    for row in valid {
      let kind = try XCTUnwrap(ControlKind(rawValue: XCTUnwrap(row["type"] as? Int64)))
      let expected = SessionControl(kind: kind, value: try XCTUnwrap(row["value"] as? Int64))
      let bytes = try b(row, "payload")
      XCTAssertEqual(try expected.encode(), bytes)
      XCTAssertEqual(try SessionControl.decode(bytes), expected)
      XCTAssertEqual(try SessionControl.application(bytes), expected)
    }
    for row in invalid {
      let reason = try XCTUnwrap(SessionFailure(rawValue: XCTUnwrap(row["reason"] as? String)))
      XCTAssertThrowsError(try SessionControl.decode(b(row, "payload"))) {
        XCTAssertEqual($0 as? SessionFailure, reason)
      }
    }
    XCTAssertNil(try SessionControl.application(Data("aniCe connection check".utf8)))
    XCTAssertNil(try SessionControl.application(SessionCbor.encode(.array([.text("other")]))))
    XCTAssertThrowsError(try SessionControl.application(Data([0x84]))) {
      XCTAssertEqual($0 as? SessionFailure, .malformed)
    }
    XCTAssertThrowsError(try SessionControl(kind: .ping, value: -1).encode()) {
      XCTAssertEqual($0 as? SessionFailure, .malformed)
    }
  }
  private func controlPair(_ initialID: Int64 = 0) throws -> (SessionLiveness, SessionLiveness) {
    var c = SessionLiveness(responder: false, nextId: initialID)
    var s = SessionLiveness(responder: true)
    try c.start(0); try s.start(0)
    let hello = try XCTUnwrap(c.pending)
    try c.issuing(hello, 0); c.submitted(hello, 0); try s.receive(hello, 0)
    let ack = try XCTUnwrap(s.pending)
    try s.issuing(ack, 0); s.submitted(ack, 0); try c.receive(ack, 0)
    return (c, s)
  }
  func testControlOrderingDeadlinesAndUnsignedBoundaries() throws {
    var (c, s) = try controlPair()
    XCTAssertEqual(c.support, true); XCTAssertEqual(s.support, true)
    try c.poll(59999); XCTAssertNil(c.pending)
    try c.poll(60000)
    let ping = try XCTUnwrap(c.pending)
    XCTAssertEqual(ping, SessionControl(kind: .ping, value: 0))
    try c.poll(60001); XCTAssertEqual(c.pending, ping)
    try c.issuing(ping, 60001); c.submitted(ping, 60001)
    try c.poll(70000); XCTAssertNil(c.pending)
    XCTAssertThrowsError(try c.receive(SessionControl(kind: .pong, value: 1), 70000)) {
      XCTAssertEqual($0 as? SessionFailure, .state)
    }
    try s.receive(ping, 70000)
    let pong = try XCTUnwrap(s.pending)
    try s.issuing(pong, 70000); s.submitted(pong, 70000); try c.receive(pong, 70000)
    XCTAssertThrowsError(try c.receive(pong, 70001)) { XCTAssertEqual($0 as? SessionFailure, .state) }
    XCTAssertThrowsError(try s.receive(ping, 70001)) { XCTAssertEqual($0 as? SessionFailure, .state) }
    XCTAssertThrowsError(try s.receive(SessionControl(kind: .renewalRequest), 70001)) {
      XCTAssertEqual($0 as? SessionFailure, .state)
    }
    try c.poll(130001); XCTAssertEqual(c.pending, SessionControl(kind: .ping, value: 1))
    var lost = try controlPair().0
    try lost.poll(60000)
    let waiting = try XCTUnwrap(lost.pending)
    try lost.issuing(waiting, 60000); lost.submitted(waiting, 60000)
    lost.activity(79999) // Authenticated data cannot satisfy an outstanding PING.
    XCTAssertThrowsError(try lost.receive(SessionControl(kind: .pong, value: 0), 80000)) {
      XCTAssertEqual($0 as? SessionFailure, .controlTimeout)
    }
    XCTAssertThrowsError(try lost.poll(80000)) { XCTAssertEqual($0 as? SessionFailure, .controlTimeout) }
    var max = try controlPair(0xffffffff).0
    try max.poll(60000)
    let final = try XCTUnwrap(max.pending)
    try max.issuing(final, 60000); max.submitted(final, 60000)
    try max.receive(SessionControl(kind: .pong, value: 0xffffffff), 60000)
    XCTAssertThrowsError(try max.poll(120000)) { XCTAssertEqual($0 as? SessionFailure, .controlTimeout) }
    var legacy = SessionLiveness(responder: false)
    try legacy.start(0)
    XCTAssertThrowsError(try legacy.receive(SessionControl(kind: .helloAck), 0)) {
      XCTAssertEqual($0 as? SessionFailure, .state)
    }
    try legacy.poll(10000); XCTAssertEqual(legacy.support, false); XCTAssertNil(legacy.pending)
    XCTAssertThrowsError(try legacy.receive(SessionControl(kind: .helloAck), 10000)) {
      XCTAssertEqual($0 as? SessionFailure, .state)
    }
  }
  func testEncryptedControlsBackpressureLegacyFallbackAndHardLifetime() async throws {
    let v = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    for serverControls in [true, false] {
      let clock = ChannelClock()
      let outI = ChannelMailbox(), outR = ChannelMailbox()
      let c = SessionConnection(
        handshake: try helper.engine(v, server: false), responder: false,
        capacity: { _ in clock.read() != 60 }, submit: { await outI.append($0) },
        data: { await outI.record($0) }, secured: { await outI.secure() }, controls: true,
        now: { Int64(clock.read() * 1000) })
      let s = SessionConnection(
        handshake: try helper.engine(v, server: true), responder: true, capacity: { _ in true },
        submit: { await outR.append($0) }, data: { await outR.record($0) },
        secured: { await outR.secure() }, controls: serverControls,
        now: { Int64(clock.read() * 1000) })
      func pump() async throws {
        for _ in 0..<32 {
          let hasI = await !outI.messages.isEmpty, hasR = await !outR.messages.isEmpty
          if !hasI && !hasR { return }
          if hasI { try await s.receive(outI.take()) }
          if await !outR.messages.isEmpty { try await c.receive(outR.take()) }
        }
        XCTFail("Unbounded control exchange")
      }
      try await c.start(); try await pump()
      if serverControls {
        let clientSupport = await c.controlSupport, serverSupport = await s.controlSupport
        XCTAssertEqual(clientSupport, true); XCTAssertEqual(serverSupport, true)
        clock.set(60); try await c.tick()
        let blocked = await outI.messages
        XCTAssertTrue(blocked.isEmpty)
        clock.set(61); try await c.tick(); try await pump()
        clock.set(121); try await c.tick(); try await pump()
        let internalData = await outR.data
        XCTAssertTrue(internalData.isEmpty)
      } else {
        clock.set(10); try await c.tick()
        let support = await c.controlSupport
        XCTAssertEqual(support, false)
      }
      let before = await outR.data.count
      try await c.sendData(Data("aniCe connection check".utf8)); try await pump()
      let after = await outR.data.count
      XCTAssertEqual(after, before + 1)
      clock.set(3600)
      try await reject(.expired) { try await c.tick() }
      let reason = await c.expiration, closed = await c.isClosed
      XCTAssertEqual(reason, .lifetime); XCTAssertTrue(closed)
      await c.close(); await s.close()
    }
  }
  func testRenewalMarginsAndEncryptedRetirementRaces() async throws {
    let threshold = (UInt64(1) << 20) - 1024
    XCTAssertNil(SecureSession.renewalReason(age: 3299.999, sent: threshold - 1, received: threshold - 1))
    XCTAssertEqual(SecureSession.renewalReason(age: 3300, sent: 0, received: 0), 1)
    XCTAssertEqual(SecureSession.renewalReason(age: 0, sent: threshold, received: 0), 2)
    XCTAssertEqual(SecureSession.renewalReason(age: 0, sent: 0, received: threshold), 2)
    var (lc, ls) = try controlPair()
    try lc.requestRenewal(2); try ls.requestRenewal(1); try ls.poll(1)
    let request = try XCTUnwrap(ls.pending)
    try lc.receive(request, 1); try lc.receive(request, 2)
    XCTAssertEqual(lc.renewalReason, 2)
    try ls.issuing(request, 2); ls.submitted(request, 2); try ls.poll(3)
    XCTAssertNil(ls.pending)
    let v = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    for fault in ["none", "submission", "stop"] {
      let clock = ChannelClock(), outI = ChannelMailbox(), outR = ChannelMailbox()
      let c = SessionConnection(handshake: try helper.engine(v, server: false), responder: false,
        capacity: { _ in true }, submit: { await outI.append($0) }, data: { await outI.record($0) },
        secured: {}, controls: true, now: { Int64(clock.read() * 1000) }, renew: true)
      let s = SessionConnection(handshake: try helper.engine(v, server: true), responder: true,
        capacity: { _ in clock.read() != 3300 }, submit: {
          if fault == "submission" && clock.read() > 3300 { throw SessionFailure.authentication }
          await outR.append($0)
        }, data: { await outR.record($0) }, secured: {}, controls: true,
        now: { Int64(clock.read() * 1000) }, renew: true)
      func pump() async throws {
        for _ in 0..<32 {
          let hasI = await !outI.messages.isEmpty, hasR = await !outR.messages.isEmpty
          if !hasI && !hasR { return }
          if hasI { try await s.receive(outI.take()) }
          if await !outR.messages.isEmpty { try await c.receive(outR.take()) }
        }
        XCTFail("Unbounded renewal exchange")
      }
      try await c.start(); try await pump()
      for minute in 1...54 { clock.set(Double(minute * 60)); try await c.tick(); try await pump() }
      clock.set(3300); try await s.tick()
      let blocked = await outR.messages
      XCTAssertTrue(blocked.isEmpty)
      do { try await s.sendData(Data([1])); XCTFail("Application escaped renewal") }
      catch is SessionBackpressure {}
      clock.set(3301)
      if fault == "stop" {
        await s.close()
        try await reject(.cancelled) { try await s.tick() }
        let queued = await outR.messages; XCTAssertTrue(queued.isEmpty)
      } else if fault == "submission" {
        try await reject(.authentication) { try await s.tick() }
        let closed = await s.isClosed; XCTAssertTrue(closed)
      } else {
        try await c.tick(); try await s.tick(); try await pump()
        let reason = await c.renewalReason; XCTAssertEqual(reason, 1)
        do { try await c.sendData(Data([1])); XCTFail("Application escaped renewal") }
        catch is SessionBackpressure {}
        try await c.disconnect(); try await pump()
        let closedC = await c.isClosed, closedS = await s.isClosed
        XCTAssertTrue(closedC); XCTAssertTrue(closedS)
      }
      let deliveredI = await outI.data, deliveredR = await outR.data
      XCTAssertTrue(deliveredI.isEmpty); XCTAssertTrue(deliveredR.isEmpty)
      await c.close(); await s.close()
    }
  }
  func testIndependentRecordsUnsignedCountersAndAllNegatives() async throws {
    let root = try helper.root("record-vectors")
    let rows = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(rows.count, 3)
    XCTAssertGreaterThanOrEqual(invalid.count, 15)
    for v in rows {
      let direction = try XCTUnwrap(v["direction"] as? UInt8)
      let kind = try XCTUnwrap(RecordKind(rawValue: XCTUnwrap(v["kind"] as? UInt8)))
      let sequence = try XCTUnwrap(UInt64(XCTUnwrap(v["sequence"] as? String)))
      let record = try SessionRecordCodec.seal(
        key: b(v, "key"), iv: b(v, "iv"), id: b(v, "session"), direction: direction, kind: kind,
        sequence: sequence, plaintext: b(v, "plain"))
      XCTAssertEqual(record, try b(v, "record"))
      XCTAssertEqual(try SessionRecordCodec.nonce(b(v, "iv"), sequence), try b(v, "nonce"))
      let result = try SessionRecordCodec.open(
        key: b(v, "key"), iv: b(v, "iv"), id: b(v, "session"), direction: direction,
        expected: sequence, record: record)
      XCTAssertEqual(result.1, try b(v, "plain"))
    }
    for v in invalid {
      let reason = try XCTUnwrap(SessionFailure(rawValue: XCTUnwrap(v["reason"] as? String)))
      try await reject(reason) {
        _ = try SessionRecordCodec.open(
          key: self.b(v, "key"), iv: self.b(v, "iv"), id: self.b(v, "session"),
          direction: XCTUnwrap(v["direction"] as? UInt8),
          expected: XCTUnwrap(UInt64(XCTUnwrap(v["sequence"] as? String))),
          record: self.b(v, "record"))
      }
    }
  }
  func testEncryptedControlFailuresRetireWithoutApplicationDelivery() async throws {
    let v = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    let faults = ["wrongPong", "missingPong", "malformed", "submission", "retirement"]
    XCTAssertEqual(faults.count, 5)
    for fault in faults {
      let clock = ChannelClock(), gate = ChannelSubmissionGate()
      let outI = ChannelMailbox(), outR = ChannelMailbox()
      let c = SessionConnection(
        handshake: try helper.engine(v, server: false), responder: false, capacity: { _ in true },
        submit: {
          if clock.read() >= 60 && fault == "submission" { throw SessionFailure.authentication }
          if clock.read() >= 60 && fault == "retirement" { await gate.pause() }
          await outI.append($0)
        }, data: { await outI.record($0) }, secured: {}, controls: true,
        now: { Int64(clock.read() * 1000) })
      let s = SessionConnection(
        handshake: try helper.engine(v, server: true), responder: true, capacity: { _ in true },
        submit: { await outR.append($0) }, data: { await outR.record($0) }, secured: {},
        controls: true, now: { Int64(clock.read() * 1000) })
      func pump() async throws {
        for _ in 0..<32 {
          let hasI = await !outI.messages.isEmpty, hasR = await !outR.messages.isEmpty
          if !hasI && !hasR { return }
          if hasI { try await s.receive(outI.take()) }
          if await !outR.messages.isEmpty { try await c.receive(outR.take()) }
        }
        XCTFail("Unbounded control exchange")
      }
      try await c.start(); try await pump()
      switch fault {
      case "wrongPong":
        try await s.sendData(SessionControl(kind: .pong, value: 7).encode())
        try await reject(.state) { try await c.receive(outR.take()) }
      case "malformed":
        try await s.sendData(Data([0x84]))
        try await reject(.malformed) { try await c.receive(outR.take()) }
      case "missingPong":
        clock.set(60); try await c.tick(); try await s.receive(outI.take())
        clock.set(80)
        try await reject(.controlTimeout) { try await c.tick() }
      case "retirement":
        clock.set(60)
        let pending = Task { try await c.tick() }
        for _ in 0..<100 where await !gate.entered { try await Task.sleep(for: .milliseconds(1)) }
        let entered = await gate.entered
        XCTAssertTrue(entered)
        await c.close(); await gate.release()
        try await reject(.cancelled) { try await pending.value }
      default:
        clock.set(60)
        try await reject(.authentication) { try await c.tick() }
      }
      let closed = await c.isClosed, i = await outI.data, r = await outR.data
      XCTAssertTrue(closed); XCTAssertTrue(i.isEmpty); XCTAssertTrue(r.isEmpty)
      await c.close(); await s.close()
    }
  }
  func testCodecRejectsInvalidMaterialAndSealBounds() async throws {
    let cases = [
      (0, 12, 32), (16, 12, 32), (31, 12, 32), (33, 12, 32), (32, 0, 32), (32, 11, 32),
      (32, 13, 32), (32, 12, 0), (32, 12, 31), (32, 12, 33),
    ]
    XCTAssertGreaterThanOrEqual(cases.count, 10)
    for (key, iv, id) in cases {
      try await reject(.malformed) {
        _ = try SessionRecordCodec.seal(
          key: Data(count: key), iv: Data(count: iv), id: Data(count: id), direction: 1,
          kind: .data, sequence: 0, plaintext: Data())
      }
    }
    for direction: UInt8 in [0, 3] {
      try await reject(.malformed) {
        _ = try SessionRecordCodec.seal(
          key: Data(count: 32), iv: Data(count: 12), id: Data(count: 32), direction: direction,
          kind: .data, sequence: 0, plaintext: Data())
      }
    }
    try await reject(.malformed) {
      _ = try SessionRecordCodec.seal(
        key: Data(count: 32), iv: Data(count: 12), id: Data(count: 32), direction: 1, kind: .data,
        sequence: 0, plaintext: Data(count: 4001))
    }
    try await reject(.malformed) {
      _ = try SessionRecordCodec.seal(
        key: Data(count: 32), iv: Data(count: 12), id: Data(count: 32), direction: 1, kind: .ready,
        sequence: 0, plaintext: Data([1]))
    }
    try await reject(.malformed) { _ = try SessionRecordCodec.nonce(Data(count: 11), 0) }
  }
  private func channel(
    now: @escaping @Sendable () -> TimeInterval = { 0 },
    validate: @escaping @Sendable () async throws -> Void = {},
    capacity: @escaping @Sendable (Int) async -> Bool = { _ in true },
    submit: @escaping @Sendable (Data) async throws -> Void = { _ in }
  ) throws -> SecureSession {
    let v = try XCTUnwrap((helper.root("record-vectors")["valid"] as? [[String: Any]])?.first)
    return try SecureSession(
      responder: false, sendKey: b(v, "key"), receiveKey: b(v, "key"), sendIV: b(v, "iv"),
      receiveIV: b(v, "iv"), sessionID: b(v, "session"), validate: validate, capacity: capacity,
      submit: submit, now: now)
  }
  func testEarlyDataAndTransportFailureBurnNonce() async throws {
    let early = try channel()
    try await reject(.state) { try await early.send(.data, plaintext: Data([1])) }
    let earlyStage = await early.stage
    let earlySent = await early.sent
    XCTAssertEqual(earlyStage, .closed)
    XCTAssertEqual(earlySent, 0)
    let failed = try channel(submit: { _ in throw SessionFailure.authentication })
    try await reject(.authentication) { try await failed.send(.ready) }
    try await reject(.cancelled) { try await failed.send(.ready) }
    let sent = await failed.sent
    let stage = await failed.stage
    XCTAssertEqual(sent, 1)
    XCTAssertEqual(stage, .closed)
    let changedCapacity = try channel(submit: { _ in throw SessionBackpressure() })
    try await reject(.state) { try await changedCapacity.send(.ready) }
    let burned = await changedCapacity.sent
    let retired = await changedCapacity.stage
    XCTAssertEqual(burned, 1)
    XCTAssertEqual(retired, .closed)
    let full = try channel(capacity: { _ in false })
    do {
      try await full.send(.ready)
      XCTFail("Expected backpressure")
    } catch is SessionBackpressure {}
    let count = await full.sent
    let waiting = await full.stage
    XCTAssertEqual(count, 0)
    XCTAssertEqual(waiting, .waiting)
  }
  func testTimeoutAndTrustRevocationCloseWithoutSending() async throws {
    let clock = ChannelClock()
    let expired = try channel(now: { clock.read() })
    clock.set(10)
    try await reject(.expired) { try await expired.tick() }
    let readinessReason = await expired.expiration
    XCTAssertEqual(readinessReason, .readiness)
    let stage = await expired.stage
    XCTAssertEqual(stage, .closed)
    let revoked = try channel(validate: { throw SessionFailure.untrustedPeer })
    try await reject(.untrustedPeer) { try await revoked.send(.ready) }
    let count = await revoked.sent
    XCTAssertEqual(count, 0)
  }
  func testCompleteReadinessBidirectionalDataAndCloseOverMtu23() async throws {
    let v = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    let outI = ChannelMailbox()
    let outR = ChannelMailbox()
    let c = SessionConnection(
      handshake: try helper.engine(v, server: false), responder: false, capacity: { _ in true },
      submit: { await outI.append($0) }, data: { await outI.record($0) },
      secured: { await outI.secure() })
    let s = SessionConnection(
      handshake: try helper.engine(v, server: true), responder: true, capacity: { _ in true },
      submit: { await outR.append($0) }, data: { await outR.record($0) },
      secured: { await outR.secure() })
    var incomingI = GattReassembler(version: 2)
    var incomingR = GattReassembler(version: 2)
    func deliver(
      _ queue: ChannelMailbox, _ to: SessionConnection, _ incoming: inout GattReassembler,
      _ id: UInt64
    ) async throws {
      let bytes = await queue.take()
      for frame in try GattReassembler.fragments(bytes, id: id, capacity: 20, version: 2) {
        if let complete = try incoming.receive(frame) { try await to.receive(complete) }
      }
    }
    try await c.start()
    try await deliver(outI, s, &incomingR, 0)
    try await deliver(outR, c, &incomingI, 0)
    try await deliver(outI, s, &incomingR, 1)
    try await deliver(outR, c, &incomingI, 1)
    let beforeI = await outI.secured
    let beforeR = await outR.secured
    XCTAssertEqual(beforeI, 0)
    XCTAssertEqual(beforeR, 0)
    try await deliver(outI, s, &incomingR, 2)
    let afterI = await outI.secured
    let afterR = await outR.secured
    XCTAssertEqual(afterI, 0)
    XCTAssertEqual(afterR, 1)
    try await deliver(outR, c, &incomingI, 2)
    let ready = await outI.secured
    XCTAssertEqual(ready, 1)
    let bytes = Data((0..<4000).map { UInt8(truncatingIfNeeded: $0) })
    try await c.sendData(bytes)
    try await deliver(outI, s, &incomingR, 3)
    try await s.sendData(Data([7]))
    try await deliver(outR, c, &incomingI, 3)
    let serverData = await outR.data
    let clientData = await outI.data
    XCTAssertEqual(serverData, [bytes])
    XCTAssertEqual(clientData, [Data([7])])
    try await s.disconnect()
    try await deliver(outR, c, &incomingI, 4)
    let ci = await c.isClosed
    let sr = await s.isClosed
    XCTAssertTrue(ci)
    XCTAssertTrue(sr)
    let peerClosed = await c.closedByPeer
    let localClosed = await s.closedByPeer
    XCTAssertTrue(peerClosed)
    XCTAssertFalse(localClosed)
    try await reject(.cancelled) { try await c.tick() }
    let retained = await c.closedByPeer
    XCTAssertTrue(retained)
  }
  func testRecordCountQueueSaturationIdleAndLifetimeLimits() async throws {
    var counter = RecordSequence()
    for i in 0..<(1 << 20) { XCTAssertEqual(try counter.reserve(), UInt64(i)) }
    try await reject(.expired) { _ = try counter.reserve() }
    XCTAssertEqual(counter.value, 1 << 20)
    var queue = GattQueueBudget()
    for _ in 0..<8 { try queue.reserve(4096) }
    XCTAssertEqual(queue.bytes, 32768)
    XCTAssertFalse(queue.canReserve(1))
    do {
      try queue.reserve(1)
      XCTFail("Expected backpressure")
    } catch is SessionBackpressure {}
    XCTAssertEqual(queue.messages, 8)
    queue.release(4096)
    try queue.reserve(4096)
    queue.clear()
    XCTAssertEqual(queue.bytes, 0)
    XCTAssertFalse(queue.canReserve(4097))
    XCTAssertFalse(queue.canReserve(0))
    let v = try XCTUnwrap((helper.root("record-vectors")["valid"] as? [[String: Any]])?.first)
    let ack = try SessionRecordCodec.seal(
      key: b(v, "key"), iv: b(v, "iv"), id: b(v, "session"), direction: 2, kind: .readyAck,
      sequence: 0, plaintext: Data())
    func ready(_ clock: ChannelClock) async throws -> SecureSession {
      let ch = try channel(now: { clock.read() })
      try await ch.send(.ready)
      _ = try await ch.receive(ack)
      return ch
    }
    let clock = ChannelClock()
    let idle = try await ready(clock)
    clock.set(120)
    try await reject(.expired) { try await idle.tick() }
    let idleReason = await idle.expiration
    XCTAssertEqual(idleReason, .idle)
    let closed = await idle.stage
    XCTAssertEqual(closed, .closed)
    clock.set(0)
    let age = try await ready(clock)
    for time in stride(from: 100, through: 3500, by: 100) {
      clock.set(TimeInterval(time))
      try await age.send(.data)
    }
    clock.set(3600)
    try await reject(.expired) { try await age.tick() }
    let lifetimeReason = await age.expiration
    XCTAssertEqual(lifetimeReason, .lifetime)
    for sequence: UInt64 in [0, 2, UInt64.max] {
      clock.set(0)
      let ch = try await ready(clock)
      let record = try SessionRecordCodec.seal(
        key: b(v, "key"), iv: b(v, "iv"), id: b(v, "session"), direction: 2, kind: .data,
        sequence: sequence, plaintext: Data([1]))
      try await reject(.authentication) { _ = try await ch.receive(record) }
      let received = await ch.received
      let stage = await ch.stage
      XCTAssertEqual(received, 1)
      XCTAssertEqual(stage, .closed)
    }
  }
  func testSubmissionFailureAtEveryHandshakeAndReadinessTransition() async throws {
    let v = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    let targets: [(UInt8, Bool)] = [
      (1, false), (2, true), (3, false), (4, true), (6, false), (6, true),
    ]
    for target in targets {
      let outI = ChannelMailbox()
      let outR = ChannelMailbox()
      let probe = ChannelFailureProbe(target.0, target.1)
      let c = SessionConnection(
        handshake: try helper.engine(v, server: false), responder: false, capacity: { _ in true },
        submit: {
          try await probe.check($0, false)
          await outI.append($0)
        }, data: { await outI.record($0) }, secured: { await outI.secure() })
      let s = SessionConnection(
        handshake: try helper.engine(v, server: true), responder: true, capacity: { _ in true },
        submit: {
          try await probe.check($0, true)
          await outR.append($0)
        }, data: { await outR.record($0) }, secured: { await outR.secure() })
      try await reject(.authentication) {
        try await c.start()
        for _ in 0..<6 {
          if await !outI.messages.isEmpty { try await s.receive(outI.take()) }
          if await !outR.messages.isEmpty { try await c.receive(outR.take()) }
        }
      }
      let injected = await probe.injected
      let readyI = await outI.secured
      let readyR = await outR.secured
      let dataI = await outI.data
      let dataR = await outR.data
      XCTAssertTrue(injected)
      XCTAssertEqual(readyI, 0)
      XCTAssertEqual(readyR, 0)
      XCTAssertTrue(dataI.isEmpty)
      XCTAssertTrue(dataR.isEmpty)
      let closed = await (target.1 ? s : c).isClosed
      XCTAssertTrue(closed)
      await c.close()
      await s.close()
    }
  }
  func testCloseDuringSuspendedSubmissionCannotReviveChannel() async throws {
    let gate = ChannelSubmissionGate()
    let ch = try channel(submit: { _ in await gate.pause() })
    let sending = Task { try await self.reject(.cancelled) { try await ch.send(.ready) } }
    for _ in 0..<200 {
      if await gate.entered { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    let entered = await gate.entered
    XCTAssertTrue(entered)
    do {
      try await ch.send(.ready)
      XCTFail("Concurrent send must return backpressure")
    } catch is SessionBackpressure {}
    let before = await ch.sent
    XCTAssertEqual(before, 1)
    await ch.close()
    await gate.release()
    try await sending.value
    let stage = await ch.stage
    let count = await ch.sent
    XCTAssertEqual(stage, .closed)
    XCTAssertEqual(count, 1)
  }
  func testAdmissionWindowCandidateExclusivityFailureCapAndExpiry() {
    var admission = SessionAdmissionWindow()
    XCTAssertFalse(admission.claim(0))
    admission.open(0)
    XCTAssertEqual(admission.deadline, 120)
    admission.open(50)
    XCTAssertEqual(admission.deadline, 120)
    for index in 0..<5 {
      XCTAssertTrue(admission.claim(Double(index)))
      XCTAssertFalse(admission.claim(Double(index)))
      XCTAssertEqual(admission.retire(Double(index)), index < 4)
    }
    XCTAssertFalse(admission.claim(6))
    XCTAssertEqual(admission.failures, 5)
    admission.clear()
    admission.open(100)
    XCTAssertTrue(admission.claim(219.999))
    XCTAssertFalse(admission.retire(220))
    XCTAssertFalse(admission.claim(220))
    admission.clear()
    XCTAssertNil(admission.deadline)
    XCTAssertFalse(admission.admitted)
  }
  func testCachedSubscriptionReadmissionRequiresFreshWindowAndExclusiveSlot() {
    // Every combination of the native admission facts, including stale/retired subscriptions.
    var accepted = 0
    var rejected = 0
    for bits in 0..<32 {
      let allowed = GattCandidateAdmission.mayReuseSubscription(
        hasCandidate: bits & 1 != 0, advertising: bits & 2 != 0,
        subscribed: bits & 4 != 0, retired: bits & 8 != 0, blocked: bits & 16 != 0)
      if allowed { accepted += 1 } else { rejected += 1 }
      XCTAssertEqual(allowed, bits == 6)
    }
    XCTAssertEqual(accepted, 1)
    XCTAssertEqual(rejected, 31)
    var window = SessionAdmissionWindow()
    window.open(0)
    XCTAssertTrue(window.claim(1))
    XCTAssertFalse(window.claim(2), "A second subscribed phone cannot join the admitted candidate")
    XCTAssertTrue(window.retire(3))
    XCTAssertFalse(window.claim(120), "Cached subscription cannot extend the original window")
  }
  func testFragmentBoundsAndAssemblyDeadline() async throws {
    let data = Data(repeating: 5, count: 4096)
    let frames = try GattReassembler.fragments(data, id: 0, capacity: 20, version: 2)
    XCTAssertEqual(frames.count, 373)
    var assembly = GattReassembler(version: 2)
    var result: Data?
    for frame in frames { result = try assembly.receive(frame) }
    XCTAssertEqual(result, data)
    var bad = [Data(), Data(frames[0].prefix(9)), frames[1]]
    for offset in 0...8 {
      var bytes = [UInt8](frames[0])
      bytes[offset] ^= 1
      bad.append(Data(bytes))
    }
    for bytes in bad {
      try await reject(.malformed) {
        var fresh = GattReassembler(version: 2)
        _ = try fresh.receive(bytes)
      }
    }
    let clock = ChannelClock()
    var timed = GattReassembler(version: 2, now: { clock.read() })
    _ = try timed.receive(frames[0])
    clock.set(10)
    try await reject(.expired) { try timed.tick() }
    try await reject(.malformed) {
      _ = try GattReassembler.fragments(data, id: UInt64(UInt32.max) + 1, capacity: 20, version: 2)
    }
    XCTAssertFalse(
      try GattReassembler.fragments(Data([1]), id: UInt64(UInt32.max), capacity: 20, version: 2)
        .isEmpty)
  }
}
