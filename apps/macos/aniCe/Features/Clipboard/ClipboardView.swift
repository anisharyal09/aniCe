// SPDX-License-Identifier: GPL-3.0-or-later
// Presents native clipboard sharing and optional device-local text history.
import AppKit
import SwiftUI

struct ClipboardHistoryPauseMenu: View {
  let history: ClipboardHistory
  @State private var custom = false
  @State private var minutes = 60.0
  var body: some View {
    Menu(history.collectionPaused ? "Resume history" : "Pause history") {
      if history.collectionPaused {
        Button("Resume history") { history.resumeCollection() }
      }
      ForEach(ClipboardPauseDuration.allCases) { duration in
        Button(duration.rawValue) { history.pauseCollection(seconds: duration.seconds) }
      }
      Button("Custom…") { custom = true }
    }.menuStyle(.borderedButton).controlSize(.small).aniCeControlFeedback()
      .help(history.pauseDescription ?? "Pause history collection only; automatic sharing stays available")
      .popover(isPresented: $custom) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Pause history").font(.headline)
          Stepper("Minutes: \(Int(minutes))", value: $minutes, in: 1...43200, step: 15)
          HStack {
            Button("Cancel") { custom = false }
            Button("Pause") { history.pauseCollection(seconds: minutes * 60); custom = false }
          }
        }.padding(16)
      }
  }
}

struct ClipboardSettingsView: View {
  let model: MacClipboardModel
  let peers: [PeerTrustRecord]
  var showHistory = true
  var compactSettings = false
  var showPreferences = true
  @Environment(\.colorScheme) private var scheme
  @AppStorage("ui.fontScale") private var fontScale = 1.0
  var body: some View {
    VStack(alignment: .leading, spacing: compactSettings ? 0 : 8) {
      if peers.isEmpty { Text("Pair a device to share your clipboard.").foregroundStyle(.secondary) }
      else if peers.count > 1 {
        Picker("Device", selection: Binding(get: { model.selected.map { $0.deviceId + ":" + $0.fingerprint } ?? "" }, set: { value in
          model.select(peers.first { $0.peer.deviceId + ":" + $0.peer.fingerprint == value }?.peer)
        })) { ForEach(peers) { record in Text(record.peer.displayName).tag(record.peer.deviceId + ":" + record.peer.fingerprint) } }
      } else if !compactSettings, let peer = peers.first { Text(peer.peer.displayName).font(.headline) }
      if !showPreferences, model.selected != nil {
        Text(model.automatic ? "Automatic sharing on" : "Manual sharing")
          .font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
      }
      if showPreferences {
        Toggle(compactSettings ? "Automatic sharing" : "Automatic clipboard sharing", isOn: Binding(get: { model.automatic }, set: { model.setAutomatic($0) }))
          .toggleStyle(AniCePreferenceToggleStyle(description: compactSettings && model.selected != nil
            ? "Enable on both devices. Manual sends stay available." : nil))
          .disabled(model.selected == nil)
        if !compactSettings {
          HStack(spacing: 8) {
            Text(model.isPaused ? (model.pauseStatusText ?? "Clipboard paused") : "Clipboard observation active")
              .font(.caption)
              .foregroundStyle(model.isPaused ? AniCePalette.accent(scheme) : AniCePalette.secondaryText(scheme))
            Spacer()
            if model.isPaused {
              Button("Resume") { model.resume() }
                .buttonStyle(AniCeButtonStyle()).controlSize(.small)
            }
            Menu(model.isPaused ? "Change" : "Pause…") {
              ForEach(ClipboardPauseDuration.allCases) { duration in
                Button(duration.rawValue) { model.pause(for: duration) }
              }
            }
            .menuStyle(.borderedButton).aniCeControlFeedback()
            .controlSize(.small)
          }
        }
        if showHistory {
          if compactSettings {
            Rectangle().fill(AniCePalette.separator(scheme)).frame(height: 0.5).padding(.vertical, 8)
          }
          HistoryPreference(history: model.history, compact: compactSettings)
          if model.history.enabled || model.history.collectionPaused {
            ViewThatFits(in: .horizontal) {
              HStack(alignment: .center, spacing: 12) {
                historyCollectionStatus
                Spacer(minLength: 8)
                ClipboardHistoryPauseMenu(history: model.history)
              }
              VStack(alignment: .leading, spacing: 8) {
                historyCollectionStatus
                ClipboardHistoryPauseMenu(history: model.history)
                  .frame(maxWidth: .infinity, alignment: .trailing)
              }
            }.frame(minHeight: 32).padding(.top, 6)
          }
        }
      }
      ClipboardAccessGuidance(model: model, settingsFontScale: compactSettings ? fontScale : nil)
    }
    .onAppear { model.prune(peers.map(\.peer)); if model.selected == nil { model.select(peers.first?.peer) }; model.refreshAccess() }
    .onChange(of: peers.map { $0.peer.deviceId + ":" + $0.peer.fingerprint }) { _, _ in model.prune(peers.map(\.peer)); if model.selected == nil { model.select(peers.first?.peer) } }
  }
  private var historyCollectionStatus: some View {
    Text(model.history.pauseDescription ?? "Collection active")
      .font(compactSettings ? .system(size: 12 * fontScale) : .caption)
      .foregroundStyle(AniCePalette.secondaryText(scheme))
      .fixedSize(horizontal: false, vertical: true)
  }
}
private struct ClipboardAccessGuidance: View {
  let model: MacClipboardModel
  var settingsFontScale: Double? = nil
  var body: some View {
    if (model.automatic || model.history.enabled) && !model.automaticAccessAllowed {
      Text("Allow pasteboard access for automatic reading, or paste text into Share → More options.")
        .font(settingsFontScale.map { Font.system(size: 12 * $0) } ?? .caption).foregroundStyle(.secondary)
      Button("Pasteboard settings") {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") { NSWorkspace.shared.open(url) }
      }
    }
  }
}
private struct HistoryPreference: View {
  let history: ClipboardHistory
  var compact = false
  @Environment(\.colorScheme) private var scheme
  @State private var confirming = false
  @AppStorage("ui.fontScale") private var fontScale = 1.0
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle("Keep clipboard history", isOn: Binding(get: { history.enabled }, set: { if $0 { confirming = true } else { history.setEnabled(false) } }))
        .toggleStyle(AniCePreferenceToggleStyle(description: compact ? "Saved on this Mac. Pausing keeps saved clips." : nil))
        .alert("Keep clipboard history?", isPresented: $confirming) {
          Button("Enable") { history.setEnabled(true) }; Button("Cancel", role: .cancel) {}
        } message: { Text("Save the latest text items on this Mac across restarts. Recognized sensitive text is excluded. Turning this off pauses collection and keeps saved items. Delete items or use Clear to remove them.") }

      ClipboardHistoryCapacityPicker(history: history, fontScale: fontScale)
    }
    if !compact && !history.enabled && !history.entries.isEmpty { Text("Collection paused · Saved items are kept").font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme)) }
    if let error = history.error {
      Text(error).font(compact ? .system(size: 13 * fontScale) : .caption).foregroundStyle(AniCePalette.error(scheme))
    }
  }
}

struct ClipboardHistoryCapacityPicker: View {
  let history: ClipboardHistory
  var fontScale: Double = 1
  var body: some View {
    AniCePreferenceRow("History capacity", fontScale: fontScale) {
      Picker("History capacity", selection: Binding(
        get: { history.capacity }, set: { if $0 != history.capacity { history.setCapacity($0) } })) {
        ForEach([20, 50, 100], id: \.self) { Text("\($0) items").tag($0) }
      }
      .labelsHidden().pickerStyle(.menu).controlSize(.small)
      .aniCeControlFeedback()
      .help("Keep the latest unpinned clips. Pinned clips are kept separately, up to 100 total.")
    }
  }
}

struct ClipboardView: View {
  let model: MacClipboardModel
  let peers: [PeerTrustRecord]
  var openSettings: (() -> Void)? = nil
  @Environment(\.colorScheme) private var scheme
  @AppStorage("ui.fontScale") private var fontScale = 1.0
  @State private var historyTab = false
  @State private var preferencesOpen = false
  @State private var more = false
  @State private var reveal = false
  @State private var pasted = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          clipboardTabs
          Spacer(minLength: 8)
          clipboardActions
        }
        VStack(alignment: .leading, spacing: 8) {
          clipboardTabs
          HStack {
            Spacer(minLength: 8)
            clipboardActions
          }
        }
      }
      if preferencesOpen {
        VStack(alignment: .leading, spacing: 8) {
          Text("Clipboard settings").font(.subheadline.weight(.medium))
          ClipboardSettingsView(model: model, peers: peers, showHistory: true, compactSettings: false)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { AniCePalette.separator(scheme).frame(height: 0.5) }
      }
      if historyTab { ClipboardHistoryView(model: model); ClipboardAccessGuidance(model: model) }
      else {
        ClipboardSettingsView(model: model, peers: peers, showHistory: false, showPreferences: false)
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
  private var clipboardTabs: some View {
    AniCeSegmentedControl(
      options: [(value: false, title: "Share"), (value: true, title: "History")],
      selection: $historyTab,
      fontScale: fontScale,
      size: .regular,
      accessibilityLabel: "Clipboard view"
    )
    .onMoveCommand { direction in
      if direction == .left { historyTab = false }
      if direction == .right { historyTab = true }
    }
  }
  private var clipboardActions: some View {
    HStack(spacing: 12) {
      Button { PasteTrayController.shared.show() } label: {
        Label { Text("Open tray") } icon: {
          Image(systemName: "rectangle.stack").foregroundStyle(AniCePalette.secondaryText(scheme))
        }
      }
      .buttonStyle(AniCeButtonStyle(quiet: true))
      .fixedSize()
      .help("Open clipboard tray (\(GlobalShortcutPreferences.shared.binding(.tray).label))")
      Button {
        if let openSettings { openSettings() } else { preferencesOpen.toggle() }
      } label: { Image(systemName: "gearshape").frame(width: 24, height: 24) }
        .buttonStyle(AniCeHoverButtonStyle()).controlSize(.small)
        .help("Clipboard preferences").accessibilityLabel("Clipboard preferences")
    }
  }
  private func clearContent() { pasted = ""; reveal = false; model.clearPreview() }
}

// Manual sends confirm the captured item, never a later pasteboard read.
struct ClipboardSendButton: View {
  let model: MacClipboardModel
  var quiet = false
  var compact = false
  @Environment(\.colorScheme) private var colorScheme
  @State private var sensitiveSample: ClipboardSample?
  var body: some View {
    Button {
      model.send(); sensitiveSample = model.preview?.sensitive == true ? model.preview : nil
    } label: {
      Label { Text("Send clipboard") } icon: {
        Image(systemName: "doc.on.clipboard")
          .foregroundStyle((quiet || compact) ? AniCePalette.secondaryText(colorScheme) : AniCePalette.primaryText(colorScheme))
      }
    }
      .buttonStyle(AniCeButtonStyle(quiet: quiet, compact: compact))
      .disabled(model.busy || model.selected.map(model.supports) != true)
      .alert("Send sensitive text?", isPresented: Binding(get: { sensitiveSample != nil }, set: { if !$0 { sensitiveSample = nil } }), presenting: sensitiveSample) { captured in
        Button("Send") { model.sendConfirmed(captured); sensitiveSample = nil }
        Button("Cancel", role: .cancel) { sensitiveSample = nil; model.clearPreview() }
      } message: { _ in Text("This clipboard is marked sensitive. Send it to \(model.selected?.displayName ?? "the selected device")?") }
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
      if compact {
        HStack(alignment: .center, spacing: 14) {
          Image(systemName: "doc.on.clipboard").font(.title3).accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
              Text("Clipboard").font(.callout.weight(.medium))
              Text(item.timestamp, format: .dateTime.hour().minute())
                .font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
              Spacer(minLength: 8)
              Text(item.received ? "From phone" : "From Mac")
                .font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
            }
            if let preview = item.textPreview { Text(preview).font(.callout).lineLimit(2) }
            else { Text("Preview hidden for marked clipboard items").font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme)) }
          }
          Spacer(minLength: 8)
          if item.sample != nil {
            Button { copyStatus = model.copyActivity(item.id) ? "Copied" : "Could not copy" } label: {
              Label(copyStatus ?? "Copy", systemImage: "doc.on.doc")
            }.buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel(copyStatus ?? "Copy clipboard item")
          }
          Button { model.dismissActivity(item.id) } label: { Text("Dismiss") }
            .buttonStyle(AniCeHoverButtonStyle()).foregroundStyle(AniCePalette.secondaryText(scheme))
        }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
          .onChange(of: item.id) { _, _ in copyStatus = nil }
      } else {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Button(action: open) { HStack { Text("Clipboard"); Image(systemName: "chevron.forward").font(.caption).accessibilityHidden(true) } }
            .buttonStyle(AniCeHoverButtonStyle()).font(.headline).accessibilityLabel("Open Clipboard")
          Spacer()
          Button { model.dismissActivity(item.id) } label: { Image(systemName: "xmark") }
            .buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("Dismiss clipboard activity")
        }
        ViewThatFits(in: .horizontal) {
          HStack { origin(item); Text(item.timestamp, format: .dateTime.hour().minute()); direction(item) }
          VStack(alignment: .leading) { origin(item); HStack { Text(item.timestamp, format: .dateTime.hour().minute()); direction(item) } }
        }.font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
        if let preview = item.textPreview { Text(preview).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }
        else { Text("Preview hidden for marked clipboard items").font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme)) }
        if item.sample != nil {
          Button { copyStatus = model.copyActivity(item.id) ? "Copied" : "Could not copy" } label: { Label(copyStatus ?? "Copy", systemImage: "doc.on.doc") }
            .buttonStyle(.borderless).aniCeControlFeedback().controlSize(.small)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(AniCePalette.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
      .onChange(of: item.id) { _, _ in copyStatus = nil }
      }
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
  @AppStorage("ui.fontScale") private var fontScale = 1.0
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("\(model.history.entries.count) saved · On this Mac").font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
        Spacer()
        Text(model.history.collecting ? "History on" : "History paused")
          .font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
        if !model.history.entries.isEmpty { Button("Clear...") { clearing = true }.buttonStyle(.borderless).aniCeControlFeedback().controlSize(.small) }
      }
      ClipboardHistoryCapacityPicker(history: model.history, fontScale: fontScale)
      if model.status != "Ready to share text" { Text(model.status).font(.caption).foregroundStyle(.secondary) }
      if model.busy { Button("Cancel send") { model.cancel() } }
      if model.history.enabled || !model.history.entries.isEmpty {
        TextField("Search history", text: $query).textFieldStyle(.roundedBorder)
          .accessibilityLabel("Search saved clipboard history")
        AniCeSegmentedControl(
          options: PasteTrayFilter.allCases.map { (value: $0, title: $0.rawValue) },
          selection: $filter,
          fontScale: fontScale,
          accessibilityLabel: "History filter"
        )
      }
      let entries = filter.entries(in: model.history.entries, query: query)
      if entries.isEmpty {
        Text(!model.history.entries.isEmpty || !query.isEmpty || filter != .all
          ? "No matching clipboard items"
          : (model.history.enabled ? "No clipboard history yet" : "Enable history to keep text on this Mac"))
          .foregroundStyle(.secondary)
      } else {
        let days = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.timestamp) }
        ForEach(days.keys.sorted(by: >), id: \.self) { day in
          Text(day, format: .dateTime.year().month().day()).font(.subheadline.weight(.medium))
          ForEach(days[day] ?? []) { entry in
            VStack(alignment: .leading, spacing: 6) {
              Text(String(entry.text.prefix(240))).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
              ViewThatFits(in: .horizontal) {
                HStack { metadata(entry); Spacer(); actions(entry) }
                VStack(alignment: .leading, spacing: 4) { metadata(entry); HStack { actions(entry) } }
              }.controlSize(.small)
            }
            .padding(.vertical, 8)
            Divider()
          }
        }
      }
      if let error = model.history.error { Text(error).font(.caption).foregroundStyle(AniCePalette.error(scheme)) }
      if model.history.error != nil && model.history.entries.isEmpty { Button("Retry history update") { model.history.setEnabled(model.history.enabled) } }
      if let status = model.history.editStatus { Text(status).font(.caption) }
      HStack {
        Button("Undo") { model.history.undo() }.disabled(!model.history.canUndo)
        Button("Redo") { model.history.redo() }.disabled(!model.history.canRedo)
        ClipboardHistoryPauseMenu(history: model.history)
      }
      .buttonStyle(AniCeButtonStyle(quiet: true, compact: true))
    }
    .confirmationDialog("Clear clipboard history?", isPresented: $clearing) {
      Button("Clear unpinned", role: .destructive) { model.history.clear() }
      if filter == .pinned {
        Button("Delete pinned clips", role: .destructive) {
          model.history.delete(Set(model.history.entries.filter(\.pinned).map(\.id)), fromPinned: true)
        }
      }
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
    Group {
      Button { model.copyHistory(entry) } label: { Label("Copy", systemImage: "doc.on.doc") }
      Button { model.togglePin(entry) } label: {
        Label(entry.pinned ? "Unpin" : "Pin", systemImage: entry.pinned ? "pin.fill" : "pin")
      }
      Button { model.sendHistory(entry) } label: { Label("Send", systemImage: "paperplane") }
        .disabled(model.busy || model.selected.map(model.supports) != true)
      Button(role: .destructive) { model.history.delete(entry.id, fromPinned: filter == .pinned) } label: { Label("Delete", systemImage: "trash") }
    }
    .buttonStyle(AniCeHoverButtonStyle(feedbackPadding: 3))
  }
}
