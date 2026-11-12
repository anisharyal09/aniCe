// SPDX-License-Identifier: GPL-3.0-or-later
// Ensures the updater rejects unconfigured and incorrect signing identities.
import Foundation
import XCTest
@testable import aniCe

final class MacUpdateSignatureTests: XCTestCase {
  func testRequiresPinsAndRejectsWrongCertificate() {
    let bundle = Bundle.main.bundleURL
    XCTAssertThrowsError(try MacUpdateSignature.validate(bundle, identifier: "io.github.anisharyal09.anice", pins: []))
    XCTAssertThrowsError(try MacUpdateSignature.validate(bundle, identifier: "io.github.anisharyal09.anice", pins: [String(repeating: "0", count: 64)]))
    XCTAssertThrowsError(try MacUpdateSignature.validate(bundle, identifier: "wrong\"identifier", pins: [String(repeating: "0", count: 64)]))
  }

  func testPackagedAppAndHelperAreArm64AndRejectOtherFiles() throws {
    try MacUpdateSignature.validateArchitecture(try XCTUnwrap(Bundle.main.executableURL))
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/aniCeUpdateHelper")
    try MacUpdateSignature.validateArchitecture(helper)
    XCTAssertThrowsError(try MacUpdateSignature.validateArchitecture(Bundle.main.bundleURL))
  }

  // A complete little-endian Mach-O 64 header: arm64/all, MH_EXECUTE.
  private let arm64Header = Data([
    0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ])

  func testArm64HeaderCannotBypassCodeSignatureValidation() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try arm64Header.write(to: file)
    try MacUpdateSignature.validateArchitecture(file)
    XCTAssertThrowsError(try MacUpdateSignature.validate(file,
      identifier: "io.github.anisharyal09.anice", pins: [String(repeating: "0", count: 64)]))
  }

  func testRejectsIntelFatUnsupportedSubtypeAndNonExecutableHeaders() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let mutations: [(String, Range<Int>, [UInt8])] = [
      ("Intel", 4..<8, [0x07, 0x00, 0x00, 0x01]),
      ("32-bit ARM", 4..<8, [0x0c, 0x00, 0x00, 0x00]),
      ("arm64e", 8..<12, [0x02, 0x00, 0x00, 0x00]),
      ("dylib", 12..<16, [0x06, 0x00, 0x00, 0x00]),
      ("32-bit Mach-O", 0..<4, [0xce, 0xfa, 0xed, 0xfe]),
      ("wrong byte order", 0..<4, [0xfe, 0xed, 0xfa, 0xcf]),
      ("fat Mach-O", 0..<4, [0xca, 0xfe, 0xba, 0xbe]),
      ("fat Mach-O 64", 0..<4, [0xca, 0xfe, 0xba, 0xbf]),
    ]
    for (label, range, bytes) in mutations {
      var data = arm64Header
      data.replaceSubrange(range, with: bytes)
      try data.write(to: file)
      XCTAssertThrowsError(try MacUpdateSignature.validateArchitecture(file), label) { error in
        guard case MacUpdateSignature.Error.invalidArchitecture = error else {
          return XCTFail("Unexpected architecture error for \(label): \(error)")
        }
      }
    }
  }

  func testRejectsTruncatedExecutableHeaders() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    for count in 0..<arm64Header.count {
      try Data(arm64Header.prefix(count)).write(to: file)
      XCTAssertThrowsError(try MacUpdateSignature.validateArchitecture(file), "header length \(count)")
    }
  }
}
