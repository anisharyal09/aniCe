// SPDX-License-Identifier: GPL-3.0-or-later
// Presents shared Bluetooth and LAN status with transport-specific connection controls.
import SwiftUI

struct MacSessionView: View {
  let peers: [PeerTrustRecord]
  @Bindable var model: MacSessionModel
  @Bindable var lan: MacLanSessionModel
  @State private var details = false
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
        if model.allowing, !model.automatic, model.state != "Secured", model.remaining > 0 {
          TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text("\(model.remaining)s").font(.caption.monospacedDigit())
          }
        }
      }
      Toggle("Connect automatically", isOn: Binding(
        get: { model.automatic }, set: { model.setAutomatic($0) }))
        .disabled(androidPeers.isEmpty)
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
        .disabled(model.allowing || lan.allowing)
      }
      if lan.allowing {
        Text("Local network: \(lan.state)").font(.subheadline)
          .foregroundStyle(lan.state == "Secured" ? AniCePalette.success(scheme) : AniCePalette.secondaryText(scheme))
      }
      Button("Connection details…") { details = true }
        .sheet(isPresented: $details) {
          VStack(alignment: .leading, spacing: 12) {
            Text("Connection details").font(.headline)
            Text("Bluetooth · \(model.state)")
            Text(model.status).foregroundStyle(AniCePalette.secondaryText(scheme))
            Text("Checks received: \(model.receivedChecks)")
            if model.allowing {
              Button("Disconnect Bluetooth", action: model.disconnect)
              if model.state == "Secured" { Button("Send Bluetooth check", action: model.checkConnection) }
            } else { Button("Allow Bluetooth connections", action: model.allow) }
            Divider()
            Text("Local network · \(lan.state)")
            Text(lan.status).foregroundStyle(AniCePalette.secondaryText(scheme))
            Text("Checks received: \(lan.receivedChecks)")
            if lan.allowing {
              Button("Disconnect local network", action: lan.disconnect)
              if lan.state == "Secured" { Button("Send local-network check", action: lan.checkConnection) }
            } else {
              Button("Allow local-network connections") { lan.allow(selected: model.selectedPeer, bluetooth: model) }
            }
            if model.allowing || lan.allowing { Button("Disconnect all") { model.disconnect(); lan.disconnect() } }
            Button("Done") { details = false }.keyboardShortcut(.cancelAction)
          }.padding(24).frame(minWidth: 320)
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
          action: { model.disconnect(); lan.disconnect() }
        ).buttonStyle(.bordered)
        if model.state == "Secured" {
          Button("Send connection check", action: model.checkConnection).buttonStyle(.bordered)
        }
      } else if !model.automatic {
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
