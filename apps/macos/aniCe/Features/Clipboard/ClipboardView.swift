// SPDX-License-Identifier: GPL-3.0-or-later
// Presents peer-scoped clipboard consent and explicit sharing with an optional native paste field.
import AppKit
import SwiftUI

struct ClipboardSettingsView: View {
  let model: MacClipboardModel
  let peers: [PeerTrustRecord]
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if peers.isEmpty { Text("Pair a device to share your clipboard.").foregroundStyle(.secondary) }
      else if peers.count > 1 {
        Picker("Device", selection: Binding(get: { model.selected.map { $0.deviceId + ":" + $0.fingerprint } ?? "" }, set: { value in
          model.select(peers.first { $0.peer.deviceId + ":" + $0.peer.fingerprint == value }?.peer)
        })) {
          ForEach(peers) { record in Text(record.peer.deviceName).tag(record.peer.deviceId + ":" + record.peer.fingerprint) }
        }
      } else if let peer = peers.first { Text(peer.peer.deviceName).font(.headline) }
      Toggle("Automatic clipboard sharing", isOn: Binding(get: { model.automatic }, set: { model.setAutomatic($0) })).disabled(model.selected == nil)
      Text("Enable on both devices. Android shares when aniCe has focus. Incoming text replaces the clipboard, including while the phone is in the background.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if model.automatic && !model.automaticAccessAllowed {
        Text("Automatic reading needs pasteboard access. You can paste text into the Clipboard panel instead.").font(.caption).foregroundStyle(.secondary)
        Button("Pasteboard settings") {
          if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") { NSWorkspace.shared.open(url) }
        }
      }
    }
    .onAppear { model.prune(peers.map(\.peer)); if model.selected == nil { model.select(peers.first?.peer) }; model.refreshAccess() }
    .onChange(of: peers.map { $0.peer.deviceId + ":" + $0.peer.fingerprint }) { _, _ in model.prune(peers.map(\.peer)); if model.selected == nil { model.select(peers.first?.peer) } }
  }
}
struct ClipboardView: View {
  let model: MacClipboardModel
  let peers: [PeerTrustRecord]
  @State private var reveal = false
  @State private var pasted = ""
  @State private var confirming = false
  @State private var sensitiveSample: ClipboardSample?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ClipboardSettingsView(model: model, peers: peers)
      Divider()
      if let peer = model.selected, !model.supports(peer) { Text(model.connected(peer) ? "Clipboard unavailable on this device" : "Connect first").font(.callout) }
      Text(model.status).font(.caption).foregroundStyle(.secondary)
      if let sample = model.preview {
        Text("\(sample.text.utf8.count) bytes · \(sample.sensitive ? "Sensitive text" : "Plain text")").font(.caption)
        if reveal { Text(sample.text).textSelection(.enabled).accessibilityHidden(true) }
        else { Button("Reveal text") { reveal = true } }
      }
      HStack {
        Button("Inspect clipboard") { model.inspect() }.disabled(model.busy)
        Button("Send to \(model.selected?.deviceName ?? "device")") { model.send(); sensitiveSample = model.preview?.sensitive == true ? model.preview : nil; confirming = sensitiveSample != nil }
          .disabled(model.busy || model.selected.map(model.supports) != true)
      }.buttonStyle(.bordered)
      TextField("Or paste text here", text: $pasted, axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder)
        .onChange(of: pasted) { _, value in if value.utf8.count > 65536 { pasted = "" } }
      if !pasted.isEmpty {
        Button("Send pasted text") { model.send(pasted: pasted); pasted = "" }
          .disabled(model.busy || model.selected.map(model.supports) != true)
      }
      if model.busy { Button("Cancel send") { model.cancel() } }
    }
    .alert("Send sensitive text?", isPresented: $confirming) {
      Button("Send") { if let sensitiveSample { model.sendConfirmed(sensitiveSample) }; sensitiveSample = nil }
      Button("Cancel", role: .cancel) { model.clearPreview() }
    } message: { Text("This clipboard is marked sensitive. Send it to \(model.selected?.deviceName ?? "the selected device")?") }
    .onChange(of: model.preview?.text) { _, _ in reveal = false }
    .onChange(of: model.selected.map { $0.deviceId + ":" + $0.fingerprint }) { _, _ in pasted = ""; reveal = false }
    .onChange(of: model.selected.map(model.supports)) { _, supported in if supported != true { pasted = ""; sensitiveSample = nil; confirming = false; reveal = false } }
    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in pasted = ""; sensitiveSample = nil; confirming = false; reveal = false; model.clearPreview() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshAccess() }
    .onDisappear { pasted = ""; reveal = false; model.clearPreview() }
  }
}
