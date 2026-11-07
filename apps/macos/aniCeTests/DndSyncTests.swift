// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import aniCe

@MainActor final class DndSyncTests: XCTestCase {
  private let on = MacDeskDeckSystemShortcut(identifier: "00000000-0000-0000-0000-000000000001", name: "DND On")
  private let off = MacDeskDeckSystemShortcut(identifier: "00000000-0000-0000-0000-000000000002", name: "DND Off")
  private func settle() async { for _ in 0..<20 { await Task.yield() } }
  private func messages(_ channel: MockSecuredChannel, kind: Int64) -> [DndSyncMessage] {
    channel.sentData.compactMap { try? DndSyncMessage.decode($0) }.filter { $0.kind == kind }
  }
  private func model(execute: @escaping (String) async -> Int64 = { _ in 0 }) async -> MacDndSyncModel {
    let name = "dnd-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let entries = [on, off]
    let model = MacDndSyncModel(defaults: defaults, execute: execute, list: { (entries, true) })
    await model.refreshShortcuts()
    model.choose(on, enabled: true); model.choose(off, enabled: false)
    defaults.removePersistentDomain(forName: name)
    return model
  }
  func testSharedFixtures() throws {
    let fixtures = SessionFixtures()
    let root = try fixtures.root("dnd-sync-vectors")
    for row in try XCTUnwrap(root["valid"] as? [[String: Any]]) {
      let bytes = try fixtures.b(row, "bytes")
      XCTAssertEqual(try XCTUnwrap(DndSyncMessage.decode(bytes)).encode(), bytes)
    }
    for row in try XCTUnwrap(root["invalid"] as? [[String: Any]]) {
      XCTAssertThrowsError(try DndSyncMessage.decode(fixtures.b(row, "bytes")))
    }
  }
  func testShortcutExitStatusOnlyConfirmsTheCommand() {
    XCTAssertEqual(MacDeskDeckShortcutRunner.resultCode(0), 0)
    XCTAssertEqual(MacDeskDeckShortcutRunner.resultCode(1), 7)
    XCTAssertEqual(MacDeskDeckShortcutRunner.resultCode(-1), 7)
  }
  func testEchoDuplicateOppositeAndExpiredEvents() {
    var guardState = DndEchoGuard()
    XCTAssertTrue(guardState.changed(false, now: 0))
    guardState.applying(true, now: 1)
    XCTAssertFalse(guardState.changed(false, now: 2))
    XCTAssertFalse(guardState.changed(true, now: 3))
    XCTAssertFalse(guardState.changed(true, now: 4))
    XCTAssertTrue(guardState.changed(false, now: 5))
    guardState.applying(true, now: 6)
    XCTAssertTrue(guardState.changed(true, now: 22))
    guardState.applying(true, now: 23)
    XCTAssertTrue(guardState.changed(false, now: 24))
    XCTAssertTrue(guardState.changed(true, now: 25))
  }
  func testIncomingWorksWithOutgoingOffAndNeverEchoesOrReplaysAcrossTransports() async throws {
    var calls: [String] = []
    let model = await model { id in calls.append(id); return 0 }
    defer { model.shutdown() }
    let lan = MockSecuredChannel(instance: "dnd-lan", transport: "lan")
    let ble = MockSecuredChannel(instance: "dnd-ble", transport: "ble", peer: lan.descriptor.peer)
    model.available(lan); model.available(ble); await settle()
    let capability = try DndSyncMessage(kind: 1, sending: true, receiving: true).encode()
    _ = await model.handle(capability, on: lan.descriptor)
    _ = await model.handle(capability, on: ble.descriptor)
    let incoming = try DndSyncMessage(kind: 2, id: UUID().uuidString.lowercased(), enabled: true).encode()
    _ = await model.handle(incoming, on: lan.descriptor)
    _ = await model.handle(incoming, on: ble.descriptor)
    await settle()
    XCTAssertEqual(calls, [on.identifier])
    _ = await model.handle(try DndSyncMessage(kind: 2, id: UUID().uuidString.lowercased(), enabled: false).encode(), on: lan.descriptor)
    await settle()
    XCTAssertEqual(calls, [on.identifier, off.identifier])
    model.setSending(true); await settle()
    await model.nativeChanged(true); await settle()
    XCTAssertTrue(messages(lan, kind: 2).isEmpty)
    await model.nativeChanged(false); await settle()
    XCTAssertEqual(messages(lan, kind: 2).map(\.enabled), [false])
    XCTAssertTrue(messages(ble, kind: 2).isEmpty)
    model.setSending(false)
    await model.nativeChanged(true); await settle()
    XCTAssertEqual(messages(lan, kind: 2).count, 1)
  }
  func testRevokedSetupAndRetiredChannelsCannotApply() async throws {
    var calls = 0
    let model = await model { _ in calls += 1; return 0 }
    defer { model.shutdown() }
    let channel = MockSecuredChannel(instance: "dnd-revoked", transport: "lan")
    model.available(channel); await settle()
    _ = await model.handle(try DndSyncMessage(kind: 1, sending: true).encode(), on: channel.descriptor)
    model.removeSelections()
    _ = await model.handle(try DndSyncMessage(kind: 2, id: UUID().uuidString.lowercased(), enabled: true).encode(), on: channel.descriptor)
    await settle()
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(messages(channel, kind: 3).last?.result, 1)
    model.retired(channel.descriptor)
    _ = await model.handle(try DndSyncMessage(kind: 2, id: UUID().uuidString.lowercased(), enabled: true).encode(), on: channel.descriptor)
    XCTAssertEqual(calls, 0)
  }
  func testNoDisconnectedChangeIsReplayedOnConnection() async throws {
    let model = await model()
    defer { model.shutdown() }
    model.setSending(true)
    await model.nativeChanged(true)
    let channel = MockSecuredChannel(instance: "dnd-no-replay", transport: "lan")
    model.available(channel); await settle()
    _ = await model.handle(try DndSyncMessage(kind: 1, receiving: true).encode(), on: channel.descriptor)
    await settle()
    XCTAssertTrue(messages(channel, kind: 2).isEmpty)
  }
  func testLatestIncomingStateSupersedesWaitingAction() async throws {
    var calls: [String] = []
    let model = await model { id in
      calls.append(id)
      if calls.count == 1 { try? await Task.sleep(for: .milliseconds(40)) }
      return 0
    }
    defer { model.shutdown() }
    let channel = MockSecuredChannel(instance: "dnd-coalescing", transport: "lan")
    model.available(channel); await settle()
    _ = await model.handle(try DndSyncMessage(kind: 1, sending: true).encode(), on: channel.descriptor)
    _ = await model.handle(try DndSyncMessage(kind: 2, id: UUID().uuidString.lowercased(), enabled: true).encode(), on: channel.descriptor)
    await settle()
    _ = await model.handle(try DndSyncMessage(kind: 2, id: UUID().uuidString.lowercased(), enabled: false).encode(), on: channel.descriptor)
    _ = await model.handle(try DndSyncMessage(kind: 2, id: UUID().uuidString.lowercased(), enabled: true).encode(), on: channel.descriptor)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(calls, [on.identifier, on.identifier])
    XCTAssertTrue(messages(channel, kind: 3).contains { $0.result == 4 })
  }
  func testHealthyTransportIsRetainedWhenAnotherBecomesAvailable() async throws {
    let model = await model()
    defer { model.shutdown() }
    model.setSending(true)
    let ble = MockSecuredChannel(instance: "dnd-stable-ble", transport: "ble")
    model.available(ble); await settle()
    let capability = try DndSyncMessage(kind: 1, receiving: true).encode()
    _ = await model.handle(capability, on: ble.descriptor)
    await model.nativeChanged(true); await settle()
    let lan = MockSecuredChannel(instance: "dnd-new-lan", transport: "lan", peer: ble.descriptor.peer)
    model.available(lan); await settle()
    _ = await model.handle(capability, on: lan.descriptor)
    await model.nativeChanged(false); await settle()
    XCTAssertEqual(messages(ble, kind: 2).map(\.enabled), [true, false])
    XCTAssertTrue(messages(lan, kind: 2).isEmpty)
  }

}
