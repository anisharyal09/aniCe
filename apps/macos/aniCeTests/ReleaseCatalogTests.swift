// SPDX-License-Identifier: GPL-3.0-or-later
// Checks release selection and rejection of untrusted asset metadata.
import Foundation
import XCTest
@testable import aniCe

final class ReleaseCatalogTests: XCTestCase {
  private func release(_ tag: String, pre: Bool = false, asset: String = "aniCe-mac.zip", size: Int = 50, draft: Bool = false) -> [String: Any] {
    ["tag_name": tag, "draft": draft, "prerelease": pre, "body": "notes", "assets": [
      ["name": asset, "state": "uploaded", "size": size, "browser_download_url": "\(MacReleaseCatalog.root)/download/\(tag)/\(asset)"]]]
  }
  func testChannelTransitions() throws {
    let items = [release("v0.4.0-beta.2", pre: true), release("v0.3.1")]
    let data = try JSONSerialization.data(withJSONObject: items)
    let current = try XCTUnwrap(UpdateVersion.parse("v0.3.0"))
    XCTAssertEqual(try MacReleaseCatalog.fromJSON(data, current: current, includeBeta: false)?.version.tag, "v0.3.1")
    XCTAssertEqual(try MacReleaseCatalog.fromJSON(data, current: current, includeBeta: true)?.version.tag, "v0.4.0-beta.2")
    let beta = try XCTUnwrap(UpdateVersion.parse("v0.4.0-beta.2"))
    XCTAssertNil(try MacReleaseCatalog.fromJSON(data, current: beta, includeBeta: false))
    let withStable = try JSONSerialization.data(withJSONObject: items + [release("v0.4.0")])
    XCTAssertEqual(try MacReleaseCatalog.fromJSON(withStable, current: beta, includeBeta: false)?.version.tag, "v0.4.0")
  }
  func testRejectsBadAssetsAndMetadata() throws {
    let current = try XCTUnwrap(UpdateVersion.parse("v0.3.0"))
    let bad = [release("v0.4.0", asset: "other.zip"), release("v0.4.0", size: 0),
      release("v0.4.0", size: Int(MacReleaseCatalog.maxBytes) + 1), release("v0.4.0", draft: true),
      release("v0.4.0-beta.1"), release("v0.4.0+bad")]
    for item in bad {
      let data = try JSONSerialization.data(withJSONObject: [item])
      XCTAssertNil(try MacReleaseCatalog.fromJSON(data, current: current, includeBeta: true))
    }
  }
}
