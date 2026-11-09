// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies shared Desk Deck and device-power fixtures against the Mac codecs.
import Foundation
import XCTest
import Darwin
@testable import aniCe

@MainActor
final class DeskDeckWireTests: XCTestCase {
  func testFocusShortcutListParserExtractsOpaqueIdentifiers() {
    let shortcut = MacDeskDeckShortcutRunner.parseList("Toggle Do Not Disturb (00000000-0000-0000-0000-000000000001)\ninvalid entry")
    XCTAssertEqual(shortcut, [MacDeskDeckSystemShortcut(identifier: "00000000-0000-0000-0000-000000000001", name: "Toggle Do Not Disturb")])
  }

  func testSharedDeskDeckFixturesRoundTripAndRejectMalformedRecords() throws {
    let root = try SessionFixtures().root("desk-deck-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(valid.count, 4)
    XCTAssertGreaterThanOrEqual(invalid.count, 2)

    var versions = Set<Int64>()
    for row in valid {
      let bytes = try SessionFixtures().b(row, "bytes")
      let message = try XCTUnwrap(MacDeskDeckMessage.decode(bytes), row["name"] as? String ?? "")
      XCTAssertEqual(try message.encode(), bytes)
      versions.insert(message.version)
    }
    XCTAssertEqual(versions, Set([1, 2, 3, 4, 5]))

    for row in invalid {
      let bytes = try SessionFixtures().b(row, "bytes")
      XCTAssertThrowsError(try MacDeskDeckMessage.decode(bytes), row["name"] as? String ?? "")
    }
  }

  func testMemoryAccountingSeparatesAnonymousAppsFromFileCache() {
    var counters = vm_statistics64()
    counters.active_count = 100
    counters.internal_page_count = 200
    counters.purgeable_count = 20
    counters.external_page_count = 50
    counters.wire_count = 30
    counters.compressor_page_count = 40
    counters.free_count = 10
    let sample = DeskDeckMemory(statistics: counters, total: 400 * 4096, pageSize: 4096, swap: 8192)
    XCTAssertEqual(sample.app, 180 * 4096)
    XCTAssertEqual(sample.used, 320 * 4096)
    XCTAssertEqual(sample.used - sample.app - sample.wired - sample.compressed, 70 * 4096)
    XCTAssertEqual(sample.cached, 70 * 4096)
    XCTAssertEqual(sample.free, 10 * 4096)
    XCTAssertEqual(sample.swap, 8192)
  }

  func testCPUCounterRolloverUsesNativeWidthAndAllCores() {
    XCTAssertEqual(DeskDeckCPU.percentage(previous: [0, 0, 0, 0, 0, 0, 0, 0],
      current: [20, 30, 50, 0, 10, 0, 90, 0]), 30)
    XCTAssertEqual(DeskDeckCPU.percentage(previous: [UInt32.max - 10, 0, 0, 0], current: [9, 0, 10, 0]), 67)
    XCTAssertEqual(DeskDeckCPU.percentage(previous: [1, 2, 3, 4], current: [1, 2, 3, 4]), -1)
    XCTAssertEqual(DeskDeckCPU.percentage(previous: [], current: [1, 2, 3, 4]), -1)
  }

  func testSharedDevicePowerFixturesPreserveUnknownPercentage() throws {
    let root = try SessionFixtures().root("device-power-vectors")
    let valid = try XCTUnwrap(root["valid"] as? [[String: Any]])
    let invalid = try XCTUnwrap(root["invalid"] as? [[String: Any]])
    for row in valid {
      let bytes = try SessionFixtures().b(row, "bytes")
      let message = try XCTUnwrap(MacDevicePowerMessage.decode(bytes), row["name"] as? String ?? "")
      XCTAssertEqual(try message.encode(), bytes)
      if row["name"] as? String == "battery-percent-unknown" { XCTAssertEqual(message.percent, -1) }
      XCTAssertNil(try MacDeskDeckMessage.decode(bytes))
    }
    for row in invalid {
      XCTAssertThrowsError(try MacDevicePowerMessage.decode(SessionFixtures().b(row, "bytes")), row["name"] as? String ?? "")
    }
    let capability = try MacDevicePowerMessage(kind: 1, state: 0, percent: -1, source: 0).encode()
    XCTAssertEqual(try MacDevicePowerMessage.decode(capability)?.kind, 1)
    for source in Int64(1)...5 {
      let report = try MacDevicePowerMessage(kind: 2, state: 3, percent: 80, source: source).encode()
      XCTAssertEqual(try MacDevicePowerMessage.decode(report)?.source, source)
    }
    XCTAssertThrowsError(try MacDevicePowerMessage(kind: 2, state: 3, percent: 80, source: 6).encode())
  }

  func testRevokedShortcutCannotLaunchFromAnEarlierCatalog() async throws {
    let channel = MockSecuredChannel(instance: "desk-deck-revocation", transport: "lan")
    let peer = channel.descriptor.peer
    let defaultsKey = "desk-deck.apps.\(peer.fingerprint)"
    let model = MacDeskDeckModel()
    let appURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("DeskDeckApproval-\(UUID().uuidString).app", isDirectory: true)
    defer {
      model.shutdown()
      UserDefaults.standard.removeObject(forKey: defaultsKey)
      try? FileManager.default.removeItem(at: appURL)
    }

    let executableName = "deskdeck-test-app"
    let executableURL = appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
    let identifier = "io.github.anisharyal09.anice.test.\(UUID().uuidString.lowercased())"
    try FileManager.default.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    let info: [String: Any] = [
      "CFBundleExecutable": executableName,
      "CFBundleIdentifier": identifier,
      "CFBundleName": "Desk Deck Test App",
      "CFBundlePackageType": "APPL",
    ]
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try FileManager.default.createDirectory(at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try plist.write(to: appURL.appendingPathComponent("Contents/Info.plist"))

    XCTAssertTrue(model.addApprovedApp(at: appURL, for: peer))
    let approved = try XCTUnwrap(model.approvedApps(for: peer).first { $0.bundleIdentifier == identifier })
    model.available(channel)
    let subscription = UUID().uuidString.lowercased()
    let descriptor = channel.descriptor
    let subscribe = MacDeskDeckMessage(version: 2, kind: 2, fields: [.text(subscription)])
    let subscribeHandling = await model.handle(try subscribe.encode(), on: descriptor)
    if case .handled = subscribeHandling {} else { XCTFail("Subscription was not accepted") }

    let requestPage = MacDeskDeckMessage(version: 2, kind: 8, fields: [.text(subscription), .integer(0)])
    let pageHandling = await model.handle(try requestPage.encode(), on: descriptor)
    if case .handled = pageHandling {} else { XCTFail("Catalog request was not accepted") }
    var oldCatalogPage: MacDeskDeckMessage?
    for _ in 0..<100 where oldCatalogPage == nil {
      await Task.yield()
      oldCatalogPage = try channel.sentData.compactMap(MacDeskDeckMessage.decode)
        .last { $0.kind == 9 && $0.string(0) == subscription }
    }
    let catalogRevision = try XCTUnwrap(oldCatalogPage?.string(3))
    let pageContainsApproval = oldCatalogPage.map { page in
      guard page.fields.indices.contains(4), case .array(let entries) = page.fields[4] else { return false }
      return entries.contains { entry in
        guard case .array(let pair) = entry, pair.count == 2, case .text(let id) = pair[0] else { return false }
        return id == approved.id
      }
    } ?? false
    XCTAssertTrue(pageContainsApproval)

    model.removeApprovedApp(id: approved.id, for: peer)
    var invalidation: MacDeskDeckMessage?
    for _ in 0..<100 where invalidation == nil {
      await Task.yield()
      invalidation = try channel.sentData.compactMap(MacDeskDeckMessage.decode)
        .last { $0.kind == 10 && $0.string(0) == subscription }
    }
    XCTAssertNotNil(invalidation, "A live approved-app catalog edit must invalidate the phone's cached pages")
    XCTAssertNotEqual(invalidation?.string(1), catalogRevision)
    let launch = MacDeskDeckMessage(version: 2, kind: 4, fields: [
      .text(subscription), .integer(1), .integer(8), .text(approved.id), .text(catalogRevision), .integer(-1),
    ])
    let launchHandling = await model.handle(try launch.encode(), on: descriptor)
    if case .handled = launchHandling {} else { XCTFail("Shortcut command was not accepted") }
    var result: MacDeskDeckMessage?
    for _ in 0..<100 where result == nil {
      await Task.yield()
      result = try channel.sentData.compactMap(MacDeskDeckMessage.decode)
        .last { $0.kind == 5 && $0.string(0) == subscription }
    }
    XCTAssertEqual(result?.number(2), 1, "A revoked or stale catalog entry must not launch")
  }

  func testBackpressureKeepsOnlyLatestSampleAndRetiringStopsTheTicker() async throws {
    let channel = MockSecuredChannel(instance: "desk-deck-backpressure", transport: "lan")
    let model = MacDeskDeckModel()
    var delayFirstSample = true
    channel.onSendData = { bytes in
      guard delayFirstSample else { return }
      let decoded: MacDeskDeckMessage?
      do { decoded = try MacDeskDeckMessage.decode(bytes) } catch { return }
      guard decoded?.kind == 3 else { return }
      delayFirstSample = false
      try await Task.sleep(for: .seconds(2.2))
    }
    defer { model.shutdown() }
    model.available(channel)
    let subscription = UUID().uuidString.lowercased()
    let descriptor = channel.descriptor
    let subscribe = MacDeskDeckMessage(version: 2, kind: 2, fields: [.text(subscription)])
    let handling = await model.handle(try subscribe.encode(), on: descriptor)
    if case .handled = handling {} else { XCTFail("Subscription was not accepted") }

    try await Task.sleep(for: .seconds(2.6))
    let samples = try channel.sentData.compactMap(MacDeskDeckMessage.decode).filter { $0.kind == 3 }
    XCTAssertEqual(samples.count, 2, "One in-flight sample and the latest queued sample should be sent")
    func sequence(_ sample: MacDeskDeckMessage) -> Int64 {
      guard sample.fields.indices.contains(1), case .integer(let value) = sample.fields[1] else { return -1 }
      return value
    }
    XCTAssertGreaterThan(samples.last.map(sequence) ?? 0, (samples.first.map(sequence) ?? 0) + 1,
      "Intermediate samples should be coalesced while transport submission is blocked")

    model.retired(descriptor)
    try await Task.sleep(for: .seconds(1.2))
    let afterRetirement = try channel.sentData.compactMap(MacDeskDeckMessage.decode).filter { $0.kind == 3 }
    XCTAssertEqual(afterRetirement.count, samples.count, "A retired channel must not be sampled again")
  }

  func testDeskDeckLeaseExpiryStopsSampling() async throws {
    let channel = MockSecuredChannel(instance: "desk-deck-lease", transport: "lan")
    let model = MacDeskDeckModel()
    defer { model.shutdown() }
    model.available(channel)
    let subscription = UUID().uuidString.lowercased()
    let descriptor = channel.descriptor
    let subscribe = MacDeskDeckMessage(version: 2, kind: 2, fields: [.text(subscription)])
    let handling = await model.handle(try subscribe.encode(), on: descriptor)
    if case .handled = handling {} else { XCTFail("Subscription was not accepted") }

    try await Task.sleep(for: .seconds(16.5))
    await Task.yield()
    let afterExpiry = try channel.sentData.compactMap(MacDeskDeckMessage.decode).filter { $0.kind == 3 }.count
    XCTAssertGreaterThan(afterExpiry, 1)
    try await Task.sleep(for: .seconds(1.2))
    let afterQuietPeriod = try channel.sentData.compactMap(MacDeskDeckMessage.decode).filter { $0.kind == 3 }.count
    XCTAssertEqual(afterQuietPeriod, afterExpiry, "Expired subscriptions must stop the sampling ticker")
  }
}
