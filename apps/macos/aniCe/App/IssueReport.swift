// SPDX-License-Identifier: GPL-3.0-or-later
// Builds a user-reviewed GitHub issue link containing only app and OS versions.
import Foundation

enum IssueReport {
  static func url(appVersion: String, osVersion: String) -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "github.com"
    components.path = "/anisharyal09/aniCe/issues/new"
    components.queryItems = [
      URLQueryItem(name: "template", value: "bug_report.yml"),
      URLQueryItem(name: "app-version", value: appVersion),
      URLQueryItem(name: "os-version", value: osVersion)
    ]
    // GitHub decodes query strings as form data, where an unescaped plus means a space.
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    return components.url!
  }

  static var currentURL: URL {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    let system = ProcessInfo.processInfo.operatingSystemVersion
    return url(appVersion: version, osVersion: "macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")
  }
}
