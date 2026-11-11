// SPDX-License-Identifier: GPL-3.0-or-later
// Selects a newer Mac release from untrusted GitHub metadata.
import Foundation

struct AvailableMacRelease: Equatable {
  let version: UpdateVersion
  let notes: String
  let assetURL: URL
  let assetBytes: Int64?
  var pageURL: URL { URL(string: "https://github.com/anisharyal09/aniCe/releases/tag/\(version.tag)")! }
}

enum MacReleaseCatalog {
  static let root = "https://github.com/anisharyal09/aniCe/releases"
  static let maxBytes: Int64 = 256 * 1024 * 1024
  static func assetURL(_ version: UpdateVersion) -> URL {
    URL(string: "\(root)/download/\(version.tag)/aniCe-mac.zip")!
  }

  static func fromJSON(_ data: Data, current: UpdateVersion, includeBeta: Bool) throws -> AvailableMacRelease? {
    guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw CocoaError(.propertyListReadCorrupt)
    }
    return releases.compactMap { item -> AvailableMacRelease? in
      guard item["draft"] as? Bool == false,
        let tag = item["tag_name"] as? String, let version = UpdateVersion.parse(tag), version > current,
        includeBeta || !version.prerelease, item["prerelease"] as? Bool == version.prerelease,
        let assets = item["assets"] as? [[String: Any]],
        let asset = assets.first(where: { $0["name"] as? String == "aniCe-mac.zip" && $0["state"] as? String == "uploaded" }),
        let size = (asset["size"] as? NSNumber)?.int64Value, (1...maxBytes).contains(size),
        let rawURL = asset["browser_download_url"] as? String, rawURL == assetURL(version).absoluteString else { return nil }
      let notes = String((item["body"] as? String ?? "").prefix(32_768))
      return AvailableMacRelease(version: version, notes: notes, assetURL: assetURL(version), assetBytes: size)
    }.max { $0.version < $1.version }
  }
}
