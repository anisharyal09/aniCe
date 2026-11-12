// SPDX-License-Identifier: GPL-3.0-or-later
// Validates release tags and orders prereleases below their final release.
import Foundation

struct UpdateVersion: Comparable {
  let tag: String
  let code: Int
  let prerelease: Bool

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.code < rhs.code }

  static func parse(_ tag: String) -> Self? {
    let pattern = #"\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(alpha|beta|rc)\.([1-9][0-9]*))?\z"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
    func value(_ index: Int) -> String? {
      guard let range = Range(match.range(at: index), in: tag) else { return nil }
      return String(tag[range])
    }
    guard let a = value(1), let b = value(2), let c = value(3),
      let major = Int(a), let minor = Int(b), let patch = Int(c),
      major <= 2000, minor <= 99, patch <= 99 else { return nil }
    let stage = value(4)
    let stageCode: Int
    if let stage {
      guard let raw = value(5), let number = Int(raw), (1...19).contains(number) else { return nil }
      switch stage {
      case "alpha": stageCode = number
      case "beta": stageCode = 20 + number
      case "rc": stageCode = 40 + number
      default: return nil
      }
    } else { stageCode = 99 }
    return Self(tag: tag, code: major * 1_000_000 + minor * 10_000 + patch * 100 + stageCode, prerelease: stage != nil)
  }
}
