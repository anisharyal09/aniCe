// SPDX-License-Identifier: GPL-3.0-or-later
// Presents searchable local clipboard cards with stable selection and native copy actions.
import AppKit
import SwiftUI

private extension Color {
  /// Parses standard CSS hex color representations (#RGB, #RGBA, #RRGGBB, #RRGGBBAA) into an sRGB Color.
  init?(hex: String) {
    var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if hexSanitized.hasPrefix("#") {
      hexSanitized.removeFirst()
    }
    guard [3, 4, 6, 8].contains(hexSanitized.count) else { return nil }
    var rgbValue: UInt64 = 0
    guard Scanner(string: hexSanitized).scanHexInt64(&rgbValue) else { return nil }

    let r, g, b, a: Double
    switch hexSanitized.count {
    case 3:
      // Short #RGB -> duplicate 4-bit nibbles (e.g. #F0A -> #FF00AA).
      r = Double(((rgbValue & 0xF00) >> 8) * 17) / 255.0
      g = Double(((rgbValue & 0x0F0) >> 4) * 17) / 255.0
      b = Double((rgbValue & 0x00F) * 17) / 255.0
      a = 1.0
    case 4:
      // Short #RGBA -> duplicate nibbles including alpha channel.
      r = Double(((rgbValue & 0xF000) >> 12) * 17) / 255.0
      g = Double(((rgbValue & 0x0F00) >> 8) * 17) / 255.0
      b = Double(((rgbValue & 0x00F0) >> 4) * 17) / 255.0
      a = Double((rgbValue & 0x000F) * 17) / 255.0
    case 6:
      // Standard #RRGGBB format with full opacity.
      r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
      g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
      b = Double(rgbValue & 0x0000FF) / 255.0
      a = 1.0
    case 8:
      // #RRGGBBAA format with trailing alpha channel.
      r = Double((rgbValue & 0xFF000000) >> 24) / 255.0
      g = Double((rgbValue & 0x00FF0000) >> 16) / 255.0
      b = Double((rgbValue & 0x0000FF00) >> 8) / 255.0
      a = Double(rgbValue & 0x000000FF) / 255.0
    default:
      return nil
    }
    self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
  }
}

enum PasteTrayKeyboard {
  // AppKit encodes arrows and function keys as private-use Unicode, not control characters.
  static let searchCharacters = CharacterSet.controlCharacters
    .union(CharacterSet(charactersIn: "\u{F700}"..."\u{F8FF}")).inverted
}

enum PasteTrayFilter: String, CaseIterable, Identifiable {
  case all = "All", pinned = "Pinned", mac = "Mac", phone = "Phone"
  var id: String { rawValue }

  func entries(in history: [ClipboardHistoryEntry], query: String) -> [ClipboardHistoryEntry] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let matches = history.filter { entry in
      (query.isEmpty || entry.text.localizedCaseInsensitiveContains(query)) &&
        (self == .all || (self == .pinned && entry.pinned) ||
         (self == .mac && entry.origin == "mac") || (self == .phone && entry.origin == "phone"))
    }
    return matches.filter(\.pinned) + matches.filter { !$0.pinned }
  }
}

struct PasteTrayView: View {
  let model: MacClipboardModel
  var width: CGFloat = 760
  let onDismiss: () -> Void
  let onSelect: (ClipboardHistoryEntry) -> Void
  var previewHeight: CGFloat = 460
  var onHeightChange: (CGFloat) -> Void = { _ in }
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var query = ""
  @State private var filter: PasteTrayFilter = .all
  @State private var selectedID: String?
  @State private var confirmingHistory = false
  private enum Focus: Hashable { case tray, search }
  @FocusState private var focus: Focus?
  @State private var previewing = false

  private var entries: [ClipboardHistoryEntry] {
    filter.entries(in: model.history.entries, query: query)
  }
  private var selected: ClipboardHistoryEntry? {
    entries.first { $0.id == selectedID } ?? entries.first
  }
  private var selectedIndex: Int { entries.firstIndex { $0.id == selected?.id } ?? 0 }

  var body: some View {
    VStack(spacing: 8) {
      searchRow
      HStack {
        Picker("History filter", selection: $filter) {
          ForEach(PasteTrayFilter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
        Spacer()
        Text(model.history.enabled ? "Saved on this Mac" : "Collection paused").font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
      }
      if previewing, let selected {
        PasteTrayExpandedPreview(entry: selected).frame(maxHeight: .infinity)
      } else {
        content.frame(height: 156)
      }
      HStack(spacing: 8) {
        Text(entries.isEmpty ? "0 items" : "\(selectedIndex + 1) of \(entries.count)")
        Spacer()
        Text(model.status == "Could not copy text" ? "Could not copy text. Try again." : "← → Select · Space Preview · ↵ Copy")
        Button(previewing ? "Collapse" : "Preview", systemImage: previewing ? "rectangle.compress.vertical" : "arrow.up.left.and.arrow.down.right") {
          togglePreview()
        }.disabled(selected == nil).help("Preview full text (Space)")
        Button("Copy", systemImage: "doc.on.doc") { copySelection() }
          .disabled(selected == nil)
          .help("Copy selected item and close (Return)")
      }
      .font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
    }
    .buttonStyle(.bordered).controlSize(.small)
    .padding(16).frame(width: width, height: previewing ? previewHeight : 292)
    .foregroundStyle(AniCePalette.primaryText(scheme))
    .background(AniCePalette.surface(scheme), in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(AniCePalette.separator(scheme)))
    .tint(AniCePalette.accent(scheme))
    .focusable().focusEffectDisabled().focused($focus, equals: .tray)
    .onAppear { selectedID = entries.first?.id; focus = .tray }
    .onKeyPress(.escape) {
      if previewing { previewing = false; focus = .tray }
      else if focus == .search { query = ""; focus = .tray }
      else { onDismiss() }
      return .handled
    }
    .onKeyPress(.space) {
      guard focus == .tray else { return .ignored }
      togglePreview(); return .handled
    }
    .onKeyPress(.return) {
      guard focus == .tray else { return .ignored }; copySelection(); return .handled
    }
    .onKeyPress(.upArrow) {
      guard !previewing else { return .ignored }; move(-1); return .handled
    }
    .onKeyPress(.downArrow) {
      guard !previewing else { return .ignored }; move(1); return .handled
    }
    .onKeyPress(.leftArrow) {
      guard focus != .search else { return .ignored }; move(-1); return .handled
    }
    .onKeyPress(.rightArrow) {
      guard focus != .search else { return .ignored }; move(1); return .handled
    }
    .onKeyPress(characters: PasteTrayKeyboard.searchCharacters) { press in
      guard press.characters != " " else { return .ignored }
      guard focus == .tray, press.modifiers.intersection([.command, .control, .option]).isEmpty else {
        if press.modifiers == .command && press.characters == "f" { focus = .search; return .handled }
        return .ignored
      }
      query += press.characters; previewing = false; focus = .search
      return .handled
    }
    .onChange(of: previewing) { _, expanded in onHeightChange(expanded ? previewHeight : 292) }
    .onChange(of: query) { _, _ in selectedID = entries.first?.id }
    .onChange(of: filter) { _, _ in selectedID = entries.first?.id }
    .onChange(of: entries.map(\.id)) { _, ids in
      if !ids.contains(selectedID ?? "") { selectedID = ids.first }
      if ids.isEmpty { previewing = false }
    }
    .alert("Keep clipboard history?", isPresented: $confirmingHistory) {
      Button("Enable") { model.history.setEnabled(true) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Save eligible text on this Mac across restarts. Recognized sensitive text is excluded. Turning history off pauses collection and keeps saved items.")
    }
  }

  private var searchRow: some View {
    HStack(spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(AniCePalette.secondaryText(scheme))
        TextField("Search clipboard history", text: $query)
          .textFieldStyle(.plain).focused($focus, equals: .search)
          .accessibilityLabel("Search clipboard history")
          .onSubmit { copySelection() }
        if !query.isEmpty {
          Button { query = ""; focus = .search } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain).accessibilityLabel("Clear search")
        }
      }
      .padding(8).background(AniCePalette.secondarySurface(scheme), in: RoundedRectangle(cornerRadius: 8))
      Button(action: onDismiss) { Image(systemName: "xmark").frame(width: 24, height: 24) }
        .buttonStyle(.plain).accessibilityLabel("Close clipboard tray").help("Close (Esc)")
    }
  }

  @ViewBuilder private var content: some View {
    if !model.history.enabled && model.history.entries.isEmpty {
      VStack(spacing: 8) {
        Text("Your clipboard, close at hand").font(.headline)
        Text("Enable local history to find and reuse copied text.").font(.callout)
        Button("Enable history…") { confirmingHistory = true }
        if let error = model.history.error { Text(error).font(.caption).foregroundStyle(AniCePalette.error(scheme)) }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if entries.isEmpty {
      VStack(spacing: 8) {
        Image(systemName: "doc.on.clipboard").font(.title2)
        Text(!query.isEmpty ? "No matching items" : filter == .pinned ? "No pinned items" : "No clipboard items yet")
          .font(.headline)
        Text(query.isEmpty ? "Copied text will appear here. Try another filter to see more." : "Try another search or filter.")
          .font(.callout)
      }.foregroundStyle(AniCePalette.secondaryText(scheme)).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          LazyHStack(spacing: 10) {
            ForEach(entries) { entry in
              PasteTrayCard(entry: entry, isSelected: selected?.id == entry.id,
                onSelect: { onSelect(entry) }, onTogglePin: { model.togglePin(entry) },
                onDelete: { model.deleteHistory(entry) })
                .id(entry.id)
            }
          }.padding(2)
        }
        .scrollIndicators(.hidden)
        .onChange(of: selected?.id) { _, id in
          if let id {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
          }
        }
      }
    }
  }

  private func togglePreview() {
    guard selected != nil else { return }
    previewing.toggle(); focus = .tray
  }
  private func move(_ delta: Int) {
    guard !entries.isEmpty else { return }
    focus = .tray
    selectedID = entries[min(max(selectedIndex + delta, 0), entries.count - 1)].id
  }
  private func copySelection() {
    if let selected { onSelect(selected) }
  }
}

struct PasteTrayExpandedPreview: View {
  let entry: ClipboardHistoryEntry
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(entry.origin == "phone" ? "From phone" : "From Mac", systemImage: entry.origin == "phone" ? "iphone" : "laptopcomputer")
        Spacer()
        Text(entry.timestamp, format: .dateTime.month().day().hour().minute())
      }.font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
      ScrollView {
        Text(entry.text).font(.body).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(12)
      }
      .background(AniCePalette.secondarySurface(scheme), in: RoundedRectangle(cornerRadius: 10))
      .id(entry.id)
      .accessibilityLabel("Full clipboard text")
    }
  }
}

private struct PasteTrayCard: View {
  let entry: ClipboardHistoryEntry
  let isSelected: Bool
  let onSelect: () -> Void
  let onTogglePin: () -> Void
  let onDelete: () -> Void

  @Environment(\.colorScheme) private var scheme
  @State private var hovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      Button(action: onSelect) {
        bodyPreview.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Copy " + String(entry.text.prefix(120)))
      .accessibilityAddTraits(isSelected ? [.isSelected] : [])
      Spacer(minLength: 0)
      footer
    }
    .padding(12)
    .frame(width: 168, height: 152)
    .background(
      isSelected ? AniCePalette.subtleAccent(scheme) : AniCePalette.secondarySurface(scheme)
    )
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(
          isSelected ? AniCePalette.accent(scheme) : (hovered ? AniCePalette.secondaryText(scheme).opacity(0.3) : AniCePalette.separator(scheme)),
          lineWidth: isSelected ? 1.5 : 1.0
        )
    )
    .onHover { isHovered in
      hovered = isHovered
    }

  }

  private var header: some View {
    HStack(spacing: 4) {
      HStack(spacing: 3) {
        Image(systemName: entry.origin == "phone" ? "iphone" : "laptopcomputer")
          .font(.system(size: 9))
        Text(entry.origin == "phone" ? "Phone" : "Mac")
          .font(.system(size: 10, weight: .medium))
      }
      .foregroundStyle(AniCePalette.secondaryText(scheme))

      Spacer()

      if entry.pinned {
        Image(systemName: "pin.fill")
          .font(.system(size: 9))
          .foregroundStyle(AniCePalette.warning(scheme))
      }


    }
  }

  @ViewBuilder
  private var bodyPreview: some View {
    if let hex = entry.hexColorValue, let color = Color(hex: hex) {
      // Smart preview: render physical color swatch alongside hex code.
      HStack(spacing: 8) {
        RoundedRectangle(cornerRadius: 4)
          .fill(color)
          .frame(width: 28, height: 28)
          .overlay(
            RoundedRectangle(cornerRadius: 4)
              .stroke(AniCePalette.separator(scheme), lineWidth: 0.5)
          )

        VStack(alignment: .leading, spacing: 2) {
          Text(hex)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(AniCePalette.primaryText(scheme))
          Text("Color")
            .font(.system(size: 9))
            .foregroundStyle(AniCePalette.secondaryText(scheme))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else if entry.isUrl {
      // Smart preview: render link symbol with structured URL prefix.
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 4) {
          Image(systemName: "link")
            .font(.system(size: 9))
            .foregroundStyle(AniCePalette.accent(scheme))
          Text("URL")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(AniCePalette.accent(scheme))
        }
        Text(URL(string: entry.text.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? entry.text)
          .font(.system(size: 12))
          .foregroundStyle(AniCePalette.primaryText(scheme))
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else {
      // General text: switch to monospace when code punctuation or keywords are present.
      Text(entry.text.prefix(120))
        .font(isCodeLike(entry.text) ? .system(size: 12, design: .monospaced) : .system(size: 12))
        .foregroundStyle(AniCePalette.primaryText(scheme))
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var footer: some View {
    HStack {
      Text(entry.timestamp, format: .dateTime.hour().minute())
        .font(.system(size: 9))
        .foregroundStyle(AniCePalette.secondaryText(scheme))

      Spacer()

      Group {
        Button(action: onTogglePin) {
          Image(systemName: entry.pinned ? "pin.slash" : "pin")
            .font(.system(size: 11))
            .foregroundStyle(AniCePalette.secondaryText(scheme))
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(entry.pinned ? "Unpin" : "Pin snippet")
        .accessibilityLabel(entry.pinned ? "Unpin item" : "Pin item")
      }

      Group {
        Button(action: onDelete) {
          Image(systemName: "trash")
            .font(.system(size: 11))
            .foregroundStyle(AniCePalette.secondaryText(scheme))
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help("Delete from history").accessibilityLabel("Delete item")
      }
    }
  }

  /// Heuristic distinguishing structured code snippets from natural language text.
  private func isCodeLike(_ text: String) -> Bool {
    text.contains("{") || text.contains("}") || text.contains(";") || text.contains("func ") || text.contains("const ") || text.contains("var ")
  }
}
