// SPDX-License-Identifier: GPL-3.0-or-later
// Checks display-only source cleanup, native Markdown styling and isolated release-note layouts.
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import aniCe

final class ReleaseNotesTests: XCTestCase {
  func testHeadingsAndIndentedListsDoNotExposeTheSourceMarker() {
    let raw = "<!-- anice-source:abcdef -->\r\n\r\n# Release\r\n## Changes\r\n- **Fixed** downloads\r\n  * Nested item\r\n1. First step"
    let blocks = ReleaseNotes.blocks(raw)
    XCTAssertEqual(blocks.count, 5)
    XCTAssertEqual(blocks.map(\.heading), [1, 2, 0, 0, 0])
    XCTAssertEqual(blocks[0].text, "Release")
    XCTAssertEqual(blocks[2].marker, "•")
    XCTAssertEqual(blocks[3].indent, 1)
    XCTAssertEqual(blocks[4].marker, "1.")
    XCTAssertFalse(blocks.contains { $0.text.contains("anice-source") })
    XCTAssertTrue(raw.contains("anice-source"))
  }

  func testHorizontalRulesBecomeDividersAndDuplicateVersionTitleIsSuppressed() {
    let raw = "# aniCe v0.9.0-beta.2\n\n## What’s changed\n- Fixed downloads\n---\n* More polish"
    let blocks = ReleaseNotes.blocks(raw, version: "v0.9.0-beta.2")
    XCTAssertEqual(blocks.map(\.heading), [2, 0, 0, 0])
    XCTAssertEqual(blocks.filter(\.divider).count, 1)
    XCTAssertEqual(blocks[1].marker, "•")
    XCTAssertEqual(blocks[3].marker, "•")
    XCTAssertEqual(ReleaseNotes.blocks(raw).first?.heading, 1)
    XCTAssertEqual(ReleaseNotes.blocks("# Other notes", version: "v0.9.0-beta.2").first?.text, "Other notes")
    XCTAssertEqual(
      ReleaseNotes.blocks("# aniCe v0.9.0-beta.2", version: "v0.9.0-beta.2").first?.text,
      "No release notes provided.")
  }

  func testNativeInlineBoldAndLinksDiscardUnsafeSchemes() {
    let value = ReleaseNotes.attributed("A **bold title** and [release](https://github.com/anisharyal09/aniCe).")
    XCTAssertEqual(String(value.characters), "A bold title and release.")
    XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    XCTAssertEqual(value.runs.filter { $0.link != nil }.count, 1)
    let unsafe = ReleaseNotes.attributed("[Bad](javascript:alert)")
    XCTAssertTrue(unsafe.runs.allSatisfy { $0.link == nil })
  }

  func testEmptyTruncatedAndUnrecognizedNotesHaveReadableBoundedFallbacks() {
    XCTAssertEqual(ReleaseNotes.blocks("<!-- anice-source:only -->").first?.text, "No release notes provided.")
    XCTAssertEqual(ReleaseNotes.blocks("<!-- anice-source:truncated").first?.text, "No release notes provided.")
    XCTAssertEqual(ReleaseNotes.blocks("<b>Plain HTML</b>").first?.text, "<b>Plain HTML</b>")
    XCTAssertEqual(ReleaseNotes.blocks(String(repeating: "a", count: 32_769)).first?.text.count, 32_768)
    XCTAssertEqual(ReleaseNotes.blocks(String(repeating: " ", count: 100) + "- Deep item").first?.indent, 3)
  }

  func testFencedCodeRemainsLiteralInsteadOfBecomingHeadingsOrLists() {
    let raw = "```shell\n# not a heading\n- not a list\n**literal**\n```"
    let blocks = ReleaseNotes.blocks(raw)
    XCTAssertEqual(blocks.count, 1)
    XCTAssertTrue(blocks[0].literal)
    XCTAssertEqual(blocks[0].text, raw)
    XCTAssertEqual(blocks[0].heading, 0)
    XCTAssertNil(blocks[0].marker)
    XCTAssertEqual(ReleaseNotes.blocks("~~~\n# unfinished").first?.literal, true)
  }

  @MainActor func testReleaseNotesRenderAtNarrowWidthsInBothThemesAndTextScales() throws {
    let name = "aniCe.ReleaseNotesTests.\(UUID())", preferences = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { preferences.removePersistentDomain(forName: name) }
    let notes = """
    <!-- anice-source:abcdef -->
    # aniCe v0.9.0-beta.2
    ## What’s changed
    - **Update review:** Read release notes while installation actions remain available.
    - **Scheduling:** Check at 7:30 PM Nepal time, or afterward when the network is available.
      - Your settings and trusted devices stay unchanged.
    ---
    [View the release](https://github.com/anisharyal09/aniCe/releases)
    """
    var renders = 0
    for dark in [false, true] {
      for scale in [0.8, 1.0, 1.2] {
        for width in [360.0, 520.0] {
          preferences.set(scale, forKey: "ui.fontScale")
          let scheme: ColorScheme = dark ? .dark : .light
          let view = ReleaseNotesView(notes: notes, version: "v0.9.0-beta.2").padding(24)
            .frame(width: width, alignment: .topLeading)
            .background(AniCePalette.surface(scheme))
            .environment(\.colorScheme, scheme).defaultAppStorage(preferences)
          let host = NSHostingView(rootView: view)
          let size = host.fittingSize
          XCTAssertGreaterThan(size.height, 100)
          XCTAssertLessThan(size.height, 640)
          host.frame = NSRect(origin: .zero, size: size)
          host.layoutSubtreeIfNeeded()
          let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          host.cacheDisplay(in: host.bounds, to: bitmap)
          let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          XCTAssertGreaterThan(data.count, 1000)
          if let path = ProcessInfo.processInfo.environment["ANICE_REVIEW_RENDER_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("release-notes-\(dark ? "dark" : "light")-\(Int(width))-\(Int(scale * 100)).png"))
          }
          renders += 1
        }
      }
    }
    XCTAssertEqual(renders, 12)
  }
}
