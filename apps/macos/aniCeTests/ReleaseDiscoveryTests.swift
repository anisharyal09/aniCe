// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies conditional release checks, saved notices and the Atom fallback.
import Foundation
import AppKit
import UserNotifications
import XCTest
@testable import aniCe

private actor FakeReleaseTransport: MacReleaseTransport {
  var responses: [MacReleaseResponse]
  var calls: [(String, String, String?)] = []
  private var beforeResponse: (@MainActor @Sendable () -> Void)?
  init(_ responses: [MacReleaseResponse]) { self.responses = responses }
  func request(_ url: URL, method: String, etag: String?) async throws -> MacReleaseResponse {
    calls.append((url.absoluteString, method, etag))
    guard !responses.isEmpty else { throw URLError(.badServerResponse) }
    let response = responses.removeFirst()
    if let action = beforeResponse {
      beforeResponse = nil
      await action()
    }
    return response
  }
  func beforeNextResponse(_ action: @escaping @MainActor @Sendable () -> Void) { beforeResponse = action }
  func recorded() -> [(String, String, String?)] { calls }
}

private actor SuspendedReleaseTransport: MacReleaseTransport {
  private var pending: CheckedContinuation<MacReleaseResponse, Never>?
  private var ready: CheckedContinuation<Bool, Never>?
  private var deadline: Task<Void, Never>?
  private var held = false
  private var calls = 0
  func request(_ url: URL, method: String, etag: String?) async throws -> MacReleaseResponse {
    calls += 1
    guard !held else { throw URLError(.badServerResponse) }
    held = true
    return await withCheckedContinuation {
      pending = $0
      ready?.resume(returning: true); ready = nil
      deadline?.cancel(); deadline = nil
    }
  }
  func waitForRequest() async -> Bool {
    if pending != nil { return true }
    return await withCheckedContinuation {
      ready = $0
      deadline = Task {
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        ready?.resume(returning: false); ready = nil; deadline = nil
      }
    }
  }
  func finish(_ response: MacReleaseResponse) {
    pending?.resume(returning: response)
    pending = nil
  }
  func recordedCount() -> Int { calls }
}

final class ReleaseDiscoveryTests: XCTestCase {
  private func response(_ status: Int, _ body: String = "", etag: String? = nil) -> MacReleaseResponse {
    MacReleaseResponse(status: status, data: Data(body.utf8), etag: etag)
  }
  @MainActor func testAutomaticChecksDefaultOnAndSavedOptOutBlocksRequestsButNotManualChecks() async throws {
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = FakeReleaseTransport([releaseResponse("v0.4.0"), response(304)])
    let discovery = MacReleaseDiscovery(defaults: defaults, transport: transport)
    XCTAssertTrue(discovery.automaticChecks)
    discovery.automaticChecks = false
    let restored = MacReleaseDiscovery(defaults: defaults, transport: transport)
    XCTAssertFalse(restored.automaticChecks)
    let current = try XCTUnwrap(UpdateVersion.parse("v0.3.0"))
    let now = Date(timeIntervalSince1970: 100)
    let disabled = await restored.check(current: current, now: now)
    XCTAssertEqual(disabled, .deferred)
    let before = await transport.recorded()
    XCTAssertTrue(before.isEmpty)
    XCTAssertNil(defaults.object(forKey: "updates.lastAttempt"))
    XCTAssertNil(defaults.object(forKey: "updates.lastSuccess"))
    guard case .available = await restored.check(current: current, force: true, now: now) else { return XCTFail("Manual check was blocked") }
    restored.automaticChecks = true
    XCTAssertTrue(MacReleaseDiscovery(defaults: defaults).automaticChecks)
    guard case .available = await restored.check(current: current, now: now.addingTimeInterval(UpdateSchedule.day)) else {
      return XCTFail("Automatic checks did not resume")
    }
    let calls = await transport.recorded()
    XCTAssertEqual(calls.count, 2)
  }

  @MainActor func testAutomaticOptOutKeepsCachedReviewSkipAndNotificationFloors() async throws {
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let discovery = MacReleaseDiscovery(defaults: defaults, transport: FakeReleaseTransport([releaseResponse("v0.4.0")]))
    let current = try XCTUnwrap(UpdateVersion.parse("v0.3.0")), now = Date(timeIntervalSince1970: 100)
    guard case .available(let release) = await discovery.check(current: current, force: true, now: now) else { return XCTFail("Missing release") }
    discovery.markNotified(release)
    discovery.skip("v0.5.0")
    discovery.includeBeta = true
    discovery.automaticChecks = false
    XCTAssertEqual(try discovery.cachedNotice(current: current), release)
    let version = try XCTUnwrap(UpdateVersion.parse("v0.4.1"))
    let newer = AvailableMacRelease(version: version, notes: "Notes", assetURL: MacReleaseCatalog.assetURL(version), assetBytes: 50)
    XCTAssertFalse(discovery.shouldNotify(newer))
    discovery.automaticChecks = true
    let restored = MacReleaseDiscovery(defaults: defaults)
    XCTAssertTrue(restored.includeBeta)
    XCTAssertFalse(restored.shouldNotify(release))
    XCTAssertTrue(restored.shouldNotify(newer))
    XCTAssertEqual(defaults.string(forKey: "updates.skippedTag"), "v0.5.0")
    XCTAssertEqual(defaults.double(forKey: "updates.lastSuccess"), now.timeIntervalSince1970)
  }

  @MainActor func testModelOptOutPersistsAndBetaChangesDoNotStartChecksWhileDisabled() async throws {
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = FakeReleaseTransport([response(200, "[]")])
    let model = MacUpdateModel(discovery: MacReleaseDiscovery(defaults: defaults, transport: transport))
    XCTAssertTrue(model.automaticChecks)
    model.automaticChecks = false
    model.includeBeta = true
    await model.check()
    model.startAutomaticChecks()
    model.stopAutomaticChecks()
    let before = await transport.recorded()
    XCTAssertTrue(before.isEmpty)
    XCTAssertFalse(MacUpdateModel(discovery: MacReleaseDiscovery(defaults: defaults)).automaticChecks)
    await model.check(force: true)
    XCTAssertEqual(model.status, "You’re up to date.")
    XCTAssertFalse(model.automaticChecks)
    let calls = await transport.recorded()
    XCTAssertEqual(calls.count, 1)
    model.automaticChecks = true
    XCTAssertTrue(MacUpdateModel(discovery: MacReleaseDiscovery(defaults: defaults)).automaticChecks)
  }

  @MainActor func testDisablingAutomaticChecksCancelsMetadataWithoutCompletingTheEvening() async throws {
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = SuspendedReleaseTransport()
    let model = MacUpdateModel(discovery: MacReleaseDiscovery(defaults: defaults, transport: transport))
    let check = Task { await model.check() }
    let started = await transport.waitForRequest()
    XCTAssertTrue(started)
    guard started else { check.cancel(); return }
    model.automaticChecks = false
    await transport.finish(releaseResponse("v99.0.0"))
    await check.value
    XCTAssertFalse(model.checking)
    XCTAssertNil(model.release)
    XCTAssertNil(defaults.object(forKey: "updates.cachedReleases"))
    XCTAssertNil(defaults.object(forKey: "updates.lastSuccess"))
    XCTAssertNil(defaults.object(forKey: "updates.failures"))
  }

  @MainActor func testDisablingAutomaticChecksDoesNotCancelAManualCheck() async throws {
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = SuspendedReleaseTransport()
    let model = MacUpdateModel(discovery: MacReleaseDiscovery(defaults: defaults, transport: transport))
    let check = Task { await model.check(force: true) }
    let started = await transport.waitForRequest()
    XCTAssertTrue(started)
    guard started else { check.cancel(); return }
    model.automaticChecks = false
    await transport.finish(response(200, "[]"))
    await check.value
    XCTAssertFalse(model.checking)
    XCTAssertEqual(model.status, "You’re up to date.")
    XCTAssertNotNil(defaults.object(forKey: "updates.lastSuccess"))
    XCTAssertFalse(model.automaticChecks)
  }

  @MainActor func testOptOutDoesNotRunAQueuedBetaRefresh() async throws {
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = SuspendedReleaseTransport()
    let model = MacUpdateModel(discovery: MacReleaseDiscovery(defaults: defaults, transport: transport))
    let check = Task { await model.check() }
    let started = await transport.waitForRequest()
    XCTAssertTrue(started)
    guard started else { check.cancel(); return }
    model.includeBeta = true
    await Task.yield()
    model.automaticChecks = false
    await transport.finish(response(200, "[]"))
    await check.value
    await Task.yield()
    XCTAssertFalse(model.automaticChecks)
    XCTAssertNil(defaults.object(forKey: "updates.lastSuccess"))
    let calls = await transport.recordedCount()
    XCTAssertEqual(calls, 1)
  }

  @MainActor func testNativeMonitoringAndDeadlineStopAndRestartWithSavedPreference() async throws {
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = FakeReleaseTransport([])
    let model = MacUpdateModel(discovery: MacReleaseDiscovery(defaults: defaults, transport: transport),
      automaticLifecycleEnabled: true)
    defer { model.stopAutomaticChecks() }
    defaults.set(Date().timeIntervalSince1970, forKey: "updates.lastSuccess")
    model.automaticChecks = false
    model.startAutomaticChecks()
    XCTAssertFalse(model.automaticMonitoringActive)
    XCTAssertNil(model.scheduledAutomaticCheck)
    model.automaticChecks = true
    model.startAutomaticChecks()
    XCTAssertTrue(model.automaticMonitoringActive)
    let deadline = try XCTUnwrap(model.scheduledAutomaticCheck)
    XCTAssertGreaterThan(deadline, Date())
    model.automaticChecks = false
    XCTAssertFalse(model.automaticMonitoringActive)
    XCTAssertNil(model.scheduledAutomaticCheck)
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.post(name: NSNotification.Name.NSSystemClockDidChange, object: nil)
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    await Task.yield()
    let calls = await transport.recorded()
    XCTAssertTrue(calls.isEmpty, "Disabled native catch-up events must not contact GitHub")
    let restarted = MacUpdateModel(discovery: MacReleaseDiscovery(defaults: defaults, transport: transport),
      automaticLifecycleEnabled: true)
    restarted.startAutomaticChecks()
    XCTAssertFalse(restarted.automaticMonitoringActive)
    XCTAssertNil(restarted.scheduledAutomaticCheck)
    restarted.stopAutomaticChecks()
    model.automaticChecks = true
    XCTAssertTrue(model.automaticMonitoringActive)
    XCTAssertEqual(model.scheduledAutomaticCheck, deadline)
    model.stopAutomaticChecks()
    XCTAssertFalse(model.automaticMonitoringActive)
    XCTAssertNil(model.scheduledAutomaticCheck)
  }

  @MainActor func testQueuedManualCheckStillRunsAfterAutomaticOptOut() async throws {
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = FakeReleaseTransport([response(200, "[]"), response(200, "[]")])
    let model = MacUpdateModel(discovery: MacReleaseDiscovery(defaults: defaults, transport: transport))
    await transport.beforeNextResponse {
      model.automaticChecks = false
    }
    let automatic = Task { await model.check() }
    // check() publishes ownership synchronously before it awaits the metadata task.
    while !model.checking { await Task.yield() }
    await model.check(force: true)
    await automatic.value
    let completed = expectation(description: "Queued manual refresh completes after opt-out")
    let waiter = Task { @MainActor in
      while model.status != "You’re up to date." {
        guard !Task.isCancelled else { return }
        await Task.yield()
      }
      completed.fulfill()
    }
    defer { waiter.cancel() }
    await fulfillment(of: [completed], timeout: 5)
    XCTAssertEqual(model.status, "You’re up to date.")
    XCTAssertFalse(model.automaticChecks)
    let calls = await transport.recorded()
    XCTAssertEqual(calls.count, 2)
  }

  @MainActor func testETagAndThrottledCachedNotice() async throws {
    let tag = "v0.4.0", url = "\(MacReleaseCatalog.root)/download/v0.4.0/aniCe-mac.zip"
    let body = """
    [{"tag_name":"\(tag)","draft":false,"prerelease":false,"body":"Notes","assets":[{"name":"aniCe-mac.zip","state":"uploaded","size":50,"browser_download_url":"\(url)"}]}]
    """
    let transport = FakeReleaseTransport([response(200, body, etag: "tag1"), response(304)])
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let discovery = MacReleaseDiscovery(defaults: defaults, transport: transport), current = try XCTUnwrap(UpdateVersion.parse("v0.3.0"))
    guard case .available(let first) = await discovery.check(current: current, force: true, now: Date(timeIntervalSince1970: 100)) else { return XCTFail("Missing release") }
    XCTAssertEqual(first.version.tag, tag)
    guard case .available = await discovery.check(current: current, now: Date(timeIntervalSince1970: 101)) else { return XCTFail("Cached notice missing") }
    guard case .available = await discovery.check(current: current, force: true, now: Date(timeIntervalSince1970: 102)) else { return XCTFail("304 cache missing") }
    let calls = await transport.recorded()
    XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls.last?.2, "tag1")
    discovery.skip(tag)
    let skipped = await discovery.check(current: current, now: Date(timeIntervalSince1970: 103))
    XCTAssertEqual(skipped, .deferred)
  }
  @MainActor func testAtomChecksAssetBeforeOfferingRelease() async throws {
    let feed = """
    <feed xmlns="http://www.w3.org/2005/Atom"><entry><link href="\(MacReleaseCatalog.root)/tag/v0.4.0-beta.1"/><link href="\(MacReleaseCatalog.root)/tag/v0.3.1"/></entry></feed>
    """
    let transport = FakeReleaseTransport([response(403), response(200, feed), response(200)])
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let discovery = MacReleaseDiscovery(defaults: defaults, transport: transport), current = try XCTUnwrap(UpdateVersion.parse("v0.3.0"))
    guard case .available(let release) = await discovery.check(current: current, force: true) else { return XCTFail("Missing fallback release") }
    XCTAssertEqual(release.version.tag, "v0.3.1")
    let calls = await transport.recorded()
    XCTAssertEqual(calls.last?.1, "HEAD")
    XCTAssertEqual(calls.last?.0, "\(MacReleaseCatalog.root)/download/v0.3.1/aniCe-mac.zip")
  }

  private func date(_ text: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: text)) }

  private func releaseResponse(_ tag: String) -> MacReleaseResponse {
    response(200, """
    [{"tag_name":"\(tag)","draft":false,"prerelease":false,"body":"Notes for \(tag)","assets":[{"name":"aniCe-mac.zip","state":"uploaded","size":50,"browser_download_url":"\(MacReleaseCatalog.root)/download/\(tag)/aniCe-mac.zip"}]}]
    """, etag: tag)
  }

  @MainActor func testCancelledMetadataDoesNotSaveSuccessAndRemainsDueAfterRestart() async throws {
    let evening = try date("2026-11-15T13:45:00Z"), later = evening.addingTimeInterval(60)
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = SuspendedReleaseTransport()
    let discovery = MacReleaseDiscovery(defaults: defaults, transport: transport)
    let current = try XCTUnwrap(UpdateVersion.parse("v0.3.0"))
    let check = Task { await discovery.check(current: current, now: evening) }
    let started = await transport.waitForRequest()
    XCTAssertTrue(started, "Metadata request did not start")
    guard started else { check.cancel(); return }
    check.cancel()
    await transport.finish(releaseResponse("v0.4.0"))
    let result = await check.value
    XCTAssertEqual(result, .deferred)
    XCTAssertNil(defaults.object(forKey: "updates.cachedReleases"))
    XCTAssertNil(defaults.object(forKey: "updates.etag"))
    XCTAssertNil(defaults.object(forKey: "updates.lastSuccess"))
    XCTAssertEqual(discovery.nextAutomaticCheck(now: later), later)
    XCTAssertEqual(MacReleaseDiscovery(defaults: defaults).nextAutomaticCheck(now: later), later)
  }

  @MainActor func testAnAttemptWithoutSuccessCannotCompleteTheEvening() throws {
    let evening = try date("2026-11-15T13:45:00Z"), later = evening.addingTimeInterval(60)
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(evening.timeIntervalSince1970, forKey: "updates.lastAttempt")
    XCTAssertEqual(MacReleaseDiscovery(defaults: defaults).nextAutomaticCheck(now: later), later)
  }

  @MainActor func testMorningSuccessDoesNotSuppressTheFixedNepalEveningRefresh() async throws {
    let morning = try date("2026-11-14T07:00:00Z"), evening = try date("2026-11-14T13:45:00Z")
    XCTAssertEqual(UpdateSchedule.latestEvening(evening.addingTimeInterval(-1)), evening.addingTimeInterval(-UpdateSchedule.day))
    XCTAssertEqual(UpdateSchedule.latestEvening(evening), evening)
    let body = """
    [{"tag_name":"v0.4.0","draft":false,"prerelease":false,"body":"Notes","assets":[{"name":"aniCe-mac.zip","state":"uploaded","size":50,"browser_download_url":"\(MacReleaseCatalog.root)/download/v0.4.0/aniCe-mac.zip"}]}]
    """
    let transport = FakeReleaseTransport([response(200, body, etag: "tag1"), response(304)])
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let discovery = MacReleaseDiscovery(defaults: defaults, transport: transport)
    let current = try XCTUnwrap(UpdateVersion.parse("v0.3.0"))
    guard case .available = await discovery.check(current: current, force: true, now: morning) else { return XCTFail("Missing release") }
    XCTAssertEqual(discovery.nextAutomaticCheck(now: morning.addingTimeInterval(1)), evening)
    guard case .available = await discovery.check(current: current, now: evening.addingTimeInterval(-1)) else { return XCTFail("Missing cache") }
    let before = await transport.recorded()
    XCTAssertEqual(before.count, 1)
    guard case .available = await discovery.check(current: current, now: evening) else { return XCTFail("Missing conditional release") }
    let calls = await transport.recorded()
    XCTAssertEqual(calls.count, 2)
    XCTAssertEqual(calls.last?.2, "tag1")
    XCTAssertEqual(defaults.double(forKey: "updates.lastSuccess"), evening.timeIntervalSince1970)
    XCTAssertEqual(discovery.nextAutomaticCheck(now: evening.addingTimeInterval(1)), evening.addingTimeInterval(UpdateSchedule.day))
  }

  @MainActor func testFailedEveningRemainsDueAndCanSucceedLater() async throws {
    let evening = try date("2026-11-14T13:45:00Z")
    let body = """
    [{"tag_name":"v0.4.0","draft":false,"prerelease":false,"body":"Notes","assets":[{"name":"aniCe-mac.zip","state":"uploaded","size":50,"browser_download_url":"\(MacReleaseCatalog.root)/download/v0.4.0/aniCe-mac.zip"}]}]
    """
    let transport = FakeReleaseTransport([response(500), response(200, body)])
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let discovery = MacReleaseDiscovery(defaults: defaults, transport: transport)
    let current = try XCTUnwrap(UpdateVersion.parse("v0.3.0"))
    guard case .failed = await discovery.check(current: current, now: evening) else { return XCTFail("Failure not reported") }
    XCTAssertNil(defaults.object(forKey: "updates.lastSuccess"))
    XCTAssertEqual(discovery.nextAutomaticCheck(now: evening.addingTimeInterval(1)), evening.addingTimeInterval(900))
    let deferred = await discovery.check(current: current, now: evening.addingTimeInterval(899))
    XCTAssertEqual(deferred, .deferred)
    let before = await transport.recorded()
    XCTAssertEqual(before.count, 1)
    let later = evening.addingTimeInterval(3600)
    guard case .available = await discovery.check(current: current, now: later) else { return XCTFail("Overdue refresh did not catch up") }
    XCTAssertEqual(defaults.double(forKey: "updates.lastSuccess"), later.timeIntervalSince1970)
    XCTAssertEqual(discovery.nextAutomaticCheck(now: later), evening.addingTimeInterval(UpdateSchedule.day))
  }

  @MainActor func testCompletedEmptyCacheRemainsUpToDateWithoutAnotherRequest() async throws {
    let evening = try date("2026-11-15T13:45:00Z")
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let transport = FakeReleaseTransport([response(200, "[]", etag: "empty"), response(500)])
    let discovery = MacReleaseDiscovery(defaults: defaults, transport: transport)
    let current = try XCTUnwrap(UpdateVersion.parse("v0.3.0"))
    let first = await discovery.check(current: current, now: evening)
    XCTAssertEqual(first, .upToDate)
    let cached = await discovery.check(current: current, now: evening.addingTimeInterval(1))
    XCTAssertEqual(cached, .upToDate)
    let calls = await transport.recorded()
    XCTAssertEqual(calls.count, 1)
    _ = await discovery.check(current: current, force: true, now: evening.addingTimeInterval(2))
    let failed = await discovery.check(current: current, now: evening.addingTimeInterval(3))
    XCTAssertEqual(failed, .deferred, "A failed refresh must not claim fresh up-to-date metadata")
  }

  @MainActor func testMissingAndInvalidCachesCannotClaimUpToDate() async throws {
    let evening = try date("2026-11-15T13:45:00Z")
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(evening.timeIntervalSince1970, forKey: "updates.lastSuccess")
    defaults.set(evening.timeIntervalSince1970, forKey: "updates.lastAttempt")
    defaults.set("api", forKey: "updates.lastSource")
    let discovery = MacReleaseDiscovery(defaults: defaults, transport: FakeReleaseTransport([]))
    let current = try XCTUnwrap(UpdateVersion.parse("v0.3.0"))
    let missing = await discovery.check(current: current, now: evening.addingTimeInterval(1))
    XCTAssertEqual(missing, .deferred)
    defaults.set(Data("invalid".utf8), forKey: "updates.cachedReleases")
    let invalid = await discovery.check(current: current, now: evening.addingTimeInterval(2))
    XCTAssertEqual(invalid, .deferred)
  }

  func testOverdueAndClockRollbackChecksDoNotWaitForAnotherEvening() throws {
    let now = try date("2026-11-14T17:00:00Z"), evening = try date("2026-11-14T13:45:00Z")
    XCTAssertEqual(UpdateSchedule.nextCheck(now: now, lastSuccess: evening.timeIntervalSince1970 - 1, lastAttempt: 0, failures: 0), now)
    let future = now.addingTimeInterval(UpdateSchedule.day).timeIntervalSince1970
    XCTAssertEqual(UpdateSchedule.nextCheck(now: now, lastSuccess: future, lastAttempt: future, failures: 1), now)
    let delays = (1...7).map(UpdateSchedule.retryDelay)
    XCTAssertEqual(delays.count, 7)
    XCTAssertTrue(zip(delays, delays.dropFirst()).allSatisfy { $0.0 < $0.1 })
    XCTAssertEqual(UpdateSchedule.retryDelay(100), delays.last)
    XCTAssertEqual(UpdateSchedule.retryDelay(-1), 0)
  }

  func testOverdueChecksPreserveTheExactFractionalDate() throws {
    let base = try date("2026-11-15T17:00:00Z").timeIntervalSinceReferenceDate
    let offsets = (0..<128).map { Double($0) * base.ulp }
    XCTAssertEqual(offsets.count, 128)
    for offset in offsets {
      let now = Date(timeIntervalSinceReferenceDate: base + offset)
      XCTAssertEqual(UpdateSchedule.nextCheck(now: now, lastSuccess: 0, lastAttempt: 0, failures: 0), now)
    }
  }

  @MainActor func testNotificationDeduplicationSurvivesBetaTogglesAndOwnerRestart() throws {
    func release(_ tag: String) throws -> AvailableMacRelease {
      let version = try XCTUnwrap(UpdateVersion.parse(tag))
      return AvailableMacRelease(version: version, notes: "Notes", assetURL: MacReleaseCatalog.assetURL(version), assetBytes: 50)
    }
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let discovery = MacReleaseDiscovery(defaults: defaults)
    let stable = try release("v0.3.1"), beta = try release("v0.4.0-beta.2")
    XCTAssertTrue(discovery.shouldNotify(stable))
    XCTAssertFalse(discovery.shouldNotify(beta))
    discovery.markNotified(stable)
    XCTAssertFalse(discovery.shouldNotify(stable))
    discovery.includeBeta = true
    XCTAssertTrue(discovery.shouldNotify(beta))
    discovery.markNotified(beta)
    discovery.includeBeta = false
    XCTAssertTrue(discovery.shouldNotify(try release("v0.3.2")))
    XCTAssertFalse(discovery.shouldNotify(beta))
    discovery.includeBeta = true
    XCTAssertFalse(discovery.shouldNotify(beta))
    let restored = MacReleaseDiscovery(defaults: defaults)
    XCTAssertFalse(restored.shouldNotify(beta))
    XCTAssertFalse(restored.shouldNotify(stable))
    discovery.markNotified(try release("v0.4.0"))
    XCTAssertFalse(discovery.shouldNotify(try release("v0.3.2")))
    discovery.skip("v0.5.0")
    XCTAssertFalse(discovery.shouldNotify(try release("v0.5.0")))
  }

  @MainActor func testReviewKeepsAutomaticSelectionStableAndRejectsStaleActions() async throws {
    let installed = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    let major = try XCTUnwrap(installed.split(separator: ".").first.flatMap { Int($0) })
    let tag = "v\(major + 1).0.0"
    let body = """
    [{"tag_name":"\(tag)","draft":false,"prerelease":false,"body":"Notes","assets":[{"name":"aniCe-mac.zip","state":"uploaded","size":50,"browser_download_url":"\(MacReleaseCatalog.root)/download/\(tag)/aniCe-mac.zip"}]}]
    """
    let transport = FakeReleaseTransport([response(200, body, etag: "tag1")])
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = MacUpdateModel(discovery: MacReleaseDiscovery(defaults: defaults, transport: transport))
    await model.check(force: true)
    let release = try XCTUnwrap(model.release)
    XCTAssertEqual(release.version.tag, tag)
    model.review()
    await model.check()
    let calls = await transport.recorded()
    XCTAssertEqual(calls.count, 1)
    let stale = try XCTUnwrap(UpdateVersion.parse("v0.8.0"))
    model.install(stale)
    XCTAssertFalse(model.installing)
    model.skip(stale)
    XCTAssertEqual(model.release, release)
    XCTAssertTrue(model.reviewing)
    let restarted = MacUpdateModel(discovery: MacReleaseDiscovery(defaults: defaults, transport: transport))
    restarted.review()
    XCTAssertEqual(restarted.release, release)
    XCTAssertTrue(restarted.reviewing)
    await restarted.check()
    let restoredCalls = await transport.recorded()
    XCTAssertEqual(restoredCalls.count, 1)
    model.skip(release.version)
    XCTAssertNil(model.release)
    XCTAssertFalse(model.reviewing)
  }

  @MainActor func testAutomaticCheckDoesNotReplaceAReviewOpenedDuringTheRequest() async throws {
    let installed = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    let major = try XCTUnwrap(installed.split(separator: ".").first.flatMap { Int($0) }) + 1
    let newer = releaseResponse("v\(major).1.0")
    let replies = [newer, response(200, "[]"), response(500)]
    XCTAssertEqual(replies.count, 3)
    for reply in replies {
      let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
      defer { defaults.removePersistentDomain(forName: name) }
      let transport = FakeReleaseTransport([releaseResponse("v\(major).0.0"), reply])
      let discovery = MacReleaseDiscovery(defaults: defaults, transport: transport)
      let model = MacUpdateModel(discovery: discovery)
      await model.check(force: true)
      let reviewed = try XCTUnwrap(model.release)
      defaults.set(0, forKey: "updates.lastSuccess")
      defaults.set(0, forKey: "updates.lastAttempt")
      await transport.beforeNextResponse {
        XCTAssertTrue(model.checking)
        XCTAssertFalse(model.reviewing)
        model.review()
      }
      await model.check()
      XCTAssertEqual(model.release, reviewed)
      XCTAssertTrue(model.reviewing)
      if reply.status == 500 { XCTAssertTrue(model.status.contains("500")) }
      model.reviewing = false
      await model.check()
      let expected = reply.status == 500 ? reviewed.version.tag : reply.data == newer.data ? "v\(major).1.0" : nil
      XCTAssertEqual(model.release?.version.tag, expected)
      let requests = await transport.recorded()
      XCTAssertEqual(requests.count, 2, "Closing review must reuse the completed check's cache")
    }
  }

  @MainActor func testManualCheckMayRefreshAnOpenReview() async throws {
    let installed = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    let major = try XCTUnwrap(installed.split(separator: ".").first.flatMap { Int($0) }) + 1
    let transport = FakeReleaseTransport([releaseResponse("v\(major).0.0"), releaseResponse("v\(major).1.0")])
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = MacUpdateModel(discovery: MacReleaseDiscovery(defaults: defaults, transport: transport))
    await model.check(force: true)
    model.review()
    await model.check(force: true)
    XCTAssertEqual(model.release?.version.tag, "v\(major).1.0")
    XCTAssertTrue(model.reviewing)
  }

  @MainActor func testReviewNotificationTagWindowCloseAndTerminationLifecycle() async throws {
    let installed = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    let major = try XCTUnwrap(installed.split(separator: ".").first.flatMap { Int($0) }) + 1
    let tag = "v\(major).0.0"
    let transport = FakeReleaseTransport([releaseResponse(tag)])
    let name = "aniCe.UpdateTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let model = MacUpdateModel(discovery: MacReleaseDiscovery(defaults: defaults, transport: transport),
      automaticLifecycleEnabled: true)
    defer { model.stopAutomaticChecks() }
    await model.check(force: true)
    XCTAssertEqual(model.release?.version.tag, tag)

    let delegate = AppDelegate()
    var reopened = 0
    delegate.reopenMainWindow = { reopened += 1 }
    delegate.configureNotifications(findDevice: MacFindDeviceNotifier(),
      transfer: MacTransferNotifier(model: MacTransferModel(), openMainWindow: {}),
      updates: model)

    // A stale notification for an older version must not open the review or bring forward the window.
    delegate.handleNotificationAction(category: MacUpdateModel.notificationCategory,
      action: UNNotificationDefaultActionIdentifier, identifier: "anice.update", updateTag: "v0.8.0")
    XCTAssertFalse(model.reviewing)
    XCTAssertEqual(reopened, 0)

    delegate.handleNotificationAction(category: MacUpdateModel.notificationCategory,
      action: UNNotificationDefaultActionIdentifier, identifier: "anice.update", updateTag: tag)
    XCTAssertTrue(model.reviewing)
    XCTAssertEqual(reopened, 1)

    // Closing the main window dismisses review without resurrecting it or issuing an extra network check.
    defaults.set(0, forKey: "updates.lastSuccess")
    defaults.set(0, forKey: "updates.lastAttempt")
    model.windowClosed()
    XCTAssertFalse(model.reviewing)
    await Task.yield()
    let callsAfterClose = await transport.recorded()
    XCTAssertEqual(callsAfterClose.count, 1)

    // App termination dismisses any open review and cancels an in-flight metadata check.
    let suspended = SuspendedReleaseTransport()
    let termModel = MacUpdateModel(discovery: MacReleaseDiscovery(defaults: defaults, transport: suspended),
      automaticLifecycleEnabled: true)
    XCTAssertTrue(termModel.review(expectedTag: tag))
    XCTAssertTrue(termModel.reviewing)
    let inFlight = Task { await termModel.check(force: true) }
    let started = await suspended.waitForRequest()
    XCTAssertTrue(started)
    termModel.prepareForTermination()
    XCTAssertFalse(termModel.reviewing)
    XCTAssertFalse(termModel.automaticMonitoringActive)
    await suspended.finish(response(200, "[]"))
    await inFlight.value
    XCTAssertFalse(termModel.review(expectedTag: tag), "Terminating owner must reject late review opens")
  }
}
