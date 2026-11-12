// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies conditional release checks, saved notices and the Atom fallback.
import Foundation
import XCTest
@testable import aniCe

private actor FakeReleaseTransport: MacReleaseTransport {
  var responses: [MacReleaseResponse]
  var calls: [(String, String, String?)] = []
  init(_ responses: [MacReleaseResponse]) { self.responses = responses }
  func request(_ url: URL, method: String, etag: String?) async throws -> MacReleaseResponse {
    calls.append((url.absoluteString, method, etag))
    guard !responses.isEmpty else { throw URLError(.badServerResponse) }
    return responses.removeFirst()
  }
  func recorded() -> [(String, String, String?)] { calls }
}

final class ReleaseDiscoveryTests: XCTestCase {
  private func response(_ status: Int, _ body: String = "", etag: String? = nil) -> MacReleaseResponse {
    MacReleaseResponse(status: status, data: Data(body.utf8), etag: etag)
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
}
