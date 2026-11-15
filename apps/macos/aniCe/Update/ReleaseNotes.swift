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
  static func blocks(_ raw: String, version: String? = nil) -> [ReleaseNoteBlock] {
    var result = parse(raw)
    if let version, let first = result.first, first.heading == 1,
       first.text.localizedCaseInsensitiveContains(version) {
      result.removeFirst()
    }
    return result.isEmpty ? [ReleaseNoteBlock(text: "No release notes provided.")] : result
  }

  private static func parse(_ raw: String) -> [ReleaseNoteBlock] {
    let clean = String(raw.prefix(32_768))
      .replacingOccurrences(of: #"<!--\s*anice-source:[\s\S]*?(?:-->|$)"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    var result: [ReleaseNoteBlock] = []
    var paragraph: [String] = []
    var fence: String?
    func flush(literal: Bool = false) {
      if !paragraph.isEmpty {
        result.append(ReleaseNoteBlock(text: paragraph.joined(separator: "\n"), literal: literal))
        paragraph.removeAll(keepingCapacity: true)
      }
    }
    for line in clean.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let activeFence = fence {
        paragraph.append(line)
        if trimmed.hasPrefix(activeFence) { flush(literal: true); fence = nil }
        continue
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        flush()
        fence = String(trimmed.prefix(3))
        paragraph.append(line)
        continue
      }
      if trimmed.isEmpty { flush(); continue }
      if trimmed.firstMatch(of: #/^ {0,3}([-*_])(?: *\1){2,}$/#) != nil {
        flush()
        result.append(ReleaseNoteBlock(text: "", divider: true))
      } else if let match = trimmed.firstMatch(of: #/^(#{1,6})\s+(.+?)(?:\s+#+)?$/#) {
        flush()
        result.append(ReleaseNoteBlock(text: String(match.2), heading: match.1.count))
      } else if let match = line.firstMatch(of: #/^(\s*)([-*+]|\d+[.)])\s+(.+)$/#) {
        flush()
        let marker = String(match.2)
        let indent = match.1.replacingOccurrences(of: "\t", with: "    ").count / 2
        result.append(ReleaseNoteBlock(text: String(match.3),
          marker: marker.first?.isNumber == true ? marker : "•", indent: min(indent, 3)))
      } else {
        paragraph.append(line)
      }
    }
    flush(literal: fence != nil)
    return result
  }

  static func attributed(_ text: String) -> AttributedString {
    var result = (try? AttributedString(markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    for run in result.runs {
      if let url = run.link, url.scheme?.lowercased() != "https" { result[run.range].link = nil }
    }
    return result
  }
}

struct ReleaseNotesView: View {
  let blocks: [ReleaseNoteBlock]
  @AppStorage("ui.fontScale") private var fontScale = 1.0
  @Environment(\.colorScheme) private var scheme

  init(notes: String, version: String? = nil) { blocks = ReleaseNotes.blocks(notes, version: version) }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        if block.divider {
          Rectangle()
            .fill(AniCePalette.separator(scheme))
            .frame(height: 1)
            .padding(.vertical, 4)
            .accessibilityHidden(true)
        } else if let marker = block.marker {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker).frame(minWidth: 12, alignment: .leading)
            Text(ReleaseNotes.attributed(block.text)).frame(maxWidth: .infinity, alignment: .leading)
          }
          .font(.system(size: 12 * fontScale))
          .padding(.leading, CGFloat(block.indent * 14))
        } else if block.heading > 0 {
          Text(ReleaseNotes.attributed(block.text))
            .font(.system(size: (block.heading == 1 ? 16 : block.heading == 2 ? 13 : 12) * fontScale, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
        } else {
          Text(block.literal ? AttributedString(block.text) : ReleaseNotes.attributed(block.text)).font(.system(size: 12 * fontScale))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .foregroundStyle(AniCePalette.primaryText(scheme))
    .tint(AniCePalette.accent(scheme))
    .textSelection(.enabled)
  }
}
