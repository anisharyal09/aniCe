// SPDX-License-Identifier: GPL-3.0-or-later
// Probes LAN framing, peer reservations and admission under malformed and stale operations.
import Foundation
import Network
import XCTest

@testable import aniCe

final class LanTests: XCTestCase {
  @MainActor func testTCPPeerLossDetectionDoesNotWaitForDefaultIdleTimeouts() throws {
    let parameters = LanTcpTransport.parameters()
    let options = try XCTUnwrap(
      parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
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
  private let helper = SessionTests()
  private func feed(_ bytes: Data, into framing: inout LanFraming) throws -> [Data] {
    try bytes.compactMap { try framing.feed($0) }
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
      XCTAssertThrowsError(try framing.feed(1)) {
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
    _ = try slow.feed(1)
    clock = 9.999
    _ = try slow.feed(0)
    clock = 10
    XCTAssertThrowsError(try slow.feed(0)) { XCTAssertEqual($0 as? SessionFailure, .expired) }
    XCTAssertThrowsError(try slow.end()) { XCTAssertEqual($0 as? SessionFailure, .cancelled) }
    for size in [0, 1, 4097] {
      XCTAssertThrowsError(try LanFraming.encode(Data(repeating: 0, count: size))) {
        XCTAssertEqual($0 as? SessionFailure, .malformed)
      }
    }
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

  @MainActor func testQueuedWritesAreBoundedAndCloseResumesEverySubmission() async throws {
    let socket = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    let transport = LanTcpTransport(socket)
    var jobs = [Task<Void, Error>]()
    let envelope = Data(repeating: 6, count: 4096)
    for _ in 0..<8 {
      XCTAssertTrue(transport.capacity(envelope.count))
      jobs.append(Task { try await transport.submit(envelope) })
      await Task.yield()
    }
    XCTAssertFalse(transport.capacity(2))
    do {
      try await transport.submit(Data([1, 0]))
      XCTFail("Queue overflow accepted")
    } catch is SessionBackpressure {}
    transport.close()
    for job in jobs {
      do {
        try await job.value
        XCTFail("Retired submission succeeded")
      } catch let failure as SessionFailure { XCTAssertEqual(failure, .cancelled) }
    }
    XCTAssertFalse(transport.capacity(2))
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
    XCTAssertFalse(transport.capacity(2))
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
    XCTAssertFalse(transport.capacity(2))
  }
}
