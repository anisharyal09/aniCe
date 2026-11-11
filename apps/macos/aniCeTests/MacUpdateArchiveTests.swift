// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises ZIP path and symlink validation before extraction.
import Foundation
import XCTest
@testable import aniCe

final class MacUpdateArchiveTests: XCTestCase {
  func testRejectsTraversalAndSymlinkEscapes() throws {
    let fixtures: [(String, String)] = [
    ("safe.zip", "UEsDBBQAAAAAAAAAIQCDFtyMAQAAAAEAAAAdAAAAYW5pQ2UuYXBwL0NvbnRlbnRzL0luZm8ucGxpc3R4UEsDBBQAAAAAAAAAIQAhc4xNCAAAAAgAAAARAAAAYW5pQ2UuYXBwL0N1cnJlbnRDb250ZW50c1BLAQIUAxQAAAAAAAAAIQCDFtyMAQAAAAEAAAAdAAAAAAAAAAAAAACkgQAAAABhbmlDZS5hcHAvQ29udGVudHMvSW5mby5wbGlzdFBLAQIUAxQAAAAAAAAAIQAhc4xNCAAAAAgAAAARAAAAAAAAAAAAAADtoTwAAABhbmlDZS5hcHAvQ3VycmVudFBLBQYAAAAAAgACAIoAAABzAAAAAAA="),
    ("traversal.zip", "UEsDBBQAAAAAAAAAIQCDFtyMAQAAAAEAAAAJAAAALi4vZXNjYXBleFBLAQIUAxQAAAAAAAAAIQCDFtyMAQAAAAEAAAAJAAAAAAAAAAAAAACkgQAAAAAuLi9lc2NhcGVQSwUGAAAAAAEAAQA3AAAAKAAAAAAA"),
    ("symlink.zip", "UEsDBBQAAAAAAAAAIQAIQ3nrDAAAAAwAAAAQAAAAYW5pQ2UuYXBwL0VzY2FwZS4uLy4uL2VzY2FwZVBLAQIUAxQAAAAAAAAAIQAIQ3nrDAAAAAwAAAAQAAAAAAAAAAAAAADtoQAAAABhbmlDZS5hcHAvRXNjYXBlUEsFBgAAAAABAAEAPgAAADoAAAAAAA=="),
    ("ancestor.zip", "UEsDBBQAAAAAAAAAIQAhc4xNCAAAAAgAAAARAAAAYW5pQ2UuYXBwL0N1cnJlbnRDb250ZW50c1BLAwQUAAAAAAAAACEAgxbcjAEAAAABAAAAFgAAAGFuaUNlLmFwcC9DdXJyZW50L2ZpbGV4UEsBAhQDFAAAAAAAAAAhACFzjE0IAAAACAAAABEAAAAAAAAAAAAAAO2hAAAAAGFuaUNlLmFwcC9DdXJyZW50UEsBAhQDFAAAAAAAAAAhAIMW3IwBAAAAAQAAABYAAAAAAAAAAAAAAKSBNwAAAGFuaUNlLmFwcC9DdXJyZW50L2ZpbGVQSwUGAAAAAAIAAgCDAAAAbAAAAAAA"),
    ("chain.zip", "UEsDBBQAAAAAAAAAIQAcFgiWAgAAAAIAAAAQAAAAYW5pQ2UuYXBwL2EvbGluay4uUEsDBBQAAAAAAAAAIQDwQ26dDwAAAA8AAAASAAAAYW5pQ2UuYXBwL2EvYi9saW5rLi4vLi4vYS9saW5rLy4uUEsBAhQDFAAAAAAAAAAhABwWCJYCAAAAAgAAABAAAAAAAAAAAAAAAO2hAAAAAGFuaUNlLmFwcC9hL2xpbmtQSwECFAMUAAAAAAAAACEA8ENunQ8AAAAPAAAAEgAAAAAAAAAAAAAA7aEwAAAAYW5pQ2UuYXBwL2EvYi9saW5rUEsFBgAAAAACAAIAfgAAAG8AAAAAAA=="),
    ]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    XCTAssertEqual(fixtures.count, 5)
    XCTAssertEqual(fixtures.filter { $0.0 == "safe.zip" }.count, 1)
    for (name, encoded) in fixtures {
      let url = directory.appendingPathComponent(name)
      try XCTUnwrap(Data(base64Encoded: encoded)).write(to: url)
      if name == "safe.zip" { XCTAssertNoThrow(try MacUpdateArchive.validate(url), name) }
      else { XCTAssertThrowsError(try MacUpdateArchive.validate(url), name) }
    }
  }
}
