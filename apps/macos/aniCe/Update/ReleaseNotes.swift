// SPDX-License-Identifier: GPL-3.0-or-later
// Presents bounded release-note Markdown as native headings, list rows and selectable attributed text.
import Foundation
import SwiftUI

struct ReleaseNoteBlock: Equatable {
  let text: String
  var heading = 0
  var marker: String?
  var indent = 0
  var literal = false
  var divider = false
}

enum ReleaseNotes {
  static let maxCharacters = 32_768
  static let maxLines = 256
  static let maxBlocks = 128
  static let maxInlineMarkdownCharacters = 8_192
  static let maxInlineSpansPerBlock = 64
  static let maxTotalInlineSpans = 256
  static let maxInlineDelimiters = 512

  static func blocks(_ raw: String, version: String? = nil) -> [ReleaseNoteBlock] {
    var result = parse(raw)
    if let version, let first = result.first, first.heading == 1,
       first.text.localizedCaseInsensitiveContains(version) {
      result.removeFirst()
    }
    return result.isEmpty ? [ReleaseNoteBlock(text: "No release notes provided.")] : result
  }

  private static func stripSourceMarkers(_ raw: String) -> String {
    var output = ""
    output.reserveCapacity(raw.count)
    var cursor = raw.startIndex
    while let open = raw[cursor...].range(of: "<!--") {
      output.append(contentsOf: raw[cursor..<open.lowerBound])
      var scan = open.upperBound
      while scan < raw.endIndex, raw[scan].isWhitespace { scan = raw.index(after: scan) }
      if raw[scan...].hasPrefix("anice-source:") {
        if let close = raw[scan...].range(of: "-->") {
          cursor = close.upperBound
        } else {
          return output
        }
      } else {
        output.append("<!--")
        cursor = open.upperBound
      }
    }
    output.append(contentsOf: raw[cursor...])
    return output
  }

  private static func isHorizontalRule(_ line: String) -> Bool {
    var index = line.startIndex
    var leading = 0
    while index < line.endIndex, line[index] == " ", leading < 3 {
      leading += 1
      index = line.index(after: index)
    }
    guard index < line.endIndex else { return false }
    let marker = line[index]
    guard marker == "-" || marker == "*" || marker == "_" else { return false }
    var count = 0
    while index < line.endIndex {
      let ch = line[index]
      if ch == marker { count += 1 }
      else if ch != " " { return false }
      index = line.index(after: index)
    }
    return count >= 3
  }

  private static func parseHeading(_ trimmed: String) -> (Int, String)? {
    var index = trimmed.startIndex
    var level = 0
    while index < trimmed.endIndex, trimmed[index] == "#" {
      level += 1
      if level > 6 { return nil }
      index = trimmed.index(after: index)
    }
    guard (1...6).contains(level), index < trimmed.endIndex, trimmed[index].isWhitespace else { return nil }
    while index < trimmed.endIndex, trimmed[index].isWhitespace { index = trimmed.index(after: index) }
    var text = String(trimmed[index...]).trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    if text.last == "#" {
      var cut = text.endIndex
      while cut > text.startIndex, text[text.index(before: cut)] == "#" {
        cut = text.index(before: cut)
      }
      if cut > text.startIndex, text[text.index(before: cut)].isWhitespace {
        let stripped = String(text[..<cut]).trimmingCharacters(in: .whitespaces)
        if !stripped.isEmpty { text = stripped }
      }
    }
    return (level, text)
  }

  private static func parseListItem(_ line: String) -> (String, Int, String)? {
    var index = line.startIndex
    var spaces = 0
    while index < line.endIndex, line[index] == " " || line[index] == "\t" {
      spaces += line[index] == "\t" ? 4 : 1
      index = line.index(after: index)
    }
    guard index < line.endIndex else { return nil }
    let marker: String
    let afterMarker: String.Index
    let first = line[index]
    if first == "-" || first == "*" || first == "+" {
      marker = "•"
      afterMarker = line.index(after: index)
    } else if first.isNumber {
      var end = index
      while end < line.endIndex, line[end].isNumber { end = line.index(after: end) }
      guard end < line.endIndex, line[end] == "." || line[end] == ")" else { return nil }
      afterMarker = line.index(after: end)
      marker = String(line[index..<afterMarker])
    } else {
      return nil
    }
    guard afterMarker < line.endIndex, line[afterMarker] == " " || line[afterMarker] == "\t" else { return nil }
    var bodyStart = afterMarker
    while bodyStart < line.endIndex, line[bodyStart] == " " || line[bodyStart] == "\t" {
      bodyStart = line.index(after: bodyStart)
    }
    guard bodyStart < line.endIndex else { return nil }
    return (marker, min(spaces / 2, 3), String(line[bodyStart...]))
  }

  private static func parse(_ raw: String) -> [ReleaseNoteBlock] {
    let clean = stripSourceMarkers(String(raw.prefix(maxCharacters)))
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    var result: [ReleaseNoteBlock] = []
    var paragraph: [String] = []
    var fence: String?
    var truncated = false

    func appendBlock(_ block: ReleaseNoteBlock) -> Bool {
      if result.count >= maxBlocks - 1 {
        // Reserve the final slot for a truncation notice if any more content arrives later.
        if result.count == maxBlocks - 1 {
          result.append(block)
          return true
        }
        truncated = true
        return false
      }
      result.append(block)
      return true
    }

    func flush(literal: Bool = false) -> Bool {
      guard !paragraph.isEmpty else { return true }
      let block = ReleaseNoteBlock(text: paragraph.joined(separator: "\n"), literal: literal)
      paragraph.removeAll(keepingCapacity: true)
      return appendBlock(block)
    }

    let lines = clean.components(separatedBy: "\n")
    for (lineNumber, line) in lines.enumerated() {
      if lineNumber >= maxLines {
        if !line.trimmingCharacters(in: .whitespaces).isEmpty || !paragraph.isEmpty { truncated = true }
        break
      }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let activeFence = fence {
        paragraph.append(line)
        if trimmed.hasPrefix(activeFence) {
          fence = nil
          if !flush(literal: true) { break }
        }
        continue
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        if !flush() { break }
        fence = String(trimmed.prefix(3))
        paragraph.append(line)
        continue
      }
      if trimmed.isEmpty {
        if !flush() { break }
        continue
      }
      if isHorizontalRule(line) {
        if !flush() { break }
        if !appendBlock(ReleaseNoteBlock(text: "", divider: true)) { break }
      } else if let (level, text) = parseHeading(trimmed) {
        if !flush() { break }
        if !appendBlock(ReleaseNoteBlock(text: text, heading: level)) { break }
      } else if let (marker, indent, text) = parseListItem(line) {
        if !flush() { break }
        if !appendBlock(ReleaseNoteBlock(text: text, marker: marker, indent: indent)) { break }
      } else {
        if result.count >= maxBlocks { truncated = true; break }
        paragraph.append(line)
      }
    }
    if !paragraph.isEmpty {
      _ = flush(literal: fence != nil)
    }
    if truncated {
      if result.count >= maxBlocks { result.removeLast() }
      result.append(ReleaseNoteBlock(text: "Release notes truncated. Open on GitHub for full notes."))
    }
    return result
  }

  static func attributed(_ text: String) -> AttributedString {
    var budget = maxInlineSpansPerBlock
    return attributed(text, remainingSpans: &budget)
  }

  static func attributed(_ text: String, remainingSpans: inout Int) -> AttributedString {
    guard !text.isEmpty, remainingSpans > 0, text.count <= maxInlineMarkdownCharacters else {
      return AttributedString(text)
    }
    var delimiterCount = 0
    for ch in text {
      if ch == "*" || ch == "_" || ch == "[" || ch == "]" || ch == "`" || ch == "!" || ch == "\\" {
        delimiterCount += 1
        if delimiterCount > maxInlineDelimiters { return AttributedString(text) }
      }
    }
    var result = (try? AttributedString(markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    let blockLimit = min(maxInlineSpansPerBlock, remainingSpans)
    var used = 0
    for run in result.runs {
      if run.imageURL != nil { result[run.range].imageURL = nil }
      if let url = run.link, url.scheme?.lowercased() != "https" { result[run.range].link = nil }
      let hasStyle = result[run.range].inlinePresentationIntent != nil || result[run.range].link != nil
      if hasStyle {
        if used < blockLimit {
          used += 1
        } else {
          result[run.range].inlinePresentationIntent = nil
          result[run.range].link = nil
        }
      }
    }
    remainingSpans = max(0, remainingSpans - used)
    return result
  }
}

struct ReleaseNotesView: View {
  private struct RenderedBlock {
    let block: ReleaseNoteBlock
    let content: AttributedString
  }

  let blocks: [ReleaseNoteBlock]
  private let rendered: [RenderedBlock]
  @AppStorage("ui.fontScale") private var fontScale = 1.0
  @Environment(\.colorScheme) private var scheme

  init(notes: String, version: String? = nil) {
    let parsed = ReleaseNotes.blocks(notes, version: version)
    self.blocks = parsed
    var remainingSpans = ReleaseNotes.maxTotalInlineSpans
    self.rendered = parsed.map { block in
      let content = (block.divider || block.literal)
        ? AttributedString(block.text)
        : ReleaseNotes.attributed(block.text, remainingSpans: &remainingSpans)
      return RenderedBlock(block: block, content: content)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(rendered.enumerated()), id: \.offset) { _, item in
        let block = item.block
        if block.divider {
          Rectangle()
            .fill(AniCePalette.separator(scheme))
            .frame(height: 1)
            .padding(.vertical, 4)
            .accessibilityHidden(true)
        } else if let marker = block.marker {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker).frame(minWidth: 12, alignment: .leading)
            Text(item.content).frame(maxWidth: .infinity, alignment: .leading)
          }
          .font(.system(size: 12 * fontScale))
          .padding(.leading, CGFloat(block.indent * 14))
        } else if block.heading > 0 {
          Text(item.content)
            .font(.system(size: (block.heading == 1 ? 16 : block.heading == 2 ? 13 : 12) * fontScale, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
        } else {
          Text(item.content).font(.system(size: 12 * fontScale))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .foregroundStyle(AniCePalette.primaryText(scheme))
    .tint(AniCePalette.accent(scheme))
    .textSelection(.enabled)
  }
}
