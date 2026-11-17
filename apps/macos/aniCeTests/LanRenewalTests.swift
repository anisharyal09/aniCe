// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises fresh LAN epochs, ordered drain barriers and retirement races without replacing their transport owner.
import Foundation
import XCTest

@testable import aniCe

private final class RenewalClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Int64 = 0
  func read() -> Int64 { lock.withLock { value } }
  func advance(_ amount: Int64) { lock.withLock { value += amount } }
  func set(_ amount: Int64) { lock.withLock { value = amount } }
}
private actor RenewalMailbox {
  var pending = [Data]()
  var history = [Data]()
  var data = [Data]()
  var secured = 0
  var factories = 0
  func append(_ bytes: Data) { pending.append(bytes); history.append(bytes) }
  func take() -> Data? { pending.isEmpty ? nil : pending.removeFirst() }
  func record(_ bytes: Data) { data.append(bytes) }
  func ready() { secured += 1 }
  func fresh() { factories += 1 }
}
private actor RenewalGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var entered = false
  private var enabled = false
  func enable() { enabled = true }
  func pause() async {
    guard enabled else { return }
    entered = true
    await withCheckedContinuation { continuation = $0 }
  }
  func release() { enabled = false; continuation?.resume(); continuation = nil }
}
private final class RenewalPair: @unchecked Sendable {
  let clock = RenewalClock()
  let outgoing = RenewalMailbox()
  let replies = RenewalMailbox()
  let client: SessionConnection
  let server: SessionConnection
  init(serverRenewal: Bool = true, writeGate: RenewalGate? = nil, factoryGate: RenewalGate? = nil,
    serverWriteGate: RenewalGate? = nil, ackGate: RenewalGate? = nil) throws {
    let helper = SessionFixtures()
    let row = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    let clock = clock, outgoing = outgoing, replies = replies
    let makeClient = try helper.freshFactory(row, server: false, now: { Double(clock.read()) / 1000 })
    let makeServer = try helper.freshFactory(row, server: true, now: { Double(clock.read()) / 1000 })
    let ackSize = try LanRenewalControl(kind: 3, id: Data(count: 16)).encode().count + 31
    client = SessionConnection(handshake: try makeClient(), responder: false,
      capacity: { _ in true }, submit: {
        if $0.count > 60000 { await writeGate?.pause() }
        await outgoing.append($0)
      }, data: { await outgoing.record($0) }, secured: { await outgoing.ready() },
      controls: true, now: { clock.read() }, renew: true, profile: .lanTransfer512,
      renewalHandshake: {
        await outgoing.fresh()
        await factoryGate?.pause()
        return try makeClient()
      })
    var factory: (@Sendable () async throws -> SessionHandshakeEngine)?
    if serverRenewal { factory = { await replies.fresh(); return try makeServer() } }
    server = SessionConnection(handshake: try makeServer(), responder: true,
      capacity: { _ in true }, submit: {
        if $0.count > 60000 { await serverWriteGate?.pause() }
        await replies.append($0)
        if $0.count == ackSize { await ackGate?.pause() }
      }, data: { await replies.record($0) },
      secured: { await replies.ready() }, controls: true, now: { clock.read() }, renew: serverRenewal,
      profile: .lanTransfer512, renewalHandshake: factory)
  }
  func pump() async throws {
    for _ in 0..<128 {
      let request = await outgoing.take(), reply = await replies.take()
      if request == nil, reply == nil { return }
      if let request { try await server.receive(request) }
      if let reply { try await client.receive(reply) }
    }
    XCTFail("Unbounded renewal exchange")
  }
  func ready() async throws { try await client.start(); try await pump() }
  func age() async throws {
    for _ in 0..<54 {
      clock.advance(60000)
      try await client.tick(); try await server.tick(); try await pump()
    }
    clock.advance(60000)
  }
  func close() async { await client.close(); await server.close() }
}

final class LanRenewalTests: XCTestCase, @unchecked Sendable {
  func testIndependentRenewalFixturesAndBLECompatibility() throws {
    let helper = SessionFixtures(), rows = try helper.root("renewal-vectors")
    let valid = try XCTUnwrap(rows["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(rows["invalid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(valid.count, 4); XCTAssertGreaterThanOrEqual(invalid.count, 20)
    for row in valid {
      let bytes = try helper.hex(XCTUnwrap(row["payloadHex"] as? String))
      XCTAssertEqual(try LanRenewalControl.decode(bytes).encode(), bytes)
      XCTAssertNil(try SessionControl.application(bytes))
      guard case .lanRenewal = try SessionControl.classifyApplication(bytes, maximumBytes: 4096, lanRenewal: true)
      else { XCTFail("LAN control was not classified"); continue }
    }
    for row in invalid {
      XCTAssertThrowsError(try LanRenewalControl.decode(helper.hex(XCTUnwrap(row["payloadHex"] as? String)))) {
        XCTAssertEqual($0 as? SessionFailure,
          row["reason"] as? String == "unsupportedProfile" ? .unsupportedProfile : .malformed)
      }
    }
  }

  func testConsecutiveFreshEpochsPreserveReadinessAndApplicationOrdering() async throws {
    let pair = try RenewalPair()
    do {
      try await pair.ready()
      for cycle in 0..<3 {
        try await pair.client.sendData(Data([UInt8(cycle), 7]))
        try await pair.server.sendData(Data([UInt8(cycle), 9]))
        try await pair.pump(); try await pair.age()
        try await pair.server.tick(); try await pair.client.tick()
        let renewing = await pair.client.isRenewing, available = await pair.client.applicationAvailable
        XCTAssertTrue(renewing); XCTAssertFalse(available)
        do { try await pair.client.sendData(Data([42])); XCTFail("DATA escaped renewal") }
        catch is SessionBackpressure {}
        pair.clock.advance(50)
        try await pair.pump()
        let finished = await pair.client.isRenewing, ready = await pair.client.applicationAvailable
        XCTAssertFalse(finished); XCTAssertTrue(ready)
        let countI = await pair.outgoing.secured, countR = await pair.replies.secured
        XCTAssertEqual(countI, 1); XCTAssertEqual(countR, 1)
        let factoriesI = await pair.outgoing.factories, factoriesR = await pair.replies.factories
        XCTAssertEqual(factoriesI, cycle + 1); XCTAssertEqual(factoriesR, cycle + 1)
        let snapshot = await pair.client.maintenanceSnapshot
        XCTAssertEqual(snapshot.elapsedMillis, Int64(cycle + 1) * 50)
      }
      let dataI = await pair.outgoing.data, dataR = await pair.replies.data
      XCTAssertEqual(dataI, (0..<3).map { Data([UInt8($0), 9]) })
      XCTAssertEqual(dataR, (0..<3).map { Data([UInt8($0), 7]) })
      let historyI = await pair.outgoing.history, historyR = await pair.replies.history
      let starts = historyI.filter { $0.first == 1 }
      XCTAssertEqual(starts.count, 4); XCTAssertEqual(Set(starts).count, 4)
      for history in [historyI, historyR] {
        let ready = history.filter { $0.first == 6 && (1...2).contains($0[$0.startIndex + 2]) }
        XCTAssertEqual(ready.count, 4); XCTAssertEqual(Set(ready).count, 4)
        for record in ready { XCTAssertTrue(record.dropFirst(3).prefix(8).allSatisfy { $0 == 0 }) }
      }
    } catch { await pair.close(); throw error }
    await pair.close()
  }

  func testLegacyPeerKeepsOriginalHardExpiryWithoutInBandHandshake() async throws {
    let pair = try RenewalPair(serverRenewal: false)
    do {
      try await pair.ready(); try await pair.age()
      try await pair.client.tick(); try await pair.server.tick(); try await pair.pump()
      let renewing = await pair.client.isRenewing, factories = await pair.outgoing.factories
      XCTAssertFalse(renewing); XCTAssertEqual(factories, 0)
      try await pair.client.sendData(Data([7])); try await pair.pump()
      pair.clock.set(3600000)
      do { try await pair.client.tick(); XCTFail("Legacy peer extended hard lifetime") }
      catch let failure as SessionFailure { XCTAssertEqual(failure, .expired) }
      let expiry = await pair.client.expiration
      XCTAssertEqual(expiry, .lifetime)
    } catch { await pair.close(); throw error }
    await pair.close()
  }

  func testRecordMarginRequestsCoalesceIntoOneFreshEpoch() async throws {
    let pair = try RenewalPair()
    do {
      try await pair.ready()
      for _ in 0..<2 { try await pair.server.sendData(SessionControl(kind: .renewalRequest, value: 2).encode()) }
      try await pair.pump()
      let countI = await pair.outgoing.factories, countR = await pair.replies.factories
      let renewing = await pair.client.isRenewing
      XCTAssertEqual(countI, 1); XCTAssertEqual(countR, 1); XCTAssertFalse(renewing)
    } catch { await pair.close(); throw error }
    await pair.close()
  }

  func testOldCiphertextCannotAuthenticateAtTheSuccessorExpectedSequence() async throws {
    let pair = try RenewalPair()
    do {
      try await pair.ready()
      try await pair.server.sendData(Data([7]))
      let pending = await pair.replies.pending
      let old = try XCTUnwrap(pending.first)
      XCTAssertEqual(old[old.startIndex + 10], 3)
      try await pair.pump(); try await pair.age(); try await pair.client.tick(); try await pair.pump()
      do { try await pair.client.receive(old); XCTFail("Old ciphertext authenticated under successor keys") }
      catch let failure as SessionFailure { XCTAssertEqual(failure, .authentication) }
      let closed = await pair.client.isClosed, data = await pair.outgoing.data
      XCTAssertTrue(closed); XCTAssertEqual(data, [Data([7])])
    } catch { await pair.close(); throw error }
    await pair.close()
  }

  @MainActor func testMaintenancePreservesWaitBudgetAndFencesStaleUpdates() async throws {
    final class Channel: SecuredChannel {
      let descriptor: ChannelDescriptor
      let maintenance: ChannelMaintenance? = ChannelMaintenance()
      init(peer: DeviceIdentity) { descriptor = ChannelDescriptor(instance: "test", transport: "lan", peer: peer) }
      func sendData(_ bytes: Data) async throws {}
    }
    let helper = SessionFixtures()
    let fixture = try XCTUnwrap((helper.root()["valid"] as? [[String: Any]])?.first)
    let channel = Channel(peer: try helper.identity(fixture, "initiator"))
    let maintenance = try XCTUnwrap(channel.maintenance)
    let began = Int64(ProcessInfo.processInfo.systemUptime * 1000)
    maintenance.update(SessionMaintenanceSnapshot(sinceMillis: began, revision: 1))
    var finished = false
    let deadline = Task { try await waitForChannelDeadline(.milliseconds(20), on: channel); finished = true }
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertFalse(finished)
    let elapsed = Int64(ProcessInfo.processInfo.systemUptime * 1000) - began
    maintenance.update(SessionMaintenanceSnapshot(elapsedMillis: elapsed, revision: 2))
    maintenance.update(SessionMaintenanceSnapshot(sinceMillis: began, revision: 1))
    XCTAssertFalse(maintenance.active)
    try await deadline.value
    XCTAssertTrue(finished)
    maintenance.update(SessionMaintenanceSnapshot(sinceMillis: began + elapsed, elapsedMillis: elapsed, revision: 3))
    let cancelled = Task { try await maintenance.awaitAvailable() }
    await Task.yield()
    cancelled.cancel()
    do { try await cancelled.value; XCTFail("Cancelled maintenance waiter succeeded") } catch is CancellationError {}
    let retired = Task { try await maintenance.awaitAvailable() }
    await Task.yield()
    maintenance.close()
    do { try await retired.value; XCTFail("Retired maintenance waiter succeeded") }
    catch let failure as SessionFailure { XCTAssertEqual(failure, .cancelled) }
  }

  func testQuiescenceAndLifetimeDeadlinesRemainAbsolute() async throws {
    for hard in [false, true] {
      let pair = try RenewalPair()
      do {
        try await pair.ready(); try await pair.age(); try await pair.client.tick()
        pair.clock.set(hard ? 3600000 : 3310000)
        do { try await pair.client.checkDeadlines(); XCTFail("Renewal extended its deadline") }
        catch let failure as SessionFailure { XCTAssertEqual(failure, hard ? .expired : .controlTimeout) }
        let closed = await pair.client.isClosed
        XCTAssertTrue(closed)
      } catch { await pair.close(); throw error }
      await pair.close()
    }
  }

  func testInvalidRoleAndUnsolicitedDrainRetireWithoutDataDelivery() async throws {
    for kind: Int64 in [2, 3] {
      let pair = try RenewalPair()
      do {
        try await pair.ready()
        try await pair.server.sendData(LanRenewalControl(kind: kind, id: Data(repeating: 1, count: 16)).encode())
        do { try await pair.pump(); XCTFail("Unsolicited/role-invalid control accepted") }
        catch let failure as SessionFailure { XCTAssertEqual(failure, .state) }
        let closed = await pair.client.isClosed, data = await pair.outgoing.data
        XCTAssertTrue(closed); XCTAssertTrue(data.isEmpty)
      } catch { await pair.close(); throw error }
      await pair.close()
    }
  }

  func testSealedOldWriteDrainsBeforeFreshHandshakeAndWakesMaintenance() async throws {
    let gate = RenewalGate(), pair = try RenewalPair(writeGate: gate)
    do {
      try await pair.ready(); try await pair.age()
      await gate.enable()
      let payload = Data(repeating: 7, count: 65536)
      let send = Task { try await pair.client.sendData(payload) }
      for _ in 0..<10000 { if await gate.entered { break }; await Task.yield() }
      let entered = await gate.entered
      XCTAssertTrue(entered)
      try await pair.client.tick()
      let pending = await pair.outgoing.pending.count
      XCTAssertEqual(pending, 0)
      await gate.release(); try await send.value
      let next = await pair.client.nextDeadline()
      XCTAssertEqual(next, pair.clock.read(), "A completed old send must rearm the drain without polling")
      try await pair.client.tick(); try await pair.pump()
      let data = await pair.replies.data, renewing = await pair.client.isRenewing
      XCTAssertEqual(data, [payload]); XCTAssertFalse(renewing)
    } catch { await gate.release(); await pair.close(); throw error }
    await pair.close()
  }

  func testStopAndDeadlineFenceASuspendedSuccessorFactory() async throws {
    for expired in [false, true] {
      let gate = RenewalGate(), pair = try RenewalPair(factoryGate: gate)
      do {
        try await pair.ready(); try await pair.age()
        await gate.enable()
        try await pair.client.tick()
        let begin = await pair.outgoing.take()
        try await pair.server.receive(XCTUnwrap(begin))
        let drained = await pair.replies.take()
        let ack = try XCTUnwrap(drained)
        let receive = Task { try await pair.client.receive(ack) }
        for _ in 0..<10000 { if await gate.entered { break }; await Task.yield() }
        let entered = await gate.entered
        XCTAssertTrue(entered)
        let deadline = await pair.client.nextDeadline(includeMaintenance: false)
        XCTAssertEqual(deadline, 3330000)
        if expired {
          pair.clock.set(3330000)
          do { try await pair.client.checkDeadlines(); XCTFail("Factory extended handshake") }
          catch let failure as SessionFailure { XCTAssertEqual(failure, .expired) }
        } else { await pair.client.close() }
        await gate.release()
        do { try await receive.value; XCTFail("Retired factory published a handshake") }
        catch let failure as SessionFailure { XCTAssertEqual(failure, .cancelled) }
        let starts = await pair.outgoing.history.filter { $0.first == 1 }.count
        XCTAssertEqual(starts, 1)
      } catch { await gate.release(); await pair.close(); throw error }
      await pair.close()
    }
  }

  func testPeerReceiptCannotSwapKeysBeforeDrainSubmissionFinishes() async throws {
    let oldGate = RenewalGate(), ackGate = RenewalGate()
    let pair = try RenewalPair(serverWriteGate: oldGate, ackGate: ackGate)
    do {
      try await pair.ready(); try await pair.age()
      await oldGate.enable()
      let oldWrite = Task { try await pair.server.sendData(Data(repeating: 7, count: 65536)) }
      for _ in 0..<10000 { if await oldGate.entered { break }; await Task.yield() }
      let entered = await oldGate.entered
      XCTAssertTrue(entered)
      try await pair.client.tick()
      let begin = await pair.outgoing.take()
      try await pair.server.receive(XCTUnwrap(begin))
      await oldGate.release(); try await oldWrite.value
      let data = await pair.replies.take()
      try await pair.client.receive(XCTUnwrap(data))
      await ackGate.enable()
      let drain = Task { try await pair.server.tick() }
      for _ in 0..<10000 { if await ackGate.entered { break }; await Task.yield() }
      let ackEntered = await ackGate.entered
      XCTAssertTrue(ackEntered)
      let ack = await pair.replies.take()
      try await pair.client.receive(XCTUnwrap(ack))
      let first = await pair.outgoing.take()
      let message1 = try XCTUnwrap(first)
      XCTAssertEqual(message1.first, 1)
      let receiving = Task { try await pair.server.receive(message1) }
      for _ in 0..<20 { await Task.yield() }
      let factories = await pair.replies.factories, closed = await pair.server.isClosed
      XCTAssertEqual(factories, 0); XCTAssertFalse(closed)
      await ackGate.release()
      try await drain.value; try await receiving.value
      try await pair.pump()
      let finalFactories = await pair.replies.factories
      let clientClosed = await pair.client.isClosed, serverClosed = await pair.server.isClosed
      XCTAssertEqual(finalFactories, 1); XCTAssertFalse(clientClosed); XCTAssertFalse(serverClosed)
    } catch { await oldGate.release(); await ackGate.release(); await pair.close(); throw error }
    await pair.close()
  }
}
