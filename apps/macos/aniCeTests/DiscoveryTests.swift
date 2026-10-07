// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import aniCe

final class DiscoveryTests: XCTestCase, @unchecked Sendable {
    private func hex(_ value: String) -> Data {
        let chars = Array(value)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! })
    }
    func testSharedVectors() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "discovery-vectors", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(root["fixtureVersion"] as? Int, 1)
        for vector in try XCTUnwrap(root["valid"] as? [[String: Any]]) {
            let bytes = hex(try XCTUnwrap(vector["payloadHex"] as? String))
            let payload = try BlePayloadCodec.decode(bytes)
            XCTAssertEqual(Int(payload.flags), vector["flags"] as? Int)
            XCTAssertEqual(payload.nonce, hex(try XCTUnwrap(vector["nonceHex"] as? String)))
            XCTAssertEqual(try BlePayloadCodec.encode(nonce: payload.nonce, flags: payload.flags), bytes)
        }
        for vector in try XCTUnwrap(root["invalid"] as? [[String: Any]]) {
            XCTAssertThrowsError(try BlePayloadCodec.decode(hex(try XCTUnwrap(vector["payloadHex"] as? String))))
        }
        XCTAssertThrowsError(try BlePayloadCodec.encode(nonce: Data(count: 15)))
    }
    @MainActor private final class Fake: PeripheralAdapter {
        var event: (PeripheralEvent) -> Void = { _ in }
        var reader: (Bool, Int) -> DiscoveryRead = { _, _ in .unavailable }
        var publishes = 0; var advertises = 0; var stops = 0
        func begin(event: @escaping (PeripheralEvent) -> Void, read: @escaping (Bool, Int) -> DiscoveryRead) { self.event = event; reader = read }
        func publish() { publishes += 1 }
        func advertise() { advertises += 1 }
        func stop() { stops += 1 }
    }
    @MainActor private final class Rig {
        var time: TimeInterval = 0
        var randomCount: UInt8 = 0
        var randomFails = false
        let fake = Fake()
        lazy var session = PeripheralDiscoverySession(now: { self.time }, random: {
            if self.randomFails { throw BlePayloadCodec.Failure.length }
            self.randomCount += 1
            return Data(repeating: self.randomCount, count: 16)
        }, makeAdapter: { self.fake })
        func advertise() { session.start(); fake.event(.available); fake.event(.published); fake.event(.advertising) }
    }
    @MainActor func testPublicationOrderAndReadOffsets() async {
        let r = Rig(); r.session.start()
        XCTAssertEqual(r.fake.advertises, 0)
        r.fake.event(.available); XCTAssertEqual(r.fake.publishes, 1)
        XCTAssertEqual(r.session.read(matches: true, offset: 0), .unavailable)
        r.fake.event(.published); XCTAssertEqual(r.fake.advertises, 1)
        r.fake.event(.advertising)
        XCTAssertEqual(r.session.read(matches: true, offset: 4), .value(Data(repeating: 1, count: 16)))
        XCTAssertEqual(r.session.read(matches: true, offset: 20), .value(Data()))
        XCTAssertEqual(r.session.read(matches: true, offset: 21), .invalidOffset)
        XCTAssertEqual(r.session.read(matches: false, offset: 0), .unknownCharacteristic)
    }
    @MainActor func testNonceRotationAndFreshStart() async {
        let r = Rig(); r.advertise(); r.time = 30
        XCTAssertEqual(r.session.read(matches: true, offset: 4), .value(Data(repeating: 2, count: 16)))
        r.time = 95; r.session.tick(); XCTAssertEqual(r.randomCount, 3)
        r.session.stop(); XCTAssertEqual(r.session.read(matches: true, offset: 0), .unavailable)
        r.advertise(); XCTAssertEqual(r.randomCount, 4)
    }
    @MainActor func testExpiryStopsBeforeServingRead() async {
        let r = Rig(); r.advertise(); r.time = 120
        XCTAssertEqual(r.session.read(matches: true, offset: 0), .unavailable)
        XCTAssertFalse(r.session.active); XCTAssertEqual(r.session.remainingSeconds, 0)
        XCTAssertEqual(r.fake.stops, 1)
    }
    @MainActor func testWatchdogWaitsForPermissionThenBoundsStartup() async {
        let r = Rig(); r.session.start(); r.fake.event(.permissionPending)
        r.time = 100; r.session.tick(); XCTAssertTrue(r.session.active)
        r.fake.event(.initializing); r.time = 110; r.session.tick()
        XCTAssertEqual(r.session.state, .failed); XCTAssertFalse(r.session.active)
    }
    @MainActor func testAbsentPublicationAndAdvertisingCallbacks() async {
        for published in [false, true] {
            let r = Rig(); r.session.start(); r.fake.event(.available)
            if published { r.fake.event(.published) }
            r.time = 10; r.session.tick(); XCTAssertEqual(r.session.state, .failed)
        }
    }
    @MainActor func testRandomFailureStopsStartAndRotation() async {
        let start = Rig(); start.randomFails = true; start.session.start(); start.fake.event(.available)
        XCTAssertEqual(start.session.state, .failed); XCTAssertEqual(start.fake.publishes, 0)
        let rotate = Rig(); rotate.advertise(); rotate.randomFails = true; rotate.time = 30; rotate.session.tick()
        XCTAssertFalse(rotate.session.active); XCTAssertEqual(rotate.session.state, .failed)
    }
    @MainActor func testFailuresAndRecoveryStates() async {
        for event in [PeripheralEvent.failure, .resetting, .unsupported, .off, .denied] {
            let r = Rig(); r.advertise(); r.fake.event(event)
            XCTAssertFalse(r.session.active)
            XCTAssertEqual(r.session.read(matches: true, offset: 0), .unavailable)
        }
        let r = Rig(); r.session.start(); r.fake.event(.off); XCTAssertEqual(r.session.state, .bluetoothOff)
        r.session.start(); r.fake.event(.denied); XCTAssertEqual(r.session.state, .permissionNeeded)
        XCTAssertEqual(r.session.recovery, .permissionSettings)
        r.session.start(); r.fake.event(.unsupported); XCTAssertEqual(r.session.recovery, .unsupported)
    }
    @MainActor func testStaleCallbacksAndCancelCannotRestartAdvertising() async {
        let r = Rig(); r.session.start(); let oldEvent = r.fake.event; let oldRead = r.fake.reader
        r.session.start(); oldEvent(.available); oldEvent(.advertising)
        XCTAssertEqual(r.fake.publishes, 0); XCTAssertEqual(oldRead(true, 0), .unavailable)
        r.session.stop(); r.fake.event(.available); XCTAssertEqual(r.fake.publishes, 0)
    }
}
