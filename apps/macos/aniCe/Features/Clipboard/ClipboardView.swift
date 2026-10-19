// SPDX-License-Identifier: GPL-3.0-or-later
// Presents native clipboard sharing and optional device-local text history.
import AppKit
import SwiftUI

struct ClipboardSettingsView: View {
  let model: MacClipboardModel
  let peers: [PeerTrustRecord]
  var showHistory = true
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if peers.isEmpty { Text("Pair a device to share your clipboard.").foregroundStyle(.secondary) }
      else if peers.count > 1 {
        Picker("Device", selection: Binding(get: { model.selected.map { $0.deviceId + ":" + $0.fingerprint } ?? "" }, set: { value in
          model.select(peers.first { $0.peer.deviceId + ":" + $0.peer.fingerprint == value }?.peer)
        })) { ForEach(peers) { record in Text(record.peer.deviceName).tag(record.peer.deviceId + ":" + record.peer.fingerprint) } }
      } else if let peer = peers.first { Text(peer.peer.deviceName).font(.headline) }
      Toggle("Automatic clipboard sharing", isOn: Binding(get: { model.automatic }, set: { model.setAutomatic($0) }))
        .toggleStyle(.checkbox).controlSize(.small).tint(AniCePalette.accent(scheme)).disabled(model.selected == nil)
      if showHistory { HistoryPreference(history: model.history) }
      ClipboardAccessGuidance(model: model)
    }
    .onAppear { model.prune(peers.map(\.peer)); if model.selected == nil { model.select(peers.first?.peer) }; model.refreshAccess() }
    .onChange(of: peers.map { $0.peer.deviceId + ":" + $0.peer.fingerprint }) { _, _ in model.prune(peers.map(\.peer)); if model.selected == nil { model.select(peers.first?.peer) } }
  }
}
private struct ClipboardAccessGuidance: View {
  let model: MacClipboardModel
  var body: some View {
    if (model.automatic || model.history.enabled) && !model.automaticAccessAllowed {
      Text("Allow pasteboard access for automatic reading, or paste text into Share → More options.").font(.caption).foregroundStyle(.secondary)
      Button("Pasteboard settings") {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") { NSWorkspace.shared.open(url) }
      }
    }
  }
}
private struct HistoryPreference: View {
  let history: ClipboardHistory
  @Environment(\.colorScheme) private var scheme
  @State private var confirming = false
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle("Keep clipboard history", isOn: Binding(get: { history.enabled }, set: { if $0 { confirming = true } else { history.setEnabled(false) } }))
        .toggleStyle(.checkbox).controlSize(.small).tint(AniCePalette.accent(scheme))
        .alert("Keep clipboard history?", isPresented: $confirming) {
          Button("Enable") { history.setEnabled(true) }; Button("Cancel", role: .cancel) {}
        } message: { Text("Save the latest text items on this Mac across restarts. Recognized sensitive text is excluded. Turning this off pauses collection and keeps saved items. Delete items or use Clear to remove them.") }

      // History capacity: limits FIFO unpinned persistence to 20, 50, or 100 items.
      if history.enabled || !history.entries.isEmpty {
        HStack(spacing: 8) {
          Picker("History capacity", selection: Binding(get: { history.capacity }, set: { history.setCapacity($0) })) {
            Text("20 items").tag(20)
            Text("50 items").tag(50)
            Text("100 items").tag(100)
          }
          .pickerStyle(.menu)
          .controlSize(.small)
        }
      }
    }
    if !history.enabled && !history.entries.isEmpty { Text("Collection paused · Saved items are kept").font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme)) }
    if let error = history.error { Text(error).font(.caption).foregroundStyle(AniCePalette.error(scheme)) }
  }
}
struct ClipboardView: View {
  let model: MacClipboardModel
  let peers: [PeerTrustRecord]
  @State private var historyTab = false
  @State private var more = false
  @State private var reveal = false
  @State private var pasted = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Picker("Clipboard view", selection: $historyTab) { Text("Share").tag(false); Text("History").tag(true) }
          .pickerStyle(.segmented).labelsHidden()
        Button("Open tray", systemImage: "rectangle.stack") { PasteTrayController.shared.show() }
          .buttonStyle(.bordered).controlSize(.small).help("Open clipboard tray (⌥⌘V)")
      }
      if historyTab { ClipboardHistoryView(model: model); ClipboardAccessGuidance(model: model) }
      else {
        ClipboardSettingsView(model: model, peers: peers, showHistory: false)
        let available = model.selected.map(model.supports) == true
        if let peer = model.selected, !available { Text(model.connected(peer) ? "Clipboard unavailable on this device" : "Connect first").font(.callout) }
        if model.status != "Ready to share text" && (available || model.busy) { Text(model.status).font(.caption).foregroundStyle(.secondary) }
        HStack {
          ClipboardSendButton(model: model)
          if model.busy { Button("Cancel send") { model.cancel() } }
        }
        DisclosureGroup("More options", isExpanded: $more) {
          VStack(alignment: .leading, spacing: 8) {
            Button("Inspect clipboard") { model.inspect() }.disabled(model.busy)
            if let sample = model.preview {
              Text("\(sample.text.utf8.count) bytes · \(sample.sensitive ? "Sensitive text" : "Plain text")").font(.caption)
              if reveal { Text(sample.text).textSelection(.enabled) }
              else { Button("Reveal text") { reveal = true } }
            }
            TextField("Paste text here", text: $pasted, axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder)
              .onChange(of: pasted) { _, value in if value.utf8.count > 65536 { pasted = "" } }
            if !pasted.isEmpty { Button("Send pasted text") { model.send(pasted: pasted); pasted = "" }.disabled(model.busy || !available) }
          }.padding(.top, 8)
        }
        DisclosureGroup("How sharing works") {
          Text("Manual sharing works with automatic sharing off. From another Android app, use Share → Send to Mac for text or links, or select text and choose Send to Mac where offered. For text already copied on the phone, its Send to Mac Quick Settings tile opens an explicit sending panel. The Mac must already be connected.\n\nFor automatic sharing, enable it on both devices. Android shares copies while aniCe has focus; copy text and open aniCe. Incoming text replaces the receiving clipboard, including while the phone app is in the background. Recent activity offers a short preview and local Copy for eligible text. Optional history stays on each device, organized by date with the latest items first.").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .padding(.horizontal, 4)
    .onChange(of: model.preview?.text) { _, _ in reveal = false }
    .onChange(of: historyTab) { _, _ in clearContent() }
    .onChange(of: more) { _, value in if !value { clearContent() } }
    .onChange(of: model.selected.map { $0.deviceId + ":" + $0.fingerprint }) { _, _ in clearContent() }
    .onChange(of: model.selected.map(model.supports)) { _, supported in if supported != true { clearContent() } }
    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in clearContent() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshAccess() }
    .onDisappear { clearContent() }
  }
  private func clearContent() { pasted = ""; reveal = false; model.clearPreview() }
}

// Both entry points confirm the exact captured item, never a later pasteboard read.
struct ClipboardSendButton: View {
  let model: MacClipboardModel
  @State private var sensitiveSample: ClipboardSample?
  var body: some View {
    Button {
      model.send(); sensitiveSample = model.preview?.sensitive == true ? model.preview : nil
    } label: { Label("Send clipboard", systemImage: "doc.on.clipboard") }
      .buttonStyle(.bordered).controlSize(.small)
      .disabled(model.busy || model.selected.map(model.supports) != true)
      .alert("Send sensitive text?", isPresented: Binding(get: { sensitiveSample != nil }, set: { if !$0 { sensitiveSample = nil } }), presenting: sensitiveSample) { captured in
        Button("Send") { model.sendConfirmed(captured); sensitiveSample = nil }
        Button("Cancel", role: .cancel) { sensitiveSample = nil; model.clearPreview() }
      } message: { _ in Text("This clipboard is marked sensitive. Send it to \(model.selected?.deviceName ?? "the selected device")?") }
      .onChange(of: model.selected.map { $0.deviceId + ":" + $0.fingerprint }) { _, _ in sensitiveSample = nil }
      .onChange(of: model.preview == nil) { _, empty in if empty { sensitiveSample = nil } }
      .onDisappear { sensitiveSample = nil; model.clearPreview() }
  }
}

struct ClipboardActivityView: View {
  let model: MacClipboardModel
  var compact = false
  let open: () -> Void
  @Environment(\.colorScheme) private var scheme
  @State private var copyStatus: String?
  var body: some View {
    if let item = model.recent {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Button(action: open) { HStack { Text("Clipboard"); Image(systemName: "chevron.forward").font(.caption).accessibilityHidden(true) } }
            .buttonStyle(.plain).font(.headline).accessibilityLabel("Open Clipboard")
          Spacer()
          Button { model.dismissActivity(item.id) } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain).accessibilityLabel("Dismiss clipboard activity")
        }
        ViewThatFits(in: .horizontal) {
          HStack { origin(item); Text(item.timestamp, format: .dateTime.hour().minute()); direction(item) }
          VStack(alignment: .leading) { origin(item); HStack { Text(item.timestamp, format: .dateTime.hour().minute()); direction(item) } }
        }.font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
        if let preview = item.textPreview { Text(preview).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }
        else { Text("Preview hidden for marked clipboard items").font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme)) }
        if item.sample != nil {
          Button { copyStatus = model.copyActivity(item.id) ? "Copied" : "Could not copy" } label: { Label(copyStatus ?? "Copy", systemImage: "doc.on.doc") }
            .buttonStyle(.borderless).controlSize(.small)
        }
      }
      .padding(compact ? 0 : 16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(compact ? Color.clear : AniCePalette.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
      .onChange(of: item.id) { _, _ in copyStatus = nil }
    }
  }
  private func origin(_ item: ClipboardActivity) -> Text { Text(item.received ? "From phone" : "From Mac") }
  private func direction(_ item: ClipboardActivity) -> Text { Text(item.received ? "Received" : "Sent to phone") }
}
struct ClipboardHistoryView: View {
  let model: MacClipboardModel
  @State private var clearing = false
  @State private var query = ""
  @State private var filter: PasteTrayFilter = .all
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HistoryPreference(history: model.history)
      HStack {
        Text("\(model.history.entries.count) saved · On this Mac").font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
        Spacer()
        if !model.history.entries.isEmpty { Button("Clear...") { clearing = true }.buttonStyle(.borderless).controlSize(.small) }
      }
      if model.status != "Ready to share text" { Text(model.status).font(.caption).foregroundStyle(.secondary) }
      if model.busy { Button("Cancel send") { model.cancel() } }
      if model.history.enabled || !model.history.entries.isEmpty {
        TextField("Search history", text: $query).textFieldStyle(.roundedBorder)
          .accessibilityLabel("Search saved clipboard history")
        Picker("History filter", selection: $filter) {
          ForEach(PasteTrayFilter.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().tint(AniCePalette.accent(scheme))
      }
      let entries = filter.entries(in: model.history.entries, query: query)
      if entries.isEmpty { Text(model.history.enabled ? (query.isEmpty && filter == .all ? "No clipboard history yet" : "No matching clipboard items") : "Enable history to keep text on this Mac").foregroundStyle(.secondary) }
      else {
        let days = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.timestamp) }
        ForEach(days.keys.sorted(by: >), id: \.self) { day in
          Text(day, format: .dateTime.year().month().day()).font(.subheadline.weight(.medium))
          ForEach(days[day] ?? []) { entry in
            VStack(alignment: .leading, spacing: 6) {
              Text(String(entry.text.prefix(240))).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
              ViewThatFits(in: .horizontal) {
                HStack { metadata(entry); Spacer(); actions(entry) }
                VStack(alignment: .leading, spacing: 4) { metadata(entry); HStack { actions(entry) } }
              }.buttonStyle(.borderless).controlSize(.small)
            }
            .padding(.vertical, 8)
            Divider()
          }
        }
      }
      if model.history.error != nil && model.history.entries.isEmpty { Button("Clear history") { model.history.clear(includePinned: true) } }
    }
    .confirmationDialog("Clear clipboard history?", isPresented: $clearing) {
      Button("Clear unpinned", role: .destructive) { model.history.clear(includePinned: false) }
      Button("Clear all", role: .destructive) { model.history.clear(includePinned: true) }
      Button("Cancel", role: .cancel) {}
    } message: { Text("Clear saved text on this Mac. Pinned snippets are kept when clearing unpinned items.") }
  }
  private func metadata(_ entry: ClipboardHistoryEntry) -> some View {
    HStack(spacing: 6) {
      if entry.pinned {
        Image(systemName: "pin.fill")
          .font(.caption2)
          .foregroundStyle(AniCePalette.warning(scheme))
      }
      Text(entry.origin == "mac" ? "From Mac" : "From phone")
      Text(entry.timestamp, format: .dateTime.hour().minute())
    }
    .font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
  }
  @ViewBuilder private func actions(_ entry: ClipboardHistoryEntry) -> some View {
    Button { model.copyHistory(entry) } label: { Label("Copy", systemImage: "doc.on.doc") }
    Button { model.togglePin(entry) } label: {
      Label(entry.pinned ? "Unpin" : "Pin", systemImage: entry.pinned ? "pin.fill" : "pin")
    }
    Button { model.sendHistory(entry) } label: { Label("Send", systemImage: "paperplane") }
      .disabled(model.busy || model.selected.map(model.supports) != true)
    Button(role: .destructive) { model.history.delete(entry.id) } label: { Label("Delete", systemImage: "trash") }
  }
}
