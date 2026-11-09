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
    model.choose(on, enabled: true)
    model.choose(off, enabled: false)
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

  func testPhoneChangesApplyOnlyAfterPhoneAdvertisesSending() async throws {
    var calls: [String] = []
    let model = await model { id in calls.append(id); return 0 }
    defer { model.shutdown() }
    let phone = MockSecuredChannel(instance: "dnd-phone-to-mac", transport: "lan")
    model.available(phone)
    await settle()

    let capability = try XCTUnwrap(messages(phone, kind: 1).last)
    XCTAssertFalse(capability.sending)
    XCTAssertTrue(capability.receiving)

    let change = DndSyncMessage(kind: 2, id: UUID().uuidString.lowercased(), enabled: true)
    let rejectedBeforeCapability = await model.handle(try change.encode(), on: phone.descriptor)
    XCTAssertEqual(rejectedBeforeCapability, .discarded)
    XCTAssertTrue(calls.isEmpty)

    _ = await model.handle(try DndSyncMessage(kind: 1, sending: true).encode(), on: phone.descriptor)
    let accepted = await model.handle(try change.encode(), on: phone.descriptor)
    XCTAssertEqual(accepted, .handled)
    await settle()
    XCTAssertEqual(calls, [on.identifier])
    XCTAssertEqual(messages(phone, kind: 3).last?.result, 0)
    XCTAssertTrue(model.receiveStatus.contains("cannot verify Focus state"))
  }

  func testMacOriginatedStateIsNeverAccepted() async throws {
    var calls = 0
    let model = await model { _ in calls += 1; return 0 }
    defer { model.shutdown() }
    let phone = MockSecuredChannel(instance: "dnd-no-mac-send", transport: "ble")
    model.available(phone)
    await settle()
    _ = await model.handle(try DndSyncMessage(kind: 1, sending: false).encode(), on: phone.descriptor)
    let change = DndSyncMessage(kind: 2, id: UUID().uuidString.lowercased(), enabled: true)
    let rejected = await model.handle(try change.encode(), on: phone.descriptor)
    XCTAssertEqual(rejected, .discarded)
    await settle()
    XCTAssertEqual(calls, 0)
    XCTAssertTrue(messages(phone, kind: 2).isEmpty)
  }

  func testRemovedShortcutsAndRetiredChannelsCannotApplyChanges() async throws {
    var calls = 0
    let model = await model { _ in calls += 1; return 0 }
    defer { model.shutdown() }
    let phone = MockSecuredChannel(instance: "dnd-revoked", transport: "lan")
    model.available(phone)
    await settle()
    _ = await model.handle(try DndSyncMessage(kind: 1, sending: true).encode(), on: phone.descriptor)
    model.removeSelections()
    let change = DndSyncMessage(kind: 2, id: UUID().uuidString.lowercased(), enabled: true)
    _ = await model.handle(try change.encode(), on: phone.descriptor)
    await settle()
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(messages(phone, kind: 3).last?.result, 1)
    model.retired(phone.descriptor)
    let retiredResult = await model.handle(try change.encode(), on: phone.descriptor)
    XCTAssertEqual(retiredResult, .discarded)
  }
}
