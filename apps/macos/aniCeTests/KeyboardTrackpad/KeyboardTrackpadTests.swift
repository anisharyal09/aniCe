// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises trusted-phone selection, association lifecycle and clipboard prevalidation.
import CryptoKit
import AppKit
import Foundation
import XCTest
import Observation
import SwiftUI

@testable import aniCe

@MainActor final class FakeKeyboardTrackpadTransport: KeyboardTrackpadTransport {
  enum Write: Equatable {
    case keyboard(UInt8, [UInt8])
    case mouse(UInt8, Int, Int, Int)
    case navigation(UInt16, Bool)
  }

  var stateChanged: (@MainActor @Sendable (KeyboardTrackpadTransportEvent) -> Void)?
  var devices: [PairedBluetoothDevice] = []
  var deferPairingRefresh = false
  var pendingPairingRefreshes: [KeyboardTrackpadDevicesCompletion] = []
  var deferConnect = false
  var connectResult: KeyboardTrackpadTransportResult = .success
  var pendingConnect: KeyboardTrackpadResultCompletion?
  var completeWrites = true
  var pendingWrites: [KeyboardTrackpadResultCompletion] = []
  var writes: [Write] = []
  var connectedAddresses: [String] = []
  var connectedGenerations: [UInt64] = []
  var disconnectCount = 0
  var didShutdown = false

  func pairedDevices(_ completion: @escaping KeyboardTrackpadDevicesCompletion) {
    if deferPairingRefresh { pendingPairingRefreshes.append(completion) }
    else { completion(devices) }
  }
  func connect(address: String, generation: UInt64, completion: @escaping KeyboardTrackpadResultCompletion) {
    connectedAddresses.append(address)
    connectedGenerations.append(generation)
    if deferConnect { pendingConnect = completion } else { completion(connectResult) }
  }
  func keyboard(modifiers: UInt8, usages: [UInt8], completion: @escaping KeyboardTrackpadResultCompletion) {
    writes.append(.keyboard(modifiers, usages))
    complete(completion)
  }
  func mouse(buttons: UInt8, deltaX: Int, deltaY: Int, wheel: Int, completion: @escaping KeyboardTrackpadResultCompletion) {
    writes.append(.mouse(buttons, deltaX, deltaY, wheel))
    complete(completion)
  }
  func navigation(usage: UInt16, pressed: Bool, completion: @escaping KeyboardTrackpadResultCompletion) {
    writes.append(.navigation(usage, pressed))
    complete(completion)
  }
  func disconnect(completion: @escaping KeyboardTrackpadVoidCompletion) { disconnectCount += 1; completion() }
  func shutdown() { didShutdown = true }

  func finishConnect(_ result: KeyboardTrackpadTransportResult = .success) {
    let completion = pendingConnect
    pendingConnect = nil
    completion?(result)
  }
  func finishWrite(_ result: KeyboardTrackpadTransportResult = .success) {
    guard !pendingWrites.isEmpty else { return }
    pendingWrites.removeFirst()(result)
  }

  private func complete(_ completion: @escaping KeyboardTrackpadResultCompletion) {
    if completeWrites { completion(.success) }
    else { pendingWrites.append(completion) }
  }
}

final class KeyboardTrackpadTests: XCTestCase {
  @MainActor func testActiveBlePhoneIsTheAutomaticDefaultWithoutReroutingLiveInput() throws {
    let a = try phone("A"), b = try phone("B")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(a)]
    let model = MacKeyboardTrackpadModel(transport: transport, preferences: testDefaults())
    defer { model.shutdown() }
    model.updateTargets([a, b], connectedPeerIDs: [a.deviceId, b.deviceId], peerContextID: b.deviceId, connectedBLEPeerID: a.deviceId)
    XCTAssertEqual(model.targetPeer, a)
    model.refreshPairedDevices()
    XCTAssertTrue(model.link(paired(a)))
    model.connect()
    model.requestControl(on: .keyboard)
    model.updateTargets([a, b], connectedPeerIDs: [a.deviceId, b.deviceId], peerContextID: nil, connectedBLEPeerID: b.deviceId)
    XCTAssertEqual(model.targetPeer, a)
    XCTAssertTrue(model.isControlling)
    model.disconnect()
    model.updateTargets([a, b], connectedPeerIDs: [a.deviceId, b.deviceId], peerContextID: nil, connectedBLEPeerID: b.deviceId)
    XCTAssertEqual(model.targetPeer, b)
    model.selectTarget(a)
    model.updateTargets([a, b], connectedPeerIDs: [a.deviceId, b.deviceId], peerContextID: nil, connectedBLEPeerID: b.deviceId)
    XCTAssertEqual(model.targetPeer, a, "Other devices remains a deliberate override.")
  }

  @MainActor func testInitialEmptyTrustSnapshotPreservesSavedLinkUntilTrustLoads() throws {
    let peer = try phone("Phone")
    let preferences = testDefaults()
    let associations = KeyboardTrackpadAssociations(storage: preferences)
    XCTAssertTrue(associations.associate(paired(peer).address, with: peer))
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = MacKeyboardTrackpadModel(transport: transport, preferences: preferences)
    defer { model.shutdown() }
    model.updateTargets([], connectedPeerIDs: [], peerContextID: nil)
    model.enterPanel()
    XCTAssertNil(model.targetPeer)
    XCTAssertTrue(transport.connectedAddresses.isEmpty)
    XCTAssertEqual(KeyboardTrackpadAssociations(storage: preferences).address(for: peer), paired(peer).address)
    model.updateTargets([peer], connectedPeerIDs: [peer.deviceId], peerContextID: nil, connectedBLEPeerID: peer.deviceId)
    XCTAssertEqual(model.phase, .connectedIdle)
    XCTAssertEqual(transport.connectedAddresses, [paired(peer).address])
    XCTAssertFalse(model.isControlling)
    model.trustWasRemoved(retaining: [])
    XCTAssertNil(KeyboardTrackpadAssociations(storage: preferences).address(for: peer))
    XCTAssertNil(model.targetPeer)
  }

  @MainActor func testSelectionRequiresTrustedPeerAndDoesNotChooseAnUnconnectedPhone() throws {
    let phoneA = try phone("Phone A")
    let phoneB = try phone("Phone B")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(phoneA)]
    let model = MacKeyboardTrackpadModel(transport: transport, preferences: testDefaults())
    defer { model.shutdown() }

    model.updateTargets([phoneA, phoneB], connectedPeerIDs: [], peerContextID: nil)
    XCTAssertNil(model.targetPeer)

    model.updateTargets([phoneA, phoneB], connectedPeerIDs: [phoneA.deviceId], peerContextID: nil)
    XCTAssertEqual(model.targetPeer, phoneA)

    model.selectTarget(phoneB)
    XCTAssertEqual(model.targetPeer, phoneB)
    XCTAssertTrue(model.needsDeviceLink)
  }

  @MainActor func testExplicitContextAndLastDeliberateSelectionAreStable() throws {
    let phoneA = try phone("Phone")
    let phoneB = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    let model = MacKeyboardTrackpadModel(transport: transport, preferences: testDefaults())
    defer { model.shutdown() }

    model.updateTargets([phoneA, phoneB], connectedPeerIDs: [phoneA.deviceId, phoneB.deviceId], peerContextID: phoneB.deviceId)
    XCTAssertEqual(model.targetPeer, phoneB)

    model.selectTarget(phoneA)
    model.updateTargets([phoneA, phoneB], connectedPeerIDs: [phoneA.deviceId, phoneB.deviceId], peerContextID: nil)
    XCTAssertEqual(model.targetPeer, phoneA)
  }

  @MainActor func testDuplicateNamesOnlySuggestCandidatesAndLinkIsExplicit() throws {
    let phone = try self.phone("Galaxy A34")
    let transport = FakeKeyboardTrackpadTransport()
    let candidateA = PairedBluetoothDevice(address: "10:20:30:40:50:60", name: "Galaxy A34")
    let candidateB = PairedBluetoothDevice(address: "AA:BB:CC:DD:EE:FF", name: "Galaxy A34")
    transport.devices = [candidateA, candidateB]
    let model = MacKeyboardTrackpadModel(transport: transport, preferences: testDefaults())
    defer { model.shutdown() }

    model.updateTargets([phone], connectedPeerIDs: [phone.deviceId], peerContextID: nil)
    model.refreshPairedDevices()
    XCTAssertEqual(model.matchingPairedDevices.map(\.address), [candidateA.address, candidateB.address])
    XCTAssertNil(model.targetAddress, "A matching system name must never link by itself.")
    XCTAssertTrue(model.link(candidateB))
    XCTAssertEqual(model.targetAddress, candidateB.address)
    XCTAssertTrue(model.canConnect)
  }

  @MainActor func testLinkConfirmationRejectsChangedPhoneWithoutWritingAssociation() throws {
    let a = try phone("Same name"), b = try phone("Same name")
    let preferences = testDefaults()
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(a)]
    let model = MacKeyboardTrackpadModel(transport: transport, preferences: preferences)
    defer { model.shutdown() }
    model.updateTargets([a, b], connectedPeerIDs: [a.deviceId], peerContextID: nil, connectedBLEPeerID: a.deviceId)
    model.refreshPairedDevices()
    let confirmedKey = try XCTUnwrap(model.targetKey)
    model.updateTargets([a, b], connectedPeerIDs: [b.deviceId], peerContextID: nil, connectedBLEPeerID: b.deviceId)
    XCTAssertEqual(model.targetPeer, b)
    XCTAssertFalse(model.link(paired(a), expectedPeerKey: confirmedKey))
    let saved = KeyboardTrackpadAssociations(storage: preferences)
    XCTAssertNil(saved.address(for: a))
    XCTAssertNil(saved.address(for: b))
    XCTAssertTrue(transport.connectedAddresses.isEmpty)
    XCTAssertTrue(model.link(paired(b), expectedPeerKey: KeyboardTrackpadAssociations.peerKey(b)))
  }

  @MainActor func testOlderPairingRefreshCannotOverwriteNewerDevices() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.deferPairingRefresh = true
    let model = MacKeyboardTrackpadModel(transport: transport, preferences: testDefaults())
    defer { model.shutdown() }
    model.updateTargets([peer], connectedPeerIDs: [peer.deviceId], peerContextID: nil)
    model.refreshPairedDevices()
    model.refreshPairedDevices()
    XCTAssertEqual(transport.pendingPairingRefreshes.count, 2)
    transport.pendingPairingRefreshes[1]([paired(peer)])
    XCTAssertTrue(model.link(paired(peer)))
    model.connect()
    model.requestControl(on: .keyboard)
    transport.pendingPairingRefreshes[0]([])
    XCTAssertEqual(model.pairedDevices, [paired(peer)])
    XCTAssertTrue(model.isControlling)
    XCTAssertEqual(transport.disconnectCount, 0)
    model.shutdown()
    transport.pendingPairingRefreshes[1]([])
    XCTAssertEqual(model.pairedDevices, [paired(peer)])
  }

  @MainActor func testExplicitDisconnectDoesNotAutomaticallyReconnectDuringFeatureVisit() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    model.enterPanel()
    model.disconnect()
    model.refreshPairedDevices()
    XCTAssertEqual(model.phase, .disconnected)
    XCTAssertEqual(transport.connectedAddresses.count, 1)
    model.leavePanel()
    model.enterPanel()
    XCTAssertEqual(transport.connectedAddresses.count, 2)
    XCTAssertEqual(model.phase, .connectedIdle)
  }

  @MainActor func testPairingListDeduplicatesNormalizedAddressesAndPreservesDistinctDevices() throws {
    let peer = try phone("Galaxy A34")
    let first = PairedBluetoothDevice(address: "AA:BB:CC:DD:EE:FF", name: "Galaxy A34")
    let second = PairedBluetoothDevice(address: "10:20:30:40:50:60", name: "Galaxy A34")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [first,
      PairedBluetoothDevice(address: "aa-bb-cc-dd-ee-ff", name: "Galaxy A34"),
      second, first, PairedBluetoothDevice(address: "invalid", name: "Galaxy A34")]
    let model = MacKeyboardTrackpadModel(transport: transport, preferences: testDefaults())
    defer { model.shutdown() }
    model.updateTargets([peer], connectedPeerIDs: [peer.deviceId], peerContextID: nil)
    model.refreshPairedDevices()
    XCTAssertEqual(model.pairedDevices, [first, second])
    XCTAssertEqual(model.matchingPairedDevices, [first, second])
    model.refreshPairedDevices()
    XCTAssertEqual(model.pairedDevices, [first, second])
  }

  @MainActor func testLinkAndFeatureEntryConnectAutomaticallyWithoutArmingInput() throws {
    let peer = try phone("Galaxy A34")
    let candidate = paired(peer)
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [candidate]
    let model = MacKeyboardTrackpadModel(transport: transport, preferences: testDefaults())
    defer { model.shutdown() }

    model.updateTargets([peer], connectedPeerIDs: [peer.deviceId], peerContextID: nil)
    model.enterPanel()
    XCTAssertTrue(model.link(candidate))
    XCTAssertEqual(transport.connectedAddresses, [candidate.address])
    XCTAssertEqual(model.phase, .connectedIdle)
    XCTAssertFalse(model.isControlling, "Automatic connection must not capture keyboard input.")

    model.disconnect()
    XCTAssertEqual(model.phase, .disconnected)
    model.refreshPairedDevices()
    XCTAssertEqual(transport.connectedAddresses.count, 1, "A manual disconnect must not trigger an automatic reconnect in the same visit.")

    model.leavePanel()
    model.enterPanel()
    XCTAssertEqual(transport.connectedAddresses, [candidate.address, candidate.address])
    XCTAssertEqual(model.phase, .connectedIdle)
    XCTAssertFalse(model.isControlling)
  }

  @MainActor func testSavedAssociationReconnectsOncePerFeatureVisitAndRetriesNextVisit() throws {
    let peer = try phone("Galaxy")
    let candidate = paired(peer)
    let preferences = testDefaults()
    XCTAssertTrue(KeyboardTrackpadAssociations(storage: preferences).associate(candidate.address, with: peer))
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [candidate]
    transport.connectResult = .failure("Bluetooth is temporarily unavailable.")
    let model = MacKeyboardTrackpadModel(transport: transport, preferences: preferences)
    defer { model.shutdown() }
    model.updateTargets([peer], connectedPeerIDs: [peer.deviceId], peerContextID: nil)

    model.enterPanel()
    XCTAssertEqual(transport.connectedAddresses, [candidate.address])
    XCTAssertEqual(model.phase, .failed)
    model.refreshPairedDevices()
    model.refreshPairedDevices()
    XCTAssertEqual(transport.connectedAddresses.count, 1, "A failure must not cause a refresh-driven retry loop.")

    transport.connectResult = .success
    model.leavePanel()
    model.enterPanel()
    XCTAssertEqual(transport.connectedAddresses, [candidate.address, candidate.address])
    XCTAssertEqual(model.phase, .connectedIdle)
  }

  @MainActor func testChangingTrustedPhoneConnectsOnlyTheSelectedTarget() throws {
    let phoneA = try phone("Phone A")
    let phoneB = try phone("Phone B")
    let deviceA = paired(phoneA)
    let deviceB = PairedBluetoothDevice(address: "10:20:30:40:50:60", name: phoneB.deviceName)
    let preferences = testDefaults()
    let associations = KeyboardTrackpadAssociations(storage: preferences)
    XCTAssertTrue(associations.associate(deviceA.address, with: phoneA))
    XCTAssertTrue(associations.associate(deviceB.address, with: phoneB))
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [deviceA, deviceB]
    let model = MacKeyboardTrackpadModel(transport: transport, preferences: preferences)
    defer { model.shutdown() }
    model.updateTargets([phoneA, phoneB], connectedPeerIDs: [phoneA.deviceId], peerContextID: phoneA.deviceId)
    model.enterPanel()
    XCTAssertEqual(transport.connectedAddresses, [deviceA.address])

    model.selectTarget(phoneB)
    XCTAssertEqual(transport.connectedAddresses, [deviceA.address, deviceB.address])
    XCTAssertEqual(model.targetPeer, phoneB)

    model.selectTarget(phoneA)
    XCTAssertEqual(transport.connectedAddresses, [deviceA.address, deviceB.address, deviceA.address])
    XCTAssertEqual(model.targetPeer, phoneA)
    XCTAssertEqual(model.phase, .connectedIdle)
  }

  @MainActor func testExplicitReassignmentMovesAddressToTheNewTrustedPeer() throws {
    let phoneA = try phone("Galaxy")
    let phoneB = try phone("Galaxy")
    let candidate = PairedBluetoothDevice(address: "AA:BB:CC:DD:EE:FF", name: "Galaxy")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [candidate]
    let preferences = testDefaults()
    let model = MacKeyboardTrackpadModel(transport: transport, preferences: preferences)
    defer { model.shutdown() }

    model.updateTargets([phoneA, phoneB], connectedPeerIDs: [phoneA.deviceId], peerContextID: nil)
    model.refreshPairedDevices()
    XCTAssertTrue(model.link(candidate))
    XCTAssertEqual(KeyboardTrackpadAssociations(storage: preferences).address(for: phoneA), candidate.address)

    model.selectTarget(phoneB)
    XCTAssertTrue(model.link(candidate))
    XCTAssertNil(KeyboardTrackpadAssociations(storage: preferences).address(for: phoneA))
    XCTAssertEqual(KeyboardTrackpadAssociations(storage: preferences).address(for: phoneB), candidate.address)
  }

  @MainActor func testExplicitRelinkCanReplaceTheCurrentPhoneAssociation() throws {
    let peer = try phone("Galaxy")
    let first = PairedBluetoothDevice(address: "AA:BB:CC:DD:EE:FF", name: "Galaxy")
    let second = PairedBluetoothDevice(address: "10:20:30:40:50:60", name: "Galaxy")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [first, second]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }

    XCTAssertEqual(model.targetAddress, first.address)
    model.relinkBluetoothDevice()
    XCTAssertTrue(model.needsDeviceLink)
    XCTAssertTrue(model.link(second))
    XCTAssertEqual(model.targetAddress, second.address)
  }

  @MainActor func testMissingPairingAndInvalidSavedAddressReturnToSetup() throws {
    let peer = try phone("Phone")
    let preferences = testDefaults()
    let key = KeyboardTrackpadAssociations.peerKey(peer)
    preferences.set([key: "not-a-bluetooth-address"], forKey: "keyboardTrackpad.bluetoothAssociations")
    let associations = KeyboardTrackpadAssociations(storage: preferences)
    XCTAssertNil(associations.address(for: peer))
    XCTAssertNil(preferences.dictionary(forKey: "keyboardTrackpad.bluetoothAssociations")?[key])

    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = MacKeyboardTrackpadModel(transport: transport, preferences: preferences)
    defer { model.shutdown() }
    model.updateTargets([peer], connectedPeerIDs: [peer.deviceId], peerContextID: nil)
    model.refreshPairedDevices()
    XCTAssertTrue(model.link(paired(peer)))
    XCTAssertTrue(model.canConnect)

    transport.devices = []
    model.refreshPairedDevices()
    XCTAssertTrue(model.needsDeviceLink)
    XCTAssertFalse(model.canConnect)
    XCTAssertEqual(model.phase, .setupNeeded)
  }

  @MainActor func testTrustRemovalAndIdentityResetClearAssociationsWithoutFallback() throws {
    let phoneA = try phone("Phone A")
    let phoneB = try phone("Phone B")
    let candidate = paired(phoneA)
    let preferences = testDefaults()
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [candidate]
    let model = MacKeyboardTrackpadModel(transport: transport, preferences: preferences)
    defer { model.shutdown() }

    model.updateTargets([phoneA, phoneB], connectedPeerIDs: [phoneA.deviceId], peerContextID: nil)
    model.refreshPairedDevices()
    XCTAssertTrue(model.link(candidate))
    XCTAssertEqual(KeyboardTrackpadAssociations(storage: preferences).address(for: phoneA), candidate.address)
    model.trustWasRemoved(retaining: [phoneB])
    XCTAssertNil(KeyboardTrackpadAssociations(storage: preferences).address(for: phoneA))
    XCTAssertNil(model.targetPeer, "Trust removal must not fall through to a different phone.")
    XCTAssertFalse(model.connectedPeerIDs.contains(phoneA.deviceId))

    model.selectTarget(phoneB)
    XCTAssertEqual(model.targetPeer, phoneB)
    XCTAssertTrue(model.link(candidate))
    XCTAssertEqual(KeyboardTrackpadAssociations(storage: preferences).address(for: phoneB), candidate.address)
    model.identityWasReset()
    XCTAssertNil(KeyboardTrackpadAssociations(storage: preferences).address(for: phoneB))
    XCTAssertNil(model.targetPeer)
    XCTAssertEqual(model.phase, .setupNeeded)
  }

  @MainActor func testCancelledConnectCannotArmAfterFocusWasLost() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    transport.deferConnect = true
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }

    model.requestControl(on: .keyboard)
    XCTAssertEqual(model.phase, .connecting)
    model.surfaceLost(.keyboard)
    model.disconnect()
    transport.finishConnect()
    XCTAssertEqual(model.phase, .disconnected)
    XCTAssertFalse(model.isControlling)
  }

  @MainActor func testEndingAnIdleKeyboardCaptureSendsNeutralReleaseAndKeepsLinkOpen() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }

    model.connect()
    model.requestControl(on: .keyboard)
    XCTAssertTrue(model.isControlling)
    model.stopControlling()
    XCTAssertEqual(transport.writes, [.keyboard(0, [])])
    XCTAssertEqual(model.phase, .connectedIdle)
    XCTAssertEqual(transport.disconnectCount, 0)
  }

  @MainActor func testIdleNavigationUsesTheSelectedPhoneWithoutArmingCapture() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }

    model.connect()
    model.sendNavigation(usage: 0x0224)
    XCTAssertEqual(transport.writes, [.navigation(0x0224, true)])
    XCTAssertEqual(model.canTypeClipboard, false, "The matching release must finish before another idle action can start.")
    model.applicationWasInterrupted()
    XCTAssertEqual(transport.writes, [.navigation(0x0224, true), .navigation(0x0224, false)])
    XCTAssertFalse(model.isControlling)
    XCTAssertEqual(model.phase, .connectedIdle)
  }

  @MainActor func testNavigationCancellationWaitsForPressThenSendsOneRelease() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    transport.completeWrites = false
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()

    model.sendNavigation(usage: 0x0224)
    model.applicationWasInterrupted()
    XCTAssertEqual(transport.writes, [.navigation(0x0224, true)])
    transport.finishWrite()
    XCTAssertEqual(transport.writes, [.navigation(0x0224, true), .navigation(0x0224, false)])
    XCTAssertFalse(model.canTypeClipboard)
    transport.finishWrite()
    XCTAssertTrue(model.canTypeClipboard)
  }

  @MainActor func testDeviceWideDisconnectClosesOnlyTheSelectedPhoneHID() throws {
    let phoneA = try phone("Phone A")
    let phoneB = try phone("Phone B")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(phoneA)]
    let model = readyModel(peer: phoneA, transport: transport)
    defer { model.shutdown() }

    model.deviceWasDisconnected(phoneB)
    XCTAssertEqual(transport.disconnectCount, 0)
    model.deviceWasDisconnected(phoneA)
    XCTAssertEqual(transport.disconnectCount, 1)
    XCTAssertEqual(model.phase, .disconnected)
  }

  @MainActor func testQueueOverflowReleasesInputAndFailedWriteDoesNotRetry() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    transport.completeWrites = false
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }

    model.connect()
    model.requestControl(on: .keyboard)
    model.keyDown(usage: 0x04, modifiers: 0)
    for _ in 0..<70 {
      model.keyUp(usage: 0x04, modifiers: 0)
      model.keyDown(usage: 0x04, modifiers: 0)
    }
    XCTAssertFalse(model.isControlling)
    XCTAssertEqual(model.phase, .connectedIdle)
    transport.finishWrite()
    XCTAssertEqual(transport.pendingWrites.count, 1, "Overflow should send one neutral keyboard report after the in-flight write.")

    transport.finishWrite(.failure("simulated write failure"))
    XCTAssertEqual(model.phase, .failed)
    XCTAssertEqual(transport.connectedAddresses.count, 1, "A failed write must not retry or replay input.")
  }

  @MainActor func testClipboardPrevalidationAndCancellationBetweenReports() throws {
    XCTAssertEqual(MacKeyboardTrackpadModel.clipboardKeyStrokes(""), .failure(.empty))
    XCTAssertEqual(MacKeyboardTrackpadModel.clipboardKeyStrokes(String(repeating: "a", count: 1_025)), .failure(.tooLong))
    XCTAssertEqual(MacKeyboardTrackpadModel.clipboardKeyStrokes("a\r\nb"), .success([
      KeyboardTrackpadKeyStroke(usage: 0x04, modifiers: 0),
      KeyboardTrackpadKeyStroke(usage: 0x28, modifiers: 0),
      KeyboardTrackpadKeyStroke(usage: 0x05, modifiers: 0)
    ]))
    for text in ["é", "\u{0000}", "\u{000B}", "\u{007F}"] {
      guard case .failure(.unsupported) = MacKeyboardTrackpadModel.clipboardKeyStrokes(text) else {
        return XCTFail("Expected unsupported content to be rejected before any report.")
      }
    }
    XCTAssertEqual(MacKeyboardTrackpadModel.clipboardKeyStrokes(String(repeating: "a", count: 1_024)).getOrNil()?.count, 1_024)
    XCTAssertEqual(MacKeyboardTrackpadModel.clipboardKeyStrokes(String(repeating: "\r\n", count: 1_024)).getOrNil()?.count, 1_024)
    XCTAssertEqual(MacKeyboardTrackpadModel.clipboardKeyStrokes(String(repeating: "a", count: 1_000_000)), .failure(.tooLong))

    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    model.typeClipboardSnapshot("a")
    XCTAssertEqual(transport.writes, [.keyboard(0, [0x04])])
    model.stopTyping()
    XCTAssertEqual(transport.writes, [.keyboard(0, [0x04]), .keyboard(0, [])])
    XCTAssertFalse(model.isTypingClipboard)
    XCTAssertEqual(model.phase, .connectedIdle)
  }

  @MainActor func testPairingRefreshPreservesLiveCaptureAndRetiresMissingPairing() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    model.refreshPairedDevices()
    XCTAssertEqual(model.phase, .connectedIdle)
    model.requestControl(on: .keyboard)
    model.refreshPairedDevices()
    XCTAssertTrue(model.isControlling)
    transport.devices = []
    model.refreshPairedDevices()
    XCTAssertEqual(model.phase, .setupNeeded)
    XCTAssertEqual(transport.disconnectCount, 1)
  }

  @MainActor func testFractionalMotionDoesNotBlockMouseRelease() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    model.requestControl(on: .pad)
    model.pointerButtonDown()
    model.pointerMoved(deltaX: 0.25, deltaY: 0)
    model.pointerButtonUp()
    XCTAssertEqual(transport.writes, [.mouse(1, 0, 0, 0), .mouse(0, 0, 0, 0)])
  }

  @MainActor func testDragRemainderPrecedesMouseRelease() async throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    transport.completeWrites = false
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    model.requestControl(on: .pad)
    model.pointerButtonDown()
    model.pointerMoved(deltaX: 300, deltaY: 0)
    model.pointerButtonUp()
    for _ in 0..<8 {
      transport.finishWrite()
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(transport.writes, [.mouse(1, 0, 0, 0), .mouse(1, 127, 0, 0),
      .mouse(1, 127, 0, 0), .mouse(1, 46, 0, 0), .mouse(0, 0, 0, 0)])
  }

  @MainActor func testOldTransportEventsCannotReviveOrChangeANewConnection() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    let old = try XCTUnwrap(transport.connectedGenerations.last)
    model.disconnect()
    transport.stateChanged?(.changed(generation: old, ready: true, suspended: false, reportProtocol: false, message: nil))
    XCTAssertEqual(model.phase, .disconnected)
    model.connect()
    transport.stateChanged?(.changed(generation: old, ready: false, suspended: false, reportProtocol: false, message: "old failure"))
    XCTAssertEqual(model.phase, .connectedIdle)
    XCTAssertTrue(model.reportProtocol)
  }

  @MainActor func testSuspendCancelsCaptureWithoutSendingAndResumeDoesNotRearm() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    model.requestControl(on: .keyboard)
    transport.completeWrites = false
    model.keyDown(usage: 4, modifiers: 0)
    let generation = try XCTUnwrap(transport.connectedGenerations.last)
    transport.stateChanged?(.changed(generation: generation, ready: true, suspended: true, reportProtocol: true, message: nil))
    XCTAssertEqual(model.phase, .suspended)
    transport.finishWrite(.failure("suspended"))
    XCTAssertEqual(model.phase, .suspended)
    XCTAssertEqual(transport.writes, [.keyboard(0, [4])])
    transport.stateChanged?(.changed(generation: generation, ready: true, suspended: false, reportProtocol: true, message: nil))
    XCTAssertEqual(model.phase, .connectedIdle)
    XCTAssertFalse(model.isControlling)
  }

  @MainActor func testExplicitLinkAllowsDifferentSystemName() throws {
    let peer = try phone("My phone")
    let transport = FakeKeyboardTrackpadTransport()
    let candidate = PairedBluetoothDevice(address: "AA:BB:CC:DD:EE:FF", name: "Galaxy A34")
    transport.devices = [candidate]
    let model = MacKeyboardTrackpadModel(transport: transport, preferences: testDefaults())
    defer { model.shutdown() }
    model.updateTargets([peer], connectedPeerIDs: [peer.deviceId], peerContextID: nil)
    model.refreshPairedDevices()
    XCTAssertTrue(model.matchingPairedDevices.isEmpty)
    XCTAssertNil(model.targetAddress)
    XCTAssertTrue(model.link(candidate))
    XCTAssertEqual(model.targetAddress, candidate.address)
    transport.connectResult = .failure("old failure")
    model.connect()
    XCTAssertEqual(model.failureMessage, "old failure")
    XCTAssertTrue(model.link(candidate))
    XCTAssertNil(model.failureMessage)
    model.relinkBluetoothDevice()
    XCTAssertFalse(model.canConnect)
    let attempts = transport.connectedAddresses.count
    model.connect()
    XCTAssertEqual(transport.connectedAddresses.count, attempts)
  }

  @MainActor func testRecentAppsUsesAniKeyChordInOrder() async throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    model.sendRecentApps()
    for _ in 0..<100 {
      if model.canTypeClipboard { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(transport.writes, [.keyboard(0, []), .keyboard(8, []),
      .keyboard(8, [0x2B]), .keyboard(8, []), .keyboard(0, [])])
    XCTAssertTrue(model.canTypeClipboard)
  }

  @MainActor func testSidewaysGestureReleasesAndDoesNotOverridePhysicalDrag() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    model.requestControl(on: .pad)
    model.scrollGesture(deltaX: 4, deltaY: 0, phase: .began, precise: true, momentum: false)
    XCTAssertTrue(transport.writes.isEmpty)
    model.scrollGesture(deltaX: 8, deltaY: 0, phase: .changed, precise: true, momentum: false)
    model.scrollGesture(deltaX: 0, deltaY: 0, phase: .ended, precise: true, momentum: false)
    XCTAssertEqual(transport.writes, [.mouse(1, 0, 0, 0), .mouse(1, 12, 0, 0), .mouse(0, 0, 0, 0)])
    model.pointerButtonDown()
    let count = transport.writes.count
    model.scrollGesture(deltaX: 20, deltaY: 0, phase: .began, precise: true, momentum: false)
    model.cancelScrollGesture()
    XCTAssertEqual(transport.writes.count, count)
    model.pointerButtonUp()
  }

  @MainActor func testPadConsumesArmingMouseDownThroughMouseUp() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    let view = MousePadNSView()
    view.model = model
    let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
      modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
      modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    view.mouseDown(with: down)
    view.mouseDragged(with: down)
    view.mouseUp(with: up)
    XCTAssertTrue(model.isControlling)
    XCTAssertTrue(transport.writes.isEmpty)
    view.mouseDown(with: down)
    view.mouseUp(with: up)
    XCTAssertEqual(transport.writes, [.mouse(1, 0, 0, 0), .mouse(0, 0, 0, 0)])
  }

  @MainActor func testSurfaceSwitchKeepsNeutralReleaseAheadOfNewInput() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    transport.completeWrites = false
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    model.requestControl(on: .keyboard)
    model.keyDown(usage: 4, modifiers: 0)
    model.stopControlling()
    model.requestControl(on: .pad)
    model.pointerButtonDown()
    transport.finishWrite()
    XCTAssertEqual(transport.writes, [.keyboard(0, [4]), .keyboard(0, [])])
    transport.finishWrite()
    XCTAssertEqual(transport.writes.last, .mouse(1, 0, 0, 0))
  }

  @MainActor func testRecentAppsCancellationReleasesModifierWithoutSendingTab() async throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    transport.completeWrites = false
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    model.sendRecentApps()
    transport.finishWrite()
    for _ in 0..<100 {
      if transport.writes.count == 2 { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertEqual(transport.writes, [.keyboard(0, []), .keyboard(8, [])])
    model.applicationWasInterrupted()
    transport.finishWrite()
    transport.finishWrite()
    XCTAssertEqual(transport.writes, [.keyboard(0, []), .keyboard(8, []), .keyboard(0, [])])
    XCTAssertTrue(model.canTypeClipboard)
  }

  @MainActor private func readyModel(
    peer: DeviceIdentity,
    transport: FakeKeyboardTrackpadTransport
  ) -> MacKeyboardTrackpadModel {
    let model = MacKeyboardTrackpadModel(transport: transport, preferences: testDefaults())
    model.updateTargets([peer], connectedPeerIDs: [peer.deviceId], peerContextID: nil)
    model.refreshPairedDevices()
    XCTAssertTrue(model.link(paired(peer)))
    return model
  }

  @MainActor func testPresetReleasesHeldInputBeforeTapAndReturnsToIdle() async throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    model.requestControl(on: .keyboard)
    model.keyDown(usage: 4, modifiers: 2)
    XCTAssertTrue(model.canSendShortcut)
    transport.completeWrites = false
    model.sendTap(usage: 0x29)
    XCTAssertEqual(transport.writes, [.keyboard(2, [4]), .keyboard(0, [])])
    XCTAssertEqual(model.phase, .connectedIdle)
    transport.finishWrite()
    XCTAssertEqual(transport.writes.last, .keyboard(0, [0x29]))
    transport.finishWrite()
    try await Task.sleep(for: .milliseconds(70))
    XCTAssertEqual(transport.writes.last, .keyboard(0, []))
    transport.finishWrite()
    try await Task.sleep(for: .milliseconds(70))
    XCTAssertTrue(model.canSendShortcut)
    XCTAssertTrue(model.canTypeClipboard)
    XCTAssertEqual(transport.writes, [.keyboard(2, [4]), .keyboard(0, []), .keyboard(0, [0x29]), .keyboard(0, [])])
    transport.completeWrites = true
    model.requestControl(on: .pad)
    model.pointerButtonDown()
    XCTAssertTrue(model.canSendShortcut)
    model.sendNavigation(usage: 0x0223)
    XCTAssertEqual(Array(transport.writes.suffix(3)), [.mouse(1, 0, 0, 0), .mouse(0, 0, 0, 0), .navigation(0x0223, true)])
  }

  @MainActor func testNativeInputSurfacesReleaseHeldInputWhenFocusMoves() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    let keyboard = KeyboardInputNSView()
    keyboard.model = model
    model.requestControl(on: .keyboard)
    model.keyDown(usage: 4, modifiers: 2)
    XCTAssertTrue(keyboard.resignFirstResponder())
    XCTAssertEqual(model.phase, .connectedIdle)
    XCTAssertEqual(transport.writes.last, .keyboard(0, []))
    let pad = MousePadNSView()
    pad.model = model
    model.requestControl(on: .pad)
    model.pointerButtonDown()
    XCTAssertTrue(pad.resignFirstResponder())
    XCTAssertEqual(model.phase, .connectedIdle)
    XCTAssertEqual(transport.writes.last, .mouse(0, 0, 0, 0))
  }

  @MainActor func testButtonAvailabilityPublishesJobCompletionAndHeldInputChanges() async throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    let started = expectation(description: "Shortcut availability changes when a job starts")
    withObservationTracking { _ = model.canSendShortcut; _ = model.canTypeClipboard } onChange: { started.fulfill() }
    model.sendTap(usage: 0x28)
    await fulfillment(of: [started], timeout: 1)
    XCTAssertFalse(model.canSendShortcut)
    let finished = expectation(description: "Shortcut availability changes when a job completes")
    withObservationTracking { _ = model.canSendShortcut; _ = model.canTypeClipboard } onChange: { finished.fulfill() }
    await fulfillment(of: [finished], timeout: 1)
    try await Task.sleep(for: .milliseconds(130))
    XCTAssertTrue(model.canSendShortcut)
    XCTAssertTrue(model.canTypeClipboard)

  }

  @MainActor func testEveryVirtualKeyAndNavigationActionRestoresAvailability() async throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    for usage: UInt8 in [0x2B, 0x29, 0x2A, 0x28] {
      XCTAssertTrue(model.canSendShortcut)
      transport.writes.removeAll()
      model.sendTap(usage: usage)
      try await Task.sleep(for: .milliseconds(140))
      XCTAssertEqual(transport.writes, [.keyboard(0, [usage]), .keyboard(0, [])])
      XCTAssertTrue(model.canSendShortcut)
      XCTAssertTrue(model.canTypeClipboard)
    }
    for usage: UInt16 in [0x0224, 0x0223] {
      transport.writes.removeAll()
      model.sendNavigation(usage: usage)
      try await Task.sleep(for: .milliseconds(80))
      XCTAssertEqual(transport.writes, [.navigation(usage, true), .navigation(usage, false)])
      XCTAssertTrue(model.canSendShortcut)
    }
    transport.writes.removeAll()
    model.sendRecentApps()
    try await Task.sleep(for: .milliseconds(170))
    XCTAssertEqual(transport.writes, [.keyboard(0, []), .keyboard(8, []), .keyboard(8, [0x2B]), .keyboard(8, []), .keyboard(0, [])])
    XCTAssertTrue(model.canSendShortcut)
    XCTAssertTrue(model.canTypeClipboard)
  }

  @MainActor func testClickDuringAutomaticConnectionArmsOnlyWhileSurfaceKeepsFocus() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    transport.deferConnect = true
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.enterPanel()
    XCTAssertEqual(model.phase, .connecting)
    model.requestControl(on: .keyboard)
    transport.finishConnect()
    XCTAssertTrue(model.isControlling)
    XCTAssertEqual(model.currentSurface, .keyboard)
    XCTAssertTrue(transport.writes.isEmpty)
    model.disconnect()
    model.connect()
    model.requestControl(on: .keyboard)
    model.surfaceLost(.keyboard)
    transport.finishConnect()
    XCTAssertEqual(model.phase, .connectedIdle)
    XCTAssertFalse(model.isControlling)
  }

  @MainActor func testHostedKeyboardSurfaceReceivesClickFocusAndNativeKeyEvents() async throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    let host = NSHostingView(rootView: MacKeyboardTrackpadView(model: model).frame(width: 700, height: 760))
    let window = KeyboardTrackpadTestWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    try await Task.sleep(for: .milliseconds(80))
    host.layoutSubtreeIfNeeded()
    func keyboardViews(_ view: NSView) -> [KeyboardInputNSView] {
      (view as? KeyboardInputNSView).map { [$0] } ?? view.subviews.flatMap(keyboardViews)
    }
    let candidates = keyboardViews(host)
    XCTAssertFalse(candidates.isEmpty)
    let geometry = candidates.map { view in
      let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: host.superview)
      return "frame=\(view.frame) bounds=\(view.bounds) hidden=\(view.isHiddenOrHasHiddenAncestor) host=\(host.frame) point=\(point) hit=\(String(describing: host.hitTest(point)))"
    }.joined(separator: "; ")
    let keyboard = try XCTUnwrap(candidates.first { view in
      let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
      return view.bounds.width > 100 && view.bounds.height > 20 && host.hitTest(view.convert(center, to: host.superview)) === view
    }, "The visible keyboard surface must receive hit tests through SwiftUI: " + geometry)
    let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    keyboard.mouseDown(with: click)
    XCTAssertTrue(window.firstResponder === keyboard)
    XCTAssertTrue(model.isControlling)
    try await Task.sleep(for: .milliseconds(80))
    host.layoutSubtreeIfNeeded()
    XCTAssertTrue(window.firstResponder === keyboard, "SwiftUI state updates must preserve native keyboard focus")
    XCTAssertTrue(model.isControlling)
    transport.completeWrites = false
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
      NSApplication.shared.sendEvent(event)
      try await Task.sleep(for: .milliseconds(80))
      host.layoutSubtreeIfNeeded()
      XCTAssertTrue(window.firstResponder === keyboard, "UI changes during a key press must preserve the capturing responder")
      XCTAssertTrue(model.isControlling)
      transport.finishWrite()
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertTrue(model.canSendShortcut)
    XCTAssertEqual(transport.writes, [.keyboard(0, [4]), .keyboard(0, [])])
    transport.completeWrites = true
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
      if type == .keyDown { keyboard.keyDown(with: event) }
      else { keyboard.keyUp(with: event) }
    }
    XCTAssertEqual(Array(transport.writes.suffix(2)), [.keyboard(0, [5]), .keyboard(0, [])])
    let count = transport.writes.count
    model.surfaceLost(.keyboard)
    let releasedCount = transport.writes.count
    XCTAssertGreaterThanOrEqual(releasedCount, count)
    let offline = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
    keyboard.keyDown(with: offline)
    XCTAssertEqual(transport.writes.count, releasedCount)
    window.contentView = nil
  }

  @MainActor func testResponsiveLayoutKeepsCapturingResponderAcrossWidths() async throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    let host = NSHostingView(rootView: ScrollView { MacKeyboardTrackpadView(model: model).padding(24) })
    let window = KeyboardTrackpadTestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    try await Task.sleep(for: .milliseconds(80))
    host.layoutSubtreeIfNeeded()
    func keyboards(_ view: NSView) -> [KeyboardInputNSView] {
      (view as? KeyboardInputNSView).map { [$0] } ?? view.subviews.flatMap(keyboards)
    }
    let keyboard = try XCTUnwrap(keyboards(host).first { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 100 })
    window.makeFirstResponder(keyboard)
    model.requestControl(on: .keyboard)
    for width in [480.0, 800.0] {
      window.setContentSize(NSSize(width: width, height: 800))
      try await Task.sleep(for: .milliseconds(80))
      host.layoutSubtreeIfNeeded()
      XCTAssertTrue(window.firstResponder === keyboard, "Changing columns must retain the input responder")
      XCTAssertTrue(model.isControlling)
      XCTAssertEqual(keyboards(host).count, 1, "Only one keyboard surface may own event capture")
    }
  }

  @MainActor func testFailedWriteAfterCaptureEndsStopsPendingShortcut() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    model.requestControl(on: .keyboard)
    transport.completeWrites = false
    model.keyDown(usage: 4, modifiers: 0)
    model.sendTap(usage: 0x28)
    transport.finishWrite(.failure("Link failed"))
    XCTAssertEqual(model.phase, .failed)
    XCTAssertEqual(model.failureMessage, "Link failed")
    XCTAssertEqual(transport.writes, [.keyboard(0, [4])], "A failed connection must not send the queued shortcut")
    XCTAssertFalse(model.canSendShortcut)
  }

  @MainActor func testCapsLockChangesSendOneTapAndPreserveHeldKeys() throws {
    let peer = try phone("Phone")
    let transport = FakeKeyboardTrackpadTransport()
    transport.devices = [paired(peer)]
    let model = readyModel(peer: peer, transport: transport)
    defer { model.shutdown() }
    model.connect()
    let keyboard = KeyboardInputNSView()
    keyboard.model = model
    let window = KeyboardTrackpadTestWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = keyboard
    defer { window.contentView = nil }
    window.makeFirstResponder(keyboard)
    model.requestControl(on: .keyboard)
    model.keyDown(usage: 4, modifiers: 2)
    transport.writes.removeAll()
    for flags: NSEvent.ModifierFlags in [[.capsLock, .shift], [.capsLock, .shift], [.shift]] {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x39))
      keyboard.flagsChanged(with: event)
    }
    XCTAssertEqual(transport.writes, [.keyboard(2, [4, 0x39]), .keyboard(2, [4]), .keyboard(2, [4, 0x39]), .keyboard(2, [4])])
    model.surfaceLost(.keyboard)
    let stoppedCount = transport.writes.count
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.capsLock], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x39))
    keyboard.flagsChanged(with: event)
    XCTAssertEqual(transport.writes.count, stoppedCount)
  }

  private func phone(_ name: String, id: String = UUID().uuidString.lowercased()) throws -> DeviceIdentity {
    let key = P256.Signing.PrivateKey().publicKey.x963Representation
    let mac = try DeviceIdentity(deviceId: id, deviceName: name, publicKey: key)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(mac)) as? [String: Any])
    object["platform"] = "android"
    return try JSONDecoder().decode(DeviceIdentity.self, from: JSONSerialization.data(withJSONObject: object))
  }

  private func paired(_ peer: DeviceIdentity) -> PairedBluetoothDevice {
    PairedBluetoothDevice(address: "AA:BB:CC:DD:EE:FF", name: peer.deviceName)
  }

  private func testDefaults() -> UserDefaults {
    UserDefaults(suiteName: "KeyboardTrackpadTests.\(UUID().uuidString)")!
  }
}

private extension Result where Success: Collection {
  func getOrNil() -> Success? {
    if case .success(let value) = self { return value }
    return nil
  }
}

@MainActor private final class KeyboardTrackpadTestWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}
