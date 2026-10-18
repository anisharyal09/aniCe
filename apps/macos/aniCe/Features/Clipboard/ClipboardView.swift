// SPDX-License-Identifier: GPL-3.0-or-later
// Presents native clipboard sharing and optional device-local text history.
import AppKit
import SwiftUI

struct ClipboardSettingsView: View {
  let model: MacClipboardModel
  let peers: [PeerTrustRecord]
  var showHistory = true
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if peers.isEmpty { Text("Pair a device to share your clipboard.").foregroundStyle(.secondary) }
      else if peers.count > 1 {
        Picker("Device", selection: Binding(get: { model.selected.map { $0.deviceId + ":" + $0.fingerprint } ?? "" }, set: { value in
          model.select(peers.first { $0.peer.deviceId + ":" + $0.peer.fingerprint == value }?.peer)
        })) { ForEach(peers) { record in Text(record.peer.deviceName).tag(record.peer.deviceId + ":" + record.peer.fingerprint) } }
      } else if let peer = peers.first { Text(peer.peer.deviceName).font(.headline) }
      Toggle("Automatic clipboard sharing", isOn: Binding(get: { model.automatic }, set: { model.setAutomatic($0) })).disabled(model.selected == nil)
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
    Toggle("Keep clipboard history", isOn: Binding(get: { history.enabled }, set: { if $0 { confirming = true } else { history.setEnabled(false) } }))
      .alert("Keep clipboard history?", isPresented: $confirming) {
        Button("Enable") { history.setEnabled(true) }; Button("Cancel", role: .cancel) {}
      } message: { Text("Save the latest 20 text items on this Mac across restarts. Recognized sensitive text is excluded. Turning this off deletes saved history.") }
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
  @State private var confirming = false
  @State private var sensitiveSample: ClipboardSample?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Clipboard view", selection: $historyTab) { Text("Share").tag(false); Text("History").tag(true) }.pickerStyle(.segmented).labelsHidden()
      if historyTab { ClipboardHistoryView(model: model); ClipboardAccessGuidance(model: model) }
      else {
        ClipboardSettingsView(model: model, peers: peers, showHistory: false)
        let available = model.selected.map(model.supports) == true
        if let peer = model.selected, !available { Text(model.connected(peer) ? "Clipboard unavailable on this device" : "Connect first").font(.callout) }
        if model.status != "Ready to share text" && (available || model.busy) { Text(model.status).font(.caption).foregroundStyle(.secondary) }
        HStack {
          Button("Send clipboard") { model.send(); sensitiveSample = model.preview?.sensitive == true ? model.preview : nil; confirming = sensitiveSample != nil }.disabled(model.busy || !available)
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
          Text("Manual sharing works with automatic sharing off. From another Android app, use Share → Send to Mac for text or links, or select text and choose Send to Mac where offered. The Mac must already be connected.\n\nFor automatic sharing, enable it on both devices. Android shares copies while aniCe has focus; copy text and open aniCe. Incoming text replaces the receiving clipboard, including while the phone app is in the background. Optional history stays on each device.").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .alert("Send sensitive text?", isPresented: $confirming) {
      Button("Send") { if let sensitiveSample { model.sendConfirmed(sensitiveSample) }; sensitiveSample = nil }
      Button("Cancel", role: .cancel) { sensitiveSample = nil; model.clearPreview() }
    } message: { Text("This clipboard is marked sensitive. Send it to \(model.selected?.deviceName ?? "the selected device")?") }
    .onChange(of: model.preview?.text) { _, _ in reveal = false }
    .onChange(of: historyTab) { _, _ in clearContent() }
    .onChange(of: more) { _, value in if !value { clearContent() } }
    .onChange(of: model.selected.map { $0.deviceId + ":" + $0.fingerprint }) { _, _ in clearContent() }
    .onChange(of: model.selected.map(model.supports)) { _, supported in if supported != true { clearContent() } }
    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in clearContent() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshAccess() }
    .onDisappear { clearContent() }
  }
  private func clearContent() { pasted = ""; reveal = false; sensitiveSample = nil; confirming = false; model.clearPreview() }
}
private struct ClipboardHistoryView: View {
  let model: MacClipboardModel
  @State private var clearing = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HistoryPreference(history: model.history)
      if model.status != "Ready to share text" { Text(model.status).font(.caption).foregroundStyle(.secondary) }
      if model.busy { Button("Cancel send") { model.cancel() } }
      if model.history.entries.isEmpty { Text(model.history.enabled ? "No clipboard history yet" : "Enable history to keep text on this Mac").foregroundStyle(.secondary) }
      else {
        Button("Clear all") { clearing = true }
        ForEach(model.history.entries) { entry in
          VStack(alignment: .leading, spacing: 4) {
            Text(String(entry.text.prefix(240))).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack { Text(entry.origin == "mac" ? "From Mac" : "From phone"); Text(entry.timestamp, format: .dateTime.month().day().hour().minute()) }.font(.caption).foregroundStyle(.secondary)
            HStack {
              Button("Copy") { model.copyHistory(entry) }
              Button("Send") { model.sendHistory(entry) }.disabled(model.busy || model.selected.map(model.supports) != true)
              Button("Delete", role: .destructive) { model.history.delete(entry.id) }
            }
          }
          Divider()
        }
      }
      if model.history.error != nil && model.history.entries.isEmpty { Button("Clear history") { model.history.clear() } }
    }
    .confirmationDialog("Clear clipboard history?", isPresented: $clearing) { Button("Clear all", role: .destructive) { model.history.clear() }; Button("Cancel", role: .cancel) {} } message: { Text("Delete all saved text on this Mac.") }
  }
}
