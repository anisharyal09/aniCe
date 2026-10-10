// SPDX-License-Identifier: GPL-3.0-or-later
// Projects independent transport readiness into shared device controls and explicit connection details.
import SwiftUI

struct ConnectionPresentation: Equatable {
  enum Action: String { case allow = "Connect", stop = "Cancel", retry = "Retry", disconnect = "Disconnect" }
  let summary: String
  let connected: Bool
  let action: Action

  init(bluetooth: String, lan: String, bluetoothAllowing: Bool, lanAllowing: Bool, automatic: Bool) {
    let secured = [("Bluetooth", bluetooth), ("Local network", lan)].filter { $0.1 == "Secured" }.map { $0.0 }
    connected = !secured.isEmpty
    if connected {
      summary = "Connected · " + secured.joined(separator: " + ")
      action = .disconnect
    } else if bluetoothAllowing || lanAllowing {
      summary = bluetooth == "Connecting" || lan == "Connecting" ? "Connecting" : "Waiting for phone"
      action = .stop
    } else if automatic {
      summary = "Waiting nearby"
      action = .stop
    } else if bluetooth == "Failed" || lan == "Failed" {
      summary = "Connection failed"
      action = .retry
    } else {
      summary = "Disconnected"
      action = .allow
    }
  }
}

struct MacSessionView: View {
  let peers: [PeerTrustRecord]
  @Bindable var model: MacSessionModel
  @Bindable var lan: MacLanSessionModel
  @Binding var details: Bool
  @Binding var diagnostics: Bool
  var companion = false
  var discovery: MacDiscoveryModel?
  var canDiscover = true
  var automaticEnabled = true
  var onManageDevices: () -> Void
  var onChoosePhone: () -> Void = {}
  var onOpenDiagnostics: () -> Void = {}
  @Environment(\.colorScheme) private var scheme
  private var androidPeers: [PeerTrustRecord] { peers.filter { $0.peer.platform == "android" } }
  private var device: DeviceIdentity? {
    model.authenticatedPeer ?? lan.authenticatedPeer ?? model.selectedPeer
      ?? (androidPeers.count == 1 ? androidPeers.first?.peer : nil)
  }
  private var presentation: ConnectionPresentation {
    ConnectionPresentation(bluetooth: model.state, lan: lan.state,
      bluetoothAllowing: model.allowing, lanAllowing: lan.allowing, automatic: model.automatic)
  }

  var body: some View {
    Group {
      if companion {
        if details {
          VStack(alignment: .leading, spacing: 16) {
            Button("Back") { details = false }.buttonStyle(.bordered)
            detailContent
          }
        } else { overview }
      } else {
        overview
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(20)
          .background(AniCePalette.surface(scheme), in: RoundedRectangle(cornerRadius: 12))
          .sheet(isPresented: $details) {
            ScrollView {
              VStack(alignment: .leading, spacing: 16) {
                detailContent
                Button("Done") { details = false }.keyboardShortcut(.cancelAction)
              }.padding(24)
            }.frame(minWidth: 340, idealWidth: 420, maxHeight: 560)
          }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var overview: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(device?.deviceName ?? "Any trusted phone")
        .font(.headline).fixedSize(horizontal: false, vertical: true)
      Text(presentation.summary + (device.map { " · " + $0.fingerprint.prefix(8) } ?? ""))
        .font(.subheadline.weight(.medium))
        .foregroundStyle(presentation.connected ? AniCePalette.success(scheme) : AniCePalette.secondaryText(scheme))
      Toggle("Connect automatically", isOn: Binding(
        get: { model.automatic }, set: { model.setAutomatic($0) }))
        .tint(AniCePalette.accent(scheme))
        .disabled(androidPeers.isEmpty || !automaticEnabled)
      if model.state != "Secured", !model.status.isEmpty,
        model.allowing || !presentation.connected || model.state == "Failed" {
        Text("Bluetooth: " + model.status).font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
      }
      if lan.state != "Secured", !lan.status.isEmpty, lan.allowing || lan.state == "Failed" {
        Text("Local network: " + lan.status).font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
      }
      if model.allowing, !model.automatic, model.state != "Secured", model.remaining > 0 {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
          Text("Allowing for \(model.remaining)s").font(.caption.monospacedDigit())
        }
      }
      Button(presentation.action.rawValue) {
        switch presentation.action {
        case .disconnect, .stop: model.disconnect(); lan.disconnect()
        case .allow, .retry: model.allow()
        }
      }.buttonStyle(.bordered)
      Button("Connection details") { diagnostics = false; details = true }.buttonStyle(.bordered)
    }
  }

  private var detailContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Connection details").font(.headline)
      Text(device?.deviceName ?? "Any trusted phone").fixedSize(horizontal: false, vertical: true)
      if companion {
        if androidPeers.count > 1 {
          Button("Choose allowed phone…", action: onChoosePhone).buttonStyle(.bordered)
        }
        Button("Manage devices", action: onManageDevices).buttonStyle(.bordered)
      } else if androidPeers.count > 1 || model.selectedPeer != nil {
        Picker("Allow", selection: Binding(
          get: { model.selectedPeer?.deviceId ?? "" },
          set: { id in model.selectedPeer = androidPeers.first { $0.peer.deviceId == id }?.peer }
        )) {
          Text("Any trusted phone").tag("")
          ForEach(androidPeers) { record in
            Text(record.peer.deviceName + " · " + record.peer.fingerprint.prefix(8)).tag(record.peer.deviceId)
          }
        }.disabled(model.allowing || lan.allowing)
      }
      Divider()
      Text("Bluetooth · " + (model.state == "Secured" ? "Connected" : model.state)).font(.subheadline.weight(.medium))
      Text(model.status).font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
      if model.allowing {
        Button(model.state == "Secured" ? "Disconnect Bluetooth" : "Stop allowing Bluetooth", action: model.disconnect)
      } else { Button("Allow Bluetooth connections", action: model.allow) }
      Divider()
      Text("Local network · " + (lan.state == "Secured" ? "Connected" : lan.state)).font(.subheadline.weight(.medium))
      Text(lan.status).font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
      if lan.allowing {
        Button(lan.state == "Secured" ? "Disconnect local network" : "Stop allowing local network", action: lan.disconnect)
      } else {
        Button("Allow local-network connections") { lan.allow(selected: model.selectedPeer, bluetooth: model) }
      }
      VStack(alignment: .leading, spacing: 0) {
        Button { diagnostics.toggle() } label: {
          HStack {
            Image(systemName: diagnostics ? "chevron.down" : "chevron.right")
            Text("Diagnostics")
            Spacer()
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(diagnostics ? "Expanded" : "Collapsed")
        if diagnostics {
          VStack(alignment: .leading, spacing: 12) {
            Text("Bluetooth checks received: \(model.receivedChecks)")
            if model.state == "Secured" { Button("Send Bluetooth check", action: model.checkConnection) }
            Text("Local-network checks received: \(lan.receivedChecks)")
            if lan.state == "Secured" { Button("Send local-network check", action: lan.checkConnection) }
            if let discovery {
              Text("Nearby discovery compatibility check").font(.subheadline.weight(.medium))
              if !canDiscover { Text("Stop Bluetooth admission or pairing before checking discovery.").font(.caption) }
              MacDiscoveryView(model: discovery).disabled(!canDiscover)
            } else { Button("Check nearby discovery…", action: onOpenDiagnostics) }
          }.padding(.top, 8)
        }
      }
      if model.allowing || lan.allowing || model.automatic {
        Button("Disconnect all") { model.disconnect(); lan.disconnect() }
      }
    }
    .buttonStyle(.bordered)
  }
}
