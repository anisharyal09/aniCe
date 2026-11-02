// SPDX-License-Identifier: GPL-3.0-or-later
// Tests Mac event translation and session ownership without posting real system input.
import AppKit
import XCTest
@testable import aniCe

@MainActor private final class PhoneInputEventSinkFake: MacPhoneInputEventSink {
  var canPostEvents = true
  var cursor: CGPoint? = CGPoint(x: 10, y: 10)
  var displays = [CGRect(x: 0, y: 0, width: 100, height: 100)]
  var events = [MacPhoneInputEvent]()

  func cursorLocation() -> CGPoint? { cursor }
  func displayBounds() -> [CGRect] { displays }
  func post(_ event: MacPhoneInputEvent) throws {
    guard canPostEvents else { throw MacPhoneInputEventError.accessDenied }
    events.append(event)
  }
}

@MainActor final class MacPhoneInputTests: XCTestCase {
  func testTextChunksKeepGraphemesWholeAndRejectAnOversizedGrapheme() throws {
    let text = String(repeating: "a", count: 15) + "👩🏽‍💻" + "नमस्ते"
    let chunks = try MacPhoneInputEventAdapter.textChunks(text)
    XCTAssertTrue(chunks.allSatisfy { $0.count <= 16 })
    XCTAssertEqual(String(decoding: chunks.flatMap { $0 }, as: UTF16.self), text)

    let tooLong = "a" + String(repeating: "\u{0301}", count: 16)
    XCTAssertEqual(tooLong.count, 1)
    XCTAssertThrowsError(try MacPhoneInputEventAdapter.textChunks(tooLong))
  }

  func testDisplayClampingHandlesNegativeOriginsGapsAndEdges() {
    let displays = [
      CGRect(x: -1000, y: 0, width: 1000, height: 800),
      CGRect(x: 0, y: 0, width: 1000, height: 800),
      CGRect(x: 1000, y: 300, width: 1200, height: 900),
    ]
    XCTAssertEqual(
      MacPhoneInputEventAdapter.clampedPoint(CGPoint(x: -1200, y: 400), to: displays),
      CGPoint(x: -1000, y: 400))
    XCTAssertEqual(
      MacPhoneInputEventAdapter.clampedPoint(CGPoint(x: 2199, y: 1199), to: displays),
      CGPoint(x: 2199, y: 1199))
    XCTAssertEqual(
      MacPhoneInputEventAdapter.clampedPoint(CGPoint(x: 1500, y: 100), to: displays),
      CGPoint(x: 1500, y: 300))
    XCTAssertNil(MacPhoneInputEventAdapter.clampedPoint(.zero, to: []))
  }

  func testKeyAndModifiedClickCarryTheModifierSnapshotAndReleaseHeldState() throws {
    let sink = PhoneInputEventSinkFake()
    let adapter = MacPhoneInputEventAdapter(sink: sink)
    let session = "01234567-89ab-4cde-8fab-0123456789ab"

    try adapter.apply(.of(5, .text(session), .integer(1), .integer(8), .integer(0x0A), .bool(true)))
    try adapter.apply(.of(7, .text(session), .integer(1), .integer(1), .integer(0x08)))

    XCTAssertEqual(sink.events.first, .key(usage: 8, keyCode: 0x0E, pressed: true, modifiers: 0x0A))
    XCTAssertEqual(
      sink.events.last,
      .pointerButton(button: 1, pressed: true, location: CGPoint(x: 10, y: 10), modifiers: 0x08))
    XCTAssertTrue(adapter.releaseAll())
    XCTAssertTrue(adapter.heldKeys.isEmpty)
    XCTAssertEqual(adapter.heldButtons, 0)
    XCTAssertEqual(adapter.modifiers, 0)
    XCTAssertEqual(sink.events.suffix(2), [
      .pointerButton(button: 1, pressed: false, location: CGPoint(x: 10, y: 10), modifiers: 0x08),
      .key(usage: 8, keyCode: 0x0E, pressed: false, modifiers: 0x08),
    ])
  }

  func testMovementPostsClampedAbsolutePointAndActualDelta() throws {
    let sink = PhoneInputEventSinkFake()
    sink.cursor = CGPoint(x: 99, y: 99)
    let adapter = MacPhoneInputEventAdapter(sink: sink)
    let session = "01234567-89ab-4cde-8fab-0123456789ab"

    try adapter.apply(.of(6, .text(session), .integer(1), .integer(8), .integer(8)))

    XCTAssertEqual(
      sink.events.last,
      .pointerMotion(
        location: CGPoint(x: 99, y: 99), deltaX: 0, deltaY: 0, buttons: 0, modifiers: 0))
  }

  func testScrollPreservesBothAxesAndCurrentModifiers() throws {
    let sink = PhoneInputEventSinkFake()
    let adapter = MacPhoneInputEventAdapter(sink: sink)
    let session = "01234567-89ab-4cde-8fab-0123456789ab"
    try adapter.apply(.of(5, .text(session), .integer(1), .integer(8), .integer(8), .bool(true)))
    try adapter.apply(.of(8, .text(session), .integer(2), .integer(-12), .integer(31)))

    XCTAssertEqual(
      sink.events.last,
      .scroll(horizontal: -12, vertical: 31, location: CGPoint(x: 10, y: 10), modifiers: 8))
  }

  func testReleaseRetriesWhenEventAccessReturns() throws {
    let sink = PhoneInputEventSinkFake()
    let adapter = MacPhoneInputEventAdapter(sink: sink)
    let session = "01234567-89ab-4cde-8fab-0123456789ab"
    try adapter.apply(.of(5, .text(session), .integer(1), .integer(8), .integer(2), .bool(true)))

    sink.canPostEvents = false
    XCTAssertFalse(adapter.releaseAll())
    XCTAssertEqual(adapter.heldKeys, [8])
    sink.canPostEvents = true
    XCTAssertTrue(adapter.releaseAll())
    XCTAssertTrue(adapter.heldKeys.isEmpty)
  }

  func testOnlyArmedBLEPeerCanStartAndTextUsesTheExistingCapability() async throws {
    let sink = PhoneInputEventSinkFake()
    let model = MacPhoneInputModel(eventAdapter: MacPhoneInputEventAdapter(sink: sink))
    let channel = MockSecuredChannel(transport: "ble")
    let owner = UUID()
    let session = "01234567-89ab-4cde-8fab-0123456789ab"
    model.available(channel)
    await eventually { channel.sentData.contains { (try? PhoneInputMessage.decode($0))?.kind == 1 } }
    _ = await model.handle(
      try PhoneInputMessage.of(1, .integer(1024), .integer(1)).encode(), on: channel.descriptor)
    model.arm(ownerID: owner, for: channel.descriptor.peer)

    let result = await model.handle(
      try PhoneInputMessage.of(2, .text(session)).encode(), on: channel.descriptor)
    XCTAssertEqual(result, .handled)
    await eventually { model.isReceiving }
    XCTAssertEqual(
      try channel.sentData.compactMap { try PhoneInputMessage.decode($0) }.last?.number(1), 0)

    _ = await model.handle(
      try PhoneInputMessage.of(4, .text(session), .integer(1), .text("hello नमस्ते 👩🏽‍💻")).encode(),
      on: channel.descriptor)
    XCTAssertTrue(sink.events.contains { if case .text = $0 { true } else { false } })
    model.disarm(ownerID: owner)
    XCTAssertFalse(model.isReceiving)
    await eventually {
      channel.sentData.contains {
        guard let message = try? PhoneInputMessage.decode($0) else { return false }
        return message.kind == 11 && message.text(0) == session && message.number(1) == 0
      }
    }
    model.shutdown()
  }

  func testMissingEventAccessRejectsStartWithoutActivating() async throws {
    let sink = PhoneInputEventSinkFake()
    sink.canPostEvents = false
    let model = MacPhoneInputModel(eventAdapter: MacPhoneInputEventAdapter(sink: sink))
    let channel = MockSecuredChannel(transport: "ble")
    let session = "01234567-89ab-4cde-8fab-0123456789ab"
    model.available(channel)
    await eventually { channel.sentData.contains { (try? PhoneInputMessage.decode($0))?.kind == 1 } }
    _ = await model.handle(
      try PhoneInputMessage.of(1, .integer(1024), .integer(1)).encode(), on: channel.descriptor)
    model.arm(ownerID: UUID(), for: channel.descriptor.peer)

    _ = await model.handle(try PhoneInputMessage.of(2, .text(session)).encode(), on: channel.descriptor)
    await eventually {
      (try? channel.sentData.compactMap { try PhoneInputMessage.decode($0) }
        .contains { $0.kind == 3 && $0.number(1) == 2 }) == true
    }
    XCTAssertFalse(model.isReceiving)
    XCTAssertTrue(model.needsPostEventAccess)
    model.shutdown()
  }

  func testAccessRefreshUpdatesArmedStateAfterSettingsChange() {
    let sink = PhoneInputEventSinkFake()
    sink.canPostEvents = false
    let model = MacPhoneInputModel(eventAdapter: MacPhoneInputEventAdapter(sink: sink))
    let owner = UUID()
    let peer = MockSecuredChannel(transport: "ble").descriptor.peer

    model.arm(ownerID: owner, for: peer)
    XCTAssertTrue(model.needsPostEventAccess)
    XCTAssertTrue(model.isArmed(by: owner))

    sink.canPostEvents = true
    model.refreshAccessState()

    XCTAssertFalse(model.needsPostEventAccess)
    XCTAssertEqual(model.statusMessage, "Ready to receive from \(peer.deviceName).")
    model.disarm(ownerID: owner)
  }

  func testRevokedAccessStopsTheActiveReceiveSession() async throws {
    let sink = PhoneInputEventSinkFake()
    let model = MacPhoneInputModel(eventAdapter: MacPhoneInputEventAdapter(sink: sink))
    let channel = MockSecuredChannel(transport: "ble")
    let session = "01234567-89ab-4cde-8fab-0123456789ab"
    model.available(channel)
    await eventually { channel.sentData.contains { (try? PhoneInputMessage.decode($0))?.kind == 1 } }
    _ = await model.handle(
      try PhoneInputMessage.of(1, .integer(1024), .integer(7)).encode(), on: channel.descriptor)
    model.arm(ownerID: UUID(), for: channel.descriptor.peer)
    _ = await model.handle(try PhoneInputMessage.of(2, .text(session)).encode(), on: channel.descriptor)
    await eventually { model.isReceiving }

    sink.canPostEvents = false
    let result = await model.handle(
      try PhoneInputMessage.of(4, .text(session), .integer(1), .text("hello")).encode(),
      on: channel.descriptor)

    XCTAssertEqual(result, .discarded)
    XCTAssertFalse(model.isReceiving)
    XCTAssertTrue(model.needsPostEventAccess)
    XCTAssertTrue(model.statusMessage.contains("revoked"))
    model.shutdown()
  }

  func testRepeatedSequenceStopsAndReleasesHeldKeys() async throws {
    let sink = PhoneInputEventSinkFake()
    let model = MacPhoneInputModel(eventAdapter: MacPhoneInputEventAdapter(sink: sink))
    let channel = MockSecuredChannel(transport: "ble")
    let owner = UUID()
    let session = "01234567-89ab-4cde-8fab-0123456789ab"
    model.available(channel)
    await eventually { channel.sentData.contains { (try? PhoneInputMessage.decode($0))?.kind == 1 } }
    _ = await model.handle(
      try PhoneInputMessage.of(1, .integer(1024), .integer(7)).encode(), on: channel.descriptor)
    model.arm(ownerID: owner, for: channel.descriptor.peer)
    _ = await model.handle(try PhoneInputMessage.of(2, .text(session)).encode(), on: channel.descriptor)
    await eventually { model.isReceiving }

    let keyDown = try PhoneInputMessage.of(
      5, .text(session), .integer(1), .integer(8), .integer(2), .bool(true)).encode()
    _ = await model.handle(keyDown, on: channel.descriptor)
    XCTAssertEqual(model.isReceiving, true)
    let duplicate = await model.handle(keyDown, on: channel.descriptor)

    XCTAssertEqual(duplicate, .discarded)
    XCTAssertFalse(model.isReceiving)
    XCTAssertTrue(model.statusMessage.contains("Repeated input"))
    XCTAssertTrue(sink.events.suffix(2).contains {
      if case .key(usage: 8, keyCode: 0x0E, pressed: false, modifiers: 2) = $0 { true } else { false }
    })
    model.shutdown()
  }

  func testPhoneCannotSendMacOnlySessionEndedMessage() async throws {
    let sink = PhoneInputEventSinkFake()
    let model = MacPhoneInputModel(eventAdapter: MacPhoneInputEventAdapter(sink: sink))
    let channel = MockSecuredChannel(transport: "ble")
    let session = "01234567-89ab-4cde-8fab-0123456789ab"
    model.available(channel)
    await eventually { channel.sentData.contains { (try? PhoneInputMessage.decode($0))?.kind == 1 } }
    _ = await model.handle(
      try PhoneInputMessage.of(1, .integer(1024), .integer(7)).encode(), on: channel.descriptor)
    model.arm(ownerID: UUID(), for: channel.descriptor.peer)
    _ = await model.handle(try PhoneInputMessage.of(2, .text(session)).encode(), on: channel.descriptor)
    await eventually { model.isReceiving }
    _ = await model.handle(try PhoneInputMessage.of(
      5, .text(session), .integer(1), .integer(8), .integer(2), .bool(true)).encode(),
      on: channel.descriptor)

    let result = await model.handle(
      try PhoneInputMessage.of(11, .text(session), .integer(0)).encode(), on: channel.descriptor)

    XCTAssertEqual(result, .discarded)
    XCTAssertFalse(model.isReceiving)
    XCTAssertTrue(model.statusMessage.contains("Invalid session-ended"))
    XCTAssertTrue(sink.events.contains {
      if case .key(usage: 8, keyCode: 0x0E, pressed: false, modifiers: 2) = $0 { true } else { false }
    })
    await eventually {
      channel.sentData.contains {
        guard let message = try? PhoneInputMessage.decode($0) else { return false }
        return message.kind == 11 && message.text(0) == session && message.number(1) == 2
      }
    }
    model.shutdown()
  }

  func testBLERetirementReleasesHeldKeysAndRequiresFreshArming() async throws {
    let sink = PhoneInputEventSinkFake()
    let model = MacPhoneInputModel(eventAdapter: MacPhoneInputEventAdapter(sink: sink))
    let channel = MockSecuredChannel(transport: "ble")
    let owner = UUID()
    let session = "01234567-89ab-4cde-8fab-0123456789ab"
    model.available(channel)
    await eventually { channel.sentData.contains { (try? PhoneInputMessage.decode($0))?.kind == 1 } }
    _ = await model.handle(
      try PhoneInputMessage.of(1, .integer(1024), .integer(7)).encode(), on: channel.descriptor)
    model.arm(ownerID: owner, for: channel.descriptor.peer)
    _ = await model.handle(try PhoneInputMessage.of(2, .text(session)).encode(), on: channel.descriptor)
    await eventually { model.isReceiving }
    _ = await model.handle(try PhoneInputMessage.of(
      5, .text(session), .integer(1), .integer(8), .integer(2), .bool(true)).encode(),
      on: channel.descriptor)

    model.retired(channel.descriptor)

    XCTAssertFalse(model.isReceiving)
    XCTAssertFalse(model.isArmed)
    XCTAssertTrue(sink.events.suffix(1).contains {
      if case .key(usage: 8, keyCode: 0x0E, pressed: false, modifiers: 2) = $0 { true } else { false }
    })
    XCTAssertTrue(model.statusMessage.contains("connection ended"))
    model.shutdown()
  }

  func testPeerMismatchAndUnadvertisedKeyEventsAreRejected() async throws {
    let sink = PhoneInputEventSinkFake()
    let model = MacPhoneInputModel(eventAdapter: MacPhoneInputEventAdapter(sink: sink))
    let channel = MockSecuredChannel(transport: "ble")
    let otherPeer = MockSecuredChannel(transport: "ble").descriptor.peer
    let owner = UUID()
    let session = "01234567-89ab-4cde-8fab-0123456789ab"
    model.available(channel)
    await eventually { channel.sentData.contains { (try? PhoneInputMessage.decode($0))?.kind == 1 } }
    _ = await model.handle(
      try PhoneInputMessage.of(1, .integer(1024), .integer(1)).encode(), on: channel.descriptor)
    model.arm(ownerID: owner, for: otherPeer)
    _ = await model.handle(try PhoneInputMessage.of(2, .text(session)).encode(), on: channel.descriptor)
    await eventually {
      (try? channel.sentData.compactMap { try PhoneInputMessage.decode($0) }
        .contains { $0.kind == 3 && $0.number(1) == 1 }) == true
    }
    XCTAssertFalse(model.isReceiving)

    model.arm(ownerID: owner, for: channel.descriptor.peer)
    _ = await model.handle(try PhoneInputMessage.of(2, .text(session)).encode(), on: channel.descriptor)
    await eventually { model.isReceiving }
    let key = try PhoneInputMessage.of(
      5, .text(session), .integer(1), .integer(8), .integer(2), .bool(true)).encode()
    _ = await model.handle(key, on: channel.descriptor)

    XCTAssertFalse(model.isReceiving)
    XCTAssertTrue(model.statusMessage.contains("did not advertise"))
    XCTAssertTrue(sink.events.isEmpty)
    model.shutdown()
  }

  func testDisarmingDuringStartResponseCannotActivateStaleOwner() async throws {
    let sink = PhoneInputEventSinkFake()
    let model = MacPhoneInputModel(eventAdapter: MacPhoneInputEventAdapter(sink: sink))
    let channel = MockSecuredChannel(transport: "ble")
    let owner = UUID()
    let session = "01234567-89ab-4cde-8fab-0123456789ab"
    model.available(channel)
    await eventually { channel.sentData.contains { (try? PhoneInputMessage.decode($0))?.kind == 1 } }
    _ = await model.handle(
      try PhoneInputMessage.of(1, .integer(1024), .integer(1)).encode(), on: channel.descriptor)
    model.arm(ownerID: owner, for: channel.descriptor.peer)

    var responseGate: CheckedContinuation<Void, Never>?
    channel.onSendData = { bytes in
      if (try? PhoneInputMessage.decode(bytes))?.kind == 3 {
        await withCheckedContinuation { responseGate = $0 }
      }
    }
    _ = await model.handle(try PhoneInputMessage.of(2, .text(session)).encode(), on: channel.descriptor)
    await eventually { responseGate != nil }
    model.disarm(ownerID: owner)
    responseGate?.resume()
    responseGate = nil
    await eventually { !model.isReceiving }
    await eventually {
      channel.sentData.contains {
        guard let message = try? PhoneInputMessage.decode($0) else { return false }
        return message.kind == 11 && message.text(0) == session && message.number(1) == 0
      }
    }

    XCTAssertFalse(model.isArmed)
    XCTAssertFalse(model.isReceiving)
    XCTAssertEqual(model.statusMessage, "Phone input is off.")
    let sent = try channel.sentData.compactMap { try PhoneInputMessage.decode($0) }
    let acceptedIndex = try XCTUnwrap(sent.firstIndex { $0.kind == 3 && $0.number(1) == 0 })
    let endedIndex = try XCTUnwrap(sent.firstIndex { $0.kind == 11 && $0.text(0) == session })
    XCTAssertLessThan(acceptedIndex, endedIndex)
    model.shutdown()
  }

  private func eventually(
    file: StaticString = #filePath, line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    for _ in 0..<200 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Condition did not become true", file: file, line: line)
  }
}
