// SPDX-License-Identifier: GPL-3.0-or-later
// Tests download size limits, chunked transfer and truncated or inconsistent responses.
import Foundation
import XCTest
@testable import aniCe

private final class StagedDownloadProtocol: URLProtocol {
  nonisolated(unsafe) static var reply: (HTTPURLResponse, Data)?
  override class func canInit(with request: URLRequest) -> Bool { reply != nil }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let (response, data) = Self.reply else { return }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

final class MacUpdateStagingTests: XCTestCase {
  func testDownloadWritesExactBytes() async throws {
    let payload = Data(repeating: 0x5a, count: 200_000)
    let url = URL(string: "https://github.com/anisharyal09/aniCe/releases/download/v0.4.0/aniCe-mac.zip")!
    StagedDownloadProtocol.reply = (HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Length": String(payload.count)])!, payload)
    defer { StagedDownloadProtocol.reply = nil }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StagedDownloadProtocol.self]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("update.zip")
    try await MacUpdateDownload(destination: destination, expected: Int64(payload.count),
      configuration: configuration) { _, _ in }.start(URLRequest(url: url))
    XCTAssertEqual(try Data(contentsOf: destination), payload)
  }

  func testDownloadRejectsUnexpectedLength() async throws {
    let payload = Data(repeating: 0x5a, count: 100_000)
    let url = URL(string: "https://github.com/anisharyal09/aniCe/releases/download/v0.4.0/aniCe-mac.zip")!
    StagedDownloadProtocol.reply = (HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Length": String(payload.count)])!, payload)
    defer { StagedDownloadProtocol.reply = nil }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StagedDownloadProtocol.self]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("update.zip")
    do {
      try await MacUpdateDownload(destination: destination, expected: Int64(payload.count - 1),
        configuration: configuration) { _, _ in }.start(URLRequest(url: url))
      XCTFail("An inconsistent release length must fail")
    } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testDownloadLengths() throws {
    XCTAssertNoThrow(try MacUpdateStaging.checkLength(50, advertised: 50, expected: 50, complete: true))
    XCTAssertNoThrow(try MacUpdateStaging.checkLength(50, advertised: nil, expected: nil, complete: true))
    XCTAssertThrowsError(try MacUpdateStaging.checkLength(49, advertised: 50, expected: 50, complete: true))
    XCTAssertThrowsError(try MacUpdateStaging.checkLength(50, advertised: 51, expected: 50, complete: false))
    XCTAssertThrowsError(try MacUpdateStaging.checkLength(0, advertised: 0, expected: nil, complete: false))
    XCTAssertThrowsError(try MacUpdateStaging.checkLength(MacReleaseCatalog.maxBytes + 1, advertised: nil, expected: nil, complete: false))
  }

  func testStaleCleanupOnlyRemovesOldOwnedStaging() throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: parent) }
    let stale = parent.appendingPathComponent(".aniCe-update-stale")
    let fresh = parent.appendingPathComponent(".aniCe-update-fresh")
    let other = parent.appendingPathComponent("aniCe.app")
    for url in [stale, fresh, other] { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }
    try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-172_800)], ofItemAtPath: stale.path)
    MacUpdateStaging.removeStale(in: parent)
    XCTAssertFalse(fileManager.fileExists(atPath: stale.path))
    XCTAssertTrue(fileManager.fileExists(atPath: fresh.path))
    XCTAssertTrue(fileManager.fileExists(atPath: other.path))
  }
}
