// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct MacSessionView: View {
  let peers: [PeerTrustRecord]
  @Bindable var model: MacSessionModel
  @Environment(\.colorScheme) private var scheme
  private var androidPeers: [PeerTrustRecord] { peers.filter { $0.peer.platform == "android" } }
  private var stateColor: Color {
    switch model.state {
    case "Secured": AniCePalette.success(scheme)
    case "Failed": AniCePalette.error(scheme)
    default: AniCePalette.secondaryText(scheme)
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Trusted-device connection").font(.headline)
        Spacer()
        if model.allowing, model.state != "Secured", model.remaining > 0 {
          Text("\(model.remaining)s").font(.caption.monospacedDigit())
        }
      }
      // A single phone needs no selector. Cached presentation records never gate admission.
      if androidPeers.count > 1 || model.selectedPeer != nil {
        Menu(model.selectedPeer.map { "Allow: \($0.deviceName)" } ?? "Choose allowed phone…") {
          Button("Any trusted phone") { model.selectedPeer = nil }
          ForEach(androidPeers) { record in
            Button("\(record.peer.deviceName) · \(record.peer.fingerprint.prefix(8))") {
              model.selectedPeer = record.peer
            }
          }
        }
        .disabled(model.allowing)
      }
      // Secured feedback already names the state; render it once on both Mac surfaces.
      Text(model.state == "Secured" && !model.status.isEmpty ? model.status : model.state)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(stateColor)
      if model.state != "Secured" && !model.status.isEmpty {
        Text(model.status).font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
      }
      if model.allowing {
        Button(
          model.state == "Secured" ? "Disconnect" : "Stop allowing connections",
          action: model.disconnect
        ).buttonStyle(.bordered)
        if model.state == "Secured" {
          Button("Send connection check", action: model.checkConnection).buttonStyle(.bordered)
        }
      } else {
        Button(
          model.state == "Failed" ? "Retry allowing connections" : "Allow connections",
          action: model.allow
        ).buttonStyle(.borderedProminent)
          .foregroundStyle(AniCePalette.onAccent(scheme))

      }
    }
    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
    .background(AniCePalette.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
  }
}
