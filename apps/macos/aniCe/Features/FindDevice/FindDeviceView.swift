// SPDX-License-Identifier: GPL-3.0-or-later
// Presents peer-scoped Find Device actions and explicit local notification setup.
import AppKit
import SwiftUI

struct FindDeviceView: View {
  let model: MacFindDeviceModel
  let peers: [PeerTrustRecord]
  var notifier: MacFindDeviceNotifier? = nil
  @State private var permissionKey = "find_local_unknown"
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let notifier {
        Text("find_title", tableName: "FindDevice").font(.headline)
        Text("find_explanation", tableName: "FindDevice").font(.callout)
        Button(MacFindDeviceNotifier.text("find_permission")) { Task { permissionKey = await notifier.requestPermission() } }
        Text(MacFindDeviceNotifier.text(permissionKey)).font(.caption).foregroundStyle(.secondary)
        Button(MacFindDeviceNotifier.text("find_settings")) {
          if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
        }
      }
      ForEach(peers) { record in
        if model.supports(record.peer) {
          HStack {
            Text(record.peer.deviceName).lineLimit(2)
            Spacer()
            Button(MacFindDeviceNotifier.text("find_title")) { model.find(record.peer) }
              .disabled(!model.canFind(record.peer)).buttonStyle(.bordered)
          }
        }
      }
      if notifier != nil && !peers.contains(where: { model.supports($0.peer) }) {
        Text("find_unsupported", tableName: "FindDevice").font(.caption).foregroundStyle(.secondary)
      }
      if let peer = model.feedbackPeer, model.feedbackKey != "find_idle" {
        Text(peer.deviceName).font(.caption)
      }
      if notifier != nil || model.feedbackKey != "find_idle" {
        Text(MacFindDeviceNotifier.text(model.feedbackKey)).font(.caption)
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
    .task { if let notifier { permissionKey = await notifier.localStatus() } }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      if let notifier { Task { permissionKey = await notifier.localStatus() } }
    }
  }
}
