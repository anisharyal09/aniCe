// SPDX-License-Identifier: GPL-3.0-or-later
// Presents peer-scoped Find Device actions and explicit local notification setup.
import AppKit
import SwiftUI

enum FindDevicePermissionPolicy: Equatable {
  case allowed
  case blocked
  case unknown
  case error
}

struct FindDeviceView: View {
  static func permissionPresentationPolicy(for statusKey: String) -> FindDevicePermissionPolicy {
    switch statusKey {
    case "find_local_allowed": return .allowed
    case "find_local_blocked": return .blocked
    case "find_local_error": return .error
    default: return .unknown
    }
  }

  let model: MacFindDeviceModel
  let peers: [PeerTrustRecord]
  var notifier: MacFindDeviceNotifier? = nil
  @State private var permissionKey = "find_local_unknown"
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if peers.isEmpty { Text("find_pair_first", tableName: "FindDevice").font(.callout).foregroundStyle(.secondary) }
      if let notifier {
        Text("find_explanation", tableName: "FindDevice").font(.callout)
        if Self.permissionPresentationPolicy(for: permissionKey) == .allowed {
          HStack(spacing: 8) {
            Text(MacFindDeviceNotifier.text("find_local_allowed")).font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Button(MacFindDeviceNotifier.text("find_settings")) {
              if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
            }.buttonStyle(.link).font(.caption)
          }
        } else {
          Button(MacFindDeviceNotifier.text("find_permission")) { Task { permissionKey = await notifier.requestPermission() } }.buttonStyle(.bordered)
          Text(MacFindDeviceNotifier.text(permissionKey)).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button(MacFindDeviceNotifier.text("find_settings")) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
          }.buttonStyle(.bordered)
        }
      }
      ForEach(ConnectionPresentation.primaryPeers(peers, connected: { model.connected($0.peer) })) { record in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(record.peer.deviceName).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(MacFindDeviceNotifier.text("find_title")) { model.find(record.peer) }
              .disabled(!model.canFind(record.peer)).buttonStyle(.bordered).fixedSize()
              .accessibilityLabel(String(format: MacFindDeviceNotifier.text("find_peer_action"), record.peer.deviceName))
          }
          if !model.supports(record.peer) {
            Text(MacFindDeviceNotifier.text(model.connected(record.peer) ? "find_not_advertised" : "find_connect_first"))
              .font(.caption).foregroundStyle(.secondary)
          } else if model.connected(record.peer) {
            Text(MacFindDeviceNotifier.text("find_connected")).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      if let peer = model.feedbackPeer, model.feedbackKey != "find_idle" {
        Text(peer.deviceName).font(.caption)
      }
      let showIdle = model.feedbackKey == "find_idle" && !peers.contains { model.connected($0.peer) }
      if showIdle || (model.feedbackKey != "find_idle" && !model.feedbackKey.isEmpty) {
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
