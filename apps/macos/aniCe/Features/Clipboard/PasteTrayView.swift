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

enum PasteTraySelection {
  static func reconcile(_ selectedIDs: Set<String>, pivotID: String?, entryIDs: [String]) -> (ids: Set<String>, pivot: String?) {
    let available = Set(entryIDs)
    var ids = selectedIDs.intersection(available)
    if ids.isEmpty, let first = entryIDs.first { ids.insert(first) }
    let pivot = pivotID.flatMap { ids.contains($0) ? $0 : nil } ?? entryIDs.first(where: ids.contains)
    return (ids, pivot)
  }
}

struct PasteTrayView: View {
  let model: MacClipboardModel
  var width: CGFloat = 760
  let onDismiss: () -> Void
  let onSelect: (ClipboardHistoryEntry) -> Bool
  var onCopied: () -> Void = {}
  var previewHeight: CGFloat = 460
  var onHeightChange: (CGFloat) -> Void = { _ in }
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var query = ""
  @State private var filter: PasteTrayFilter = .all
  /// Multiple selection set supporting shift-click range expansion and multi-item operations.
  @State private var selectedIDs: Set<String> = []
  /// The anchor / pivot item ID used to calculate contiguous ranges during Shift + Click or Shift + Arrow.
  @State private var pivotID: String?
  @State private var confirmingHistory = false
  private enum Focus: Hashable { case tray, search }
  @FocusState private var focus: Focus?
  @State private var previewing = false

  private var entries: [ClipboardHistoryEntry] {
    filter.entries(in: model.history.entries, query: query)
  }
  /// Primary selected entry; returns the pivot, earliest selected item, or the first filtered entry.
  private var selected: ClipboardHistoryEntry? {
    if let pivotID, selectedIDs.contains(pivotID), let entry = entries.first(where: { $0.id == pivotID }) {
      return entry
    }
    return entries.first { selectedIDs.contains($0.id) } ?? entries.first
  }
  /// Index of the primary active/selected entry within the current filter results.
  private var selectedIndex: Int {
    entries.firstIndex { $0.id == selected?.id } ?? 0
  }
  private var columns: [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
  }
  private var isNarrow: Bool { width <= 650 }
  private var cardHeight: CGFloat { isNarrow ? 145 : 149 }
  private var contentHeight: CGFloat { isNarrow ? 154 : 156 }
  private var collapsedHeight: CGFloat { isNarrow ? 318 : 292 }

  var body: some View {
    VStack(spacing: 8) {
      header
      filterRow
      if previewing, let selected {
        PasteTrayExpandedPreview(entry: selected).frame(maxHeight: .infinity)
      } else {
        content.frame(height: contentHeight)
      }
      footer
    }
    .controlSize(.small)
    .padding(.horizontal, 16).padding(.vertical, width <= 540 ? 13 : 15)
    .frame(width: width, height: previewing ? previewHeight : collapsedHeight)
    .foregroundStyle(AniCePalette.primaryText(scheme))
    .background(AniCePalette.surface(scheme), in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(AniCePalette.separator(scheme)))
    .tint(AniCePalette.accent(scheme))
    .focusable().focusEffectDisabled().focused($focus, equals: .tray)
    .onAppear {
      if let first = entries.first?.id {
        selectedIDs = [first]
        pivotID = first
      }
      focus = .tray
    }
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
    .onKeyPress(.delete) {
      guard focus == .tray else { return .ignored }
      deleteSelection(); return .handled
    }
    .onKeyPress(.deleteForward) {
      guard focus == .tray else { return .ignored }
      deleteSelection(); return .handled
    }
    .onKeyPress(characters: CharacterSet(charactersIn: "\u{7F}\u{08}")) { _ in
      guard focus == .tray else { return .ignored }
      deleteSelection(); return .handled
    }
    .onKeyPress(.upArrow) {
      guard !previewing else { return .ignored }
      let isShift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? NSEvent.modifierFlags.contains(.shift)
      move(width <= 540 ? -1 : -3, extend: isShift); return .handled
    }
    .onKeyPress(.downArrow) {
      guard !previewing else { return .ignored }
      let isShift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? NSEvent.modifierFlags.contains(.shift)
      move(width <= 540 ? 1 : 3, extend: isShift); return .handled
    }
    .onKeyPress(.leftArrow) {
      guard focus != .search else { return .ignored }
      let isShift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? NSEvent.modifierFlags.contains(.shift)
      move(-1, extend: isShift); return .handled
    }
    .onKeyPress(.rightArrow) {
      guard focus != .search else { return .ignored }
      let isShift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? NSEvent.modifierFlags.contains(.shift)
      move(1, extend: isShift); return .handled
    }
    .onKeyPress(characters: PasteTrayKeyboard.searchCharacters) { press in
      guard press.characters != " " else { return .ignored }
      guard focus == .tray, press.modifiers.intersection([.command, .control, .option]).isEmpty else {
        if press.modifiers == .command && press.characters == "f" { focus = .search; return .handled }
        if press.modifiers == .command && press.characters == "a" {
          selectedIDs = Set(entries.map(\.id))
          pivotID = entries.first?.id
          return .handled
        }
        return .ignored
      }
      query += press.characters; previewing = false; focus = .search
      return .handled
    }
    .onChange(of: previewing) { _, expanded in onHeightChange(expanded ? previewHeight : collapsedHeight) }
    .onChange(of: entries.map(\.id)) { _, ids in
      let selection = PasteTraySelection.reconcile(selectedIDs, pivotID: pivotID, entryIDs: ids)
      selectedIDs = selection.ids
      pivotID = selection.pivot
      if ids.isEmpty { previewing = false }
    }
    .alert("Keep clipboard history?", isPresented: $confirmingHistory) {
      Button("Enable") { model.history.setEnabled(true) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Save eligible text on this Mac across restarts. Recognized sensitive text is excluded. Turning history off pauses collection and keeps saved items.")
    }
  }

  private var header: some View {
    Group {
      if isNarrow {
        VStack(spacing: 8) {
          HStack {
            title
            Spacer()
            closeButton
          }
          searchField.frame(maxWidth: .infinity)
        }
      } else {
        HStack(spacing: 12) {
          title
          Spacer(minLength: 4)
          searchField.frame(width: 214)
          closeButton
        }
      }
    }
  }

  private var title: some View {
    HStack(spacing: 7) {
      Image(systemName: "clipboard").font(.system(size: 14)).foregroundStyle(AniCePalette.secondaryText(scheme))
      Text("Clipboard").font(.system(size: 13, weight: .medium))
      if !isNarrow {
        Text("⌥⌘V").font(.system(size: 10)).foregroundStyle(AniCePalette.secondaryText(scheme))
      }
    }.fixedSize()
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(AniCePalette.secondaryText(scheme))
      TextField("Find a clip…", text: $query)
        .textFieldStyle(.plain).focused($focus, equals: .search)
        .accessibilityLabel("Search clipboard history")
        .onSubmit { copySelection() }
      if !query.isEmpty {
        Button { query = ""; focus = .search } label: { Image(systemName: "xmark.circle.fill") }
          .buttonStyle(.plain).accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 9).frame(height: 30)
    .background(AniCePalette.secondarySurface(scheme), in: RoundedRectangle(cornerRadius: 7))
  }

  private var closeButton: some View {
    Button(action: onDismiss) { Image(systemName: "xmark").frame(width: 25, height: 25) }
      .buttonStyle(.plain).accessibilityLabel("Close clipboard tray").help("Close (Esc)")
  }

  private var filterRow: some View {
    HStack(alignment: .bottom, spacing: 17) {
      ForEach(PasteTrayFilter.allCases) { option in
        Button {
          filter = option
        } label: {
          VStack(spacing: 5) {
            Text(option.rawValue)
              .font(.system(size: 11, weight: filter == option ? .medium : .regular))
              .foregroundStyle(filter == option ? AniCePalette.primaryText(scheme) : AniCePalette.secondaryText(scheme))
            Rectangle().fill(filter == option ? AniCePalette.accent(scheme) : .clear).frame(height: 2)
          }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == option ? .isSelected : [])
      }
      Spacer(minLength: 0)
      Text("\(entries.count) \(entries.count == 1 ? "clip" : "clips")")
        .font(.system(size: 10)).foregroundStyle(AniCePalette.secondaryText(scheme)).padding(.bottom, 7)
    }
    .overlay(alignment: .bottom) { Rectangle().fill(AniCePalette.separator(scheme)).frame(height: 1) }
  }

  private var footer: some View {
    HStack(spacing: 10) {
      if isNarrow {
        Text(selectedIDs.count > 1 ? "\(selectedIDs.count) selected" : "← → · Space · ↵ · ⌫")
      } else {
        Text(selectedIDs.count > 1 ? "\(selectedIDs.count) selected" : "← → Select · Space Preview · ↵ Copy · ⌫ Delete")
      }
      Spacer(minLength: 0)
      if model.status == "Could not copy text" {
        Text("Could not copy text. Try again.").font(.system(size: 10)).foregroundStyle(AniCePalette.error(scheme))
          .accessibilityAddTraits(.updatesFrequently)
      }
      Button(selectedIDs.count > 1 ? "Copy all" : "Copy", systemImage: "doc.on.doc") { copySelection() }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(selectedIDs.isEmpty && selected == nil)
        .help(selectedIDs.count > 1 ? "Copy selected items joined by newlines (Return)" : "Copy selected item and close (Return)")
    }
    .font(.system(size: 10)).foregroundStyle(AniCePalette.secondaryText(scheme))
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
        if isNarrow {
          ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
              ForEach(entries, content: trayCard)
            }
            .padding(2)
          }
          .scrollIndicators(.hidden)
          .scrollClipDisabled()
          .onChange(of: pivotID ?? selected?.id) { _, id in
            if let id {
              withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
          }
        } else {
          ScrollView(.vertical) {
            LazyVGrid(columns: columns, spacing: 10) {
              ForEach(entries, content: trayCard)
            }.padding(2)
          }
          .scrollIndicators(.hidden)
          .onChange(of: pivotID ?? selected?.id) { _, id in
            if let id {
              withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
          }
        }
      }
    }
  }

  private func trayCard(_ entry: ClipboardHistoryEntry) -> some View {
    PasteTrayCard(
      entry: entry,
      isSelected: selectedIDs.contains(entry.id),
      compact: isNarrow,
      height: cardHeight,
      onClick: { handleCardClick(entry) },
      onTogglePin: { model.togglePin(entry) },
      onDelete: {
        if selectedIDs.contains(entry.id) && selectedIDs.count > 1 {
          deleteSelection()
        } else {
          selectedIDs = [entry.id]
          deleteSelection()
        }
      }
    )
    .frame(width: isNarrow ? 196 : nil)
    .id(entry.id)
  }

  /// Deletes all currently selected history items from local storage and advances selection.
  private func deleteSelection() {
    guard !selectedIDs.isEmpty, !entries.isEmpty else { return }
    let idsToDelete = selectedIDs
    let earliestIndex = entries.firstIndex { idsToDelete.contains($0.id) } ?? 0
    let remaining = entries.filter { !idsToDelete.contains($0.id) }

    model.deleteHistory(ids: idsToDelete)

    if !remaining.isEmpty {
      let nextIndex = min(earliestIndex, remaining.count - 1)
      let nextEntry = remaining[nextIndex]
      selectedIDs = [nextEntry.id]
      pivotID = nextEntry.id
    } else {
      selectedIDs = []
      pivotID = nil
      previewing = false
    }
  }

  /// Copies either the single active entry or multiple selected entries joined with newlines.
  private func copySelection() {
    let selectedEntries = entries.filter { selectedIDs.contains($0.id) }
    if selectedEntries.count > 1 {
      let combined = selectedEntries.map(\.text).joined(separator: "\n")
      if model.copyText(combined) { onDismiss(); onCopied() }
    } else if let target = selectedEntries.first ?? selected {
      copy(target)
    }
  }

  private func copy(_ entry: ClipboardHistoryEntry) {
    if onSelect(entry) { onDismiss(); onCopied() }
  }

  /// Handles card mouse clicks supporting:
  /// - Double click: copies immediately and dismisses tray.
  /// - Shift + click: multi-selects contiguous range between pivot and clicked card.
  /// - Command + click: toggles individual card in multi-selection.
  /// - Single click: selects single card and sets as pivot anchor.
  private func handleCardClick(_ entry: ClipboardHistoryEntry) {
    focus = .tray
    let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
    let clickCount = NSApp.currentEvent?.clickCount ?? 1

    if clickCount >= 2 {
      copy(entry)
      return
    }

    if modifiers.contains(.shift) {
      let pivot = pivotID ?? selectedIDs.first ?? entry.id
      if let pivotIdx = entries.firstIndex(where: { $0.id == pivot }),
         let currentIdx = entries.firstIndex(where: { $0.id == entry.id }) {
        let range = min(pivotIdx, currentIdx)...max(pivotIdx, currentIdx)
        selectedIDs = Set(entries[range].map(\.id))
      } else {
        selectedIDs = [entry.id]
        pivotID = entry.id
      }
    } else if modifiers.contains(.command) {
      if selectedIDs.contains(entry.id) {
        selectedIDs.remove(entry.id)
      } else {
        selectedIDs.insert(entry.id)
      }
      pivotID = entry.id
    } else {
      selectedIDs = [entry.id]
      pivotID = entry.id
    }
  }

  private func togglePreview() {
    guard selected != nil else { return }
    previewing.toggle(); focus = .tray
  }

  /// Moves selection by delta; if extend is true (Shift key held), expands selection range.
  private func move(_ delta: Int, extend: Bool = false) {
    guard !entries.isEmpty else { return }
    focus = .tray
    let currentIdx = selectedIndex
    let nextIdx = min(max(currentIdx + delta, 0), entries.count - 1)
    let nextEntry = entries[nextIdx]

    if extend {
      let pivot = pivotID ?? entries[currentIdx].id
      pivotID = pivot
      if let pivotIdx = entries.firstIndex(where: { $0.id == pivot }) {
        let range = min(pivotIdx, nextIdx)...max(pivotIdx, nextIdx)
        selectedIDs = Set(entries[range].map(\.id))
      }
    } else {
      selectedIDs = [nextEntry.id]
      pivotID = nextEntry.id
    }
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
  let compact: Bool
  let height: CGFloat
  /// Card selection supports click, range selection, multi-selection and double-click copy.
  let onClick: () -> Void
  let onTogglePin: () -> Void
  let onDelete: () -> Void

  @Environment(\.colorScheme) private var scheme
  @State private var hovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      Button(action: onClick) {
        bodyPreview.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Select " + String(entry.text.prefix(120)))
      .accessibilityAddTraits(isSelected ? [.isSelected] : [])
      Spacer(minLength: 0)
      footer
    }
    .padding(compact ? 8 : 12)
    .frame(maxWidth: .infinity).frame(height: height)
    .background(
      isSelected ? AniCePalette.subtleAccent(scheme) : AniCePalette.secondarySurface(scheme)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
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
        Image(systemName: entry.isUrl ? "link" : "doc.text")
          .font(.system(size: 9))
        Text(entry.isUrl ? "Link" : "Text")
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
      Text("\(entry.origin == "phone" ? "Phone" : "Mac") · \(entry.timestamp.formatted(.dateTime.hour().minute()))")
        .font(.system(size: 9)).foregroundStyle(AniCePalette.secondaryText(scheme)).lineLimit(1)

      Spacer()

      Group {
        Button(action: onTogglePin) {
          Image(systemName: entry.pinned ? "pin.slash" : "pin")
            .font(.system(size: 11))
            .foregroundStyle(AniCePalette.secondaryText(scheme))
            .frame(width: 23, height: 23)
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
            .frame(width: 23, height: 23)
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
