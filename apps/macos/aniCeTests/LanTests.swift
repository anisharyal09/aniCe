// SPDX-License-Identifier: GPL-3.0-or-later
// Probes LAN framing, peer reservations and admission under malformed and stale operations.
import CryptoKit
import Foundation
import Network
import XCTest

@testable import aniCe

final class LanTests: XCTestCase {
  @MainActor func testTCPPeerLossDetectionDoesNotWaitForDefaultIdleTimeouts() throws {
    let parameters = LanTcpTransport.parameters()
    let options = try XCTUnwrap(
      parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
    XCTAssertTrue(options.noDelay)
    XCTAssertTrue(options.enableKeepalive)
    XCTAssertGreaterThan(options.keepaliveIdle, 0)
    XCTAssertGreaterThan(options.keepaliveCount, 0)
    XCTAssertGreaterThan(options.keepaliveInterval, 0)
    XCTAssertLessThanOrEqual(
      options.keepaliveIdle + options.keepaliveCount * options.keepaliveInterval, 30)
    XCTAssertGreaterThan(options.connectionDropTime, 0)
    XCTAssertLessThanOrEqual(options.connectionDropTime, 30)
    XCTAssertFalse(parameters.includePeerToPeer)
    XCTAssertEqual(parameters.prohibitedInterfaceTypes?.contains(.loopback), true)
  }
  private let helper = SessionFixtures()
  private func feed(_ bytes: Data, into framing: inout LanFraming) throws -> [Data] {
    let time = try framing.beginBuffer()
    var offset = 0
    var result = [Data]()
    while offset < bytes.count {
      if let frame = try framing.feed(bytes, offset: &offset, receivedAt: time) { result.append(frame) }
    }
    return result
  }
  func testIndependentFixturesAndEverySplitPoint() throws {
    let root = try helper.root("lan-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(valid.count, 8)
    XCTAssertGreaterThanOrEqual(invalid.count, 10)
    for row in valid {
      let frame = try helper.b(row, "frame")
      let envelope = try helper.b(row, "envelope")
      XCTAssertEqual(try LanFraming.encode(envelope), frame)
      for split in 0...frame.count {
        var framing = LanFraming()
        let first = try feed(Data(frame.prefix(split)), into: &framing)
        let second = try feed(Data(frame.dropFirst(split)), into: &framing)
        XCTAssertEqual(first + second, [envelope])
        try framing.end()
      }
    }
    for row in invalid {
      var framing = LanFraming()
      let reason = try XCTUnwrap(SessionFailure(rawValue: XCTUnwrap(row["reason"] as? String)))
      XCTAssertThrowsError(
        try {
          _ = try feed(helper.b(row, "frame"), into: &framing)
          try framing.end()
        }()
      ) {
        XCTAssertEqual($0 as? SessionFailure, reason)
      }
      XCTAssertThrowsError(try feed(Data([1]), into: &framing)) {
        XCTAssertEqual($0 as? SessionFailure, .cancelled)
      }
    }
  }
  func testCoalescingAndSlowAssemblyCannotExtendDeadline() throws {
    let envelope = Data([1, 42])
    let frame = try LanFraming.encode(envelope)
    var framing = LanFraming()
    XCTAssertEqual(try feed(frame + frame + frame, into: &framing), [envelope, envelope, envelope])
    var clock: TimeInterval = 0
    var slow = LanFraming(now: { clock })
    XCTAssertNil(slow.nextDeadline)
    _ = try feed(Data([1]), into: &slow)
    XCTAssertEqual(slow.nextDeadline, 10)
    clock = 9.999
    _ = try feed(Data([0]), into: &slow)
    XCTAssertEqual(slow.nextDeadline, 10)
    clock = 10
    XCTAssertThrowsError(try feed(Data([0]), into: &slow)) { XCTAssertEqual($0 as? SessionFailure, .expired) }
    XCTAssertThrowsError(try slow.end()) { XCTAssertEqual($0 as? SessionFailure, .cancelled) }
    XCTAssertNil(slow.nextDeadline)
    for size in [0, 1, 4097] {
      XCTAssertThrowsError(try LanFraming.encode(Data(repeating: 0, count: size))) {
        XCTAssertEqual($0 as? SessionFailure, .malformed)
      }
    }
  }
  func testBufferClockIsSampledOnceAndSlicesPreserveOffsets() throws {
    var reads = 0
    var framing = LanFraming(now: { reads += 1; return 0 })
    let payload = Data(repeating: 7, count: 4096)
    let wire = try LanFraming.encode(payload)
    let slice = (Data([99, 99]) + wire).dropFirst(2)
    XCTAssertEqual(try feed(slice, into: &framing), [payload])
    XCTAssertEqual(reads, 1)
    for count in 1..<wire.count {
      var partial = LanFraming()
      _ = try feed(Data(wire.prefix(count)), into: &partial)
      XCTAssertThrowsError(try partial.end()) { XCTAssertEqual($0 as? SessionFailure, .malformed) }
      XCTAssertThrowsError(try partial.beginBuffer()) { XCTAssertEqual($0 as? SessionFailure, .cancelled) }
    }
  }

  func testBulkProbeIndependentOracleAndStandardIsolation() throws {
    let root = try helper.root("bulk-probe-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(valid.count, 3); XCTAssertGreaterThanOrEqual(invalid.count, 10)
    let key = try helper.b(root, "key"), iv = try helper.b(root, "iv"), id = try helper.b(root, "id")
    for row in valid {
      let size = try XCTUnwrap(row["length"] as? Int)
      let plain = Data((0..<size).map { UInt8($0 % 251) })
      let record = try SessionRecordCodec.seal(key: key, iv: iv, id: id, direction: 1,
        kind: .data, sequence: 0, plaintext: plain, profile: .bulkProbe)
      let digest = SHA256.hash(data: record).map { String(format: "%02x", $0) }.joined()
      XCTAssertEqual(digest, row["recordSHA256"] as? String)
      XCTAssertEqual(record.prefix(14), try helper.b(row, "header"))
      XCTAssertEqual(record.suffix(16), try helper.b(row, "tag"))
      XCTAssertEqual(try SessionRecordCodec.open(key: key, iv: iv, id: id, direction: 1,
        expected: 0, record: record, profile: .bulkProbe).1, plain)
      XCTAssertThrowsError(try SessionRecordCodec.open(key: key, iv: iv, id: id, direction: 1,
        expected: 0, record: record)) { XCTAssertEqual($0 as? SessionFailure, .malformed) }
    }
    for row in invalid {
      let reason = try XCTUnwrap(SessionFailure(rawValue: XCTUnwrap(row["reason"] as? String)))
      XCTAssertThrowsError(try SessionRecordCodec.open(key: key, iv: iv, id: id, direction: 1,
        expected: 0, record: helper.b(row, "record"), profile: .bulkProbe)) {
        XCTAssertEqual($0 as? SessionFailure, reason)
      }
    }
    XCTAssertThrowsError(try SessionRecordCodec.seal(key: key, iv: iv, id: id, direction: 1,
      kind: .data, sequence: 0, plaintext: Data(repeating: 0, count: 4194305), profile: .bulkProbe))
    XCTAssertThrowsError(try SessionEnvelope.encode(1, Data(repeating: 0, count: 4096), profile: .bulkProbe))
    let envelope = Data(repeating: 6, count: 4194335)
    let frame = try LanFraming.encode(envelope, profile: .bulkProbe)
    var bulk = LanFraming(profile: .bulkProbe)
    XCTAssertEqual(try feed(frame, into: &bulk), [envelope])
    var standard = LanFraming()
    XCTAssertThrowsError(try feed(Data(frame.prefix(5)), into: &standard)) {
      XCTAssertEqual($0 as? SessionFailure, .unsupportedProfile)
    }
    var budget = LanQueueBudget(profile: .bulkProbe)
    for _ in 0..<4 { try budget.reserve(envelope.count) }
    XCTAssertFalse(budget.canReserve(1))
    for _ in 0..<4 { budget.release(envelope.count) }
    XCTAssertTrue(budget.canReserve(envelope.count))
    XCTAssertFalse(LanQueueBudget(profile: .standard).canReserve(envelope.count))
    XCTAssertNotEqual(SessionProfile.standard.exporterLabel, SessionProfile.bulkProbe.exporterLabel)
  }

  @MainActor func testUnknownAdmissionIsExclusiveAndKnownPeersRemainPinned() throws {
    let row = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    let peer = try helper.identity(row, "initiator")
    let other = try helper.identity(row, "responder")
    let reservation = SessionPeerReservation()
    XCTAssertTrue(reservation.acquire("ble", peer: nil, local: "local"))
    XCTAssertFalse(reservation.acquire("lan", peer: peer, local: "local"))
    XCTAssertTrue(reservation.authenticate("ble", peer: peer))
    XCTAssertTrue(reservation.acquire("lan", peer: peer, local: "local"))
    XCTAssertFalse(reservation.acquire("ble", peer: nil, local: "local"))
    XCTAssertFalse(reservation.acquire("lan", peer: other, local: "local"))
    XCTAssertFalse(reservation.acquire("lan", peer: peer, local: "changed"))
    XCTAssertFalse(reservation.authenticate("ble", peer: other))
    reservation.release("ble")
    XCTAssertFalse(reservation.acquire("ble", peer: other, local: "local"))
    reservation.release("lan")
    XCTAssertNil(reservation.peer)
    XCTAssertFalse(reservation.authenticate("lan", peer: peer))
    XCTAssertTrue(reservation.acquire("ble", peer: other, local: "changed"))
  }
  func testAdmissionFailureBudgetDoesNotExtendWindow() {
    var window = SessionAdmissionWindow()
    window.open(0)
    for index in 0..<5 {
      XCTAssertTrue(window.claim(Double(index)))
      XCTAssertFalse(window.claim(Double(index)))
      XCTAssertEqual(window.retire(Double(index)), index < 4)
      window.open(Double(index) + 100)
      XCTAssertEqual(window.deadline, 120)
    }
    XCTAssertFalse(window.claim(6))
    window.clear()
    window.open(10)
    XCTAssertFalse(window.claim(130))
  }

  @MainActor private func assertCapacity(_ transport: LanTcpTransport, _ size: Int, _ expected: Bool,
    file: StaticString = #filePath, line: UInt = #line) async {
    let available = await transport.capacity(size)
    XCTAssertEqual(available, expected, file: file, line: line)
  }

  @MainActor func testQueuedWritesAreBoundedAndCloseResumesEverySubmission() async throws {
    let socket = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    let transport = LanTcpTransport(socket)
    var jobs = [Task<Void, Error>]()
    let envelope = Data(repeating: 6, count: 4096)
    for _ in 0..<8 {
      await assertCapacity(transport, envelope.count, true)
      jobs.append(Task { try await transport.submit(envelope) })
      await Task.yield()
    }
    await assertCapacity(transport, 2, false)
    do {
      try await transport.submit(Data([1, 0]))
      XCTFail("Queue overflow accepted")
    } catch is SessionBackpressure {}
    await transport.close()
    for job in jobs {
      do {
        try await job.value
        XCTFail("Retired submission succeeded")
      } catch let failure as SessionFailure { XCTAssertEqual(failure, .cancelled) }
    }
    await assertCapacity(transport, 2, false)
  }

  @MainActor func testStalledNativeSubmissionIsRetiredByWatchdog() async throws {
    let socket = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    let transport = LanTcpTransport(socket)
    let start = ProcessInfo.processInfo.systemUptime
    do {
      try await transport.submit(Data([1, 0]))
      XCTFail("Stalled submission succeeded")
    } catch let failure as SessionFailure { XCTAssertEqual(failure, .cancelled) }
    XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 10)
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 15)
    await assertCapacity(transport, 2, false)
  }

  @MainActor func testCancellationRetiresAnOutstandingSubmission() async throws {
    let transport = LanTcpTransport(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
    let submission = Task { try await transport.submit(Data([1, 0])) }
    await Task.yield()
    submission.cancel()
    do {
      try await submission.value
      XCTFail("Cancelled submission succeeded")
    } catch is CancellationError {} catch let failure as SessionFailure {
      XCTAssertEqual(failure, .cancelled)
    }
    await Task.yield()
    await assertCapacity(transport, 2, false)
  }
}
