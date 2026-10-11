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
  var compact = false
  var focusedPeer: String?
  var discovery: MacDiscoveryModel?
  var canDiscover = true
  var automaticEnabled = true
  var onManageDevices: () -> Void
  var onOpenDevice: (String) -> Void = { _ in }
  var onChoosePhone: () -> Void = {}
  var onOpenDiagnostics: () -> Void = {}
  @Environment(\.colorScheme) private var scheme
  private var androidPeers: [PeerTrustRecord] { peers.filter { $0.peer.platform == "android" } }
  private var device: DeviceIdentity? {
    androidPeers.first { $0.peer.deviceId == focusedPeer }?.peer ?? model.authenticatedPeer ?? lan.authenticatedPeer ?? model.selectedPeer
      ?? (androidPeers.count == 1 ? androidPeers.first?.peer : nil)
  }
  private var ownsBluetooth: Bool {
    guard let device else { return true }
    let current = model.authenticatedPeer ?? model.selectedPeer
    return current.map { $0.deviceId == device.deviceId && $0.fingerprint == device.fingerprint } ?? true
  }
  private var ownsLan: Bool {
    guard let current = lan.authenticatedPeer, let device else { return true }
    return current.deviceId == device.deviceId && current.fingerprint == device.fingerprint
  }
  private var peerAvailable: Bool {
    (!(model.allowing || model.automatic) || ownsBluetooth) && (!lan.allowing || ownsLan)
  }
  private var presentation: ConnectionPresentation {
    ConnectionPresentation(bluetooth: ownsBluetooth ? model.state : "Disconnected", lan: ownsLan ? lan.state : "Disconnected",
      bluetoothAllowing: ownsBluetooth && model.allowing, lanAllowing: ownsLan && lan.allowing,
      automatic: ownsBluetooth && model.automatic)
  }

  var body: some View {
    Group {
      if compact { compactOverview } else if companion {
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
              .preferredColorScheme(scheme)
              .foregroundStyle(AniCePalette.primaryText(scheme))
              .background(AniCePalette.surface(scheme))
              .tint(AniCePalette.primaryText(scheme))
          }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var compactOverview: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(androidPeers) { record in
        let peer = record.peer
        let bluetoothPeer = model.authenticatedPeer ?? model.selectedPeer
        let ownsBluetooth = bluetoothPeer?.deviceId == peer.deviceId && bluetoothPeer?.fingerprint == peer.fingerprint ||
          (bluetoothPeer == nil && androidPeers.count == 1)
        let ownsLan = lan.authenticatedPeer?.deviceId == peer.deviceId && lan.authenticatedPeer?.fingerprint == peer.fingerprint
        let state = ConnectionPresentation(bluetooth: ownsBluetooth ? model.state : "Disconnected",
          lan: ownsLan ? lan.state : "Disconnected", bluetoothAllowing: ownsBluetooth && model.allowing,
          lanAllowing: ownsLan && lan.allowing, automatic: ownsBluetooth && model.automatic)
        let occupied = model.allowing || lan.allowing || model.automatic
        HStack(spacing: 12) {
          Button { onOpenDevice(peer.deviceId) } label: {
            VStack(alignment: .leading, spacing: 3) {
              Text(peer.deviceName).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
              Text(state.summary).font(.caption)
                .foregroundStyle(state.connected ? AniCePalette.success(scheme) : AniCePalette.secondaryText(scheme))
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel("Open Devices for " + peer.deviceName)
            .accessibilityValue(state.summary)
          Button(state.action.rawValue) {
            switch state.action {
            case .disconnect, .stop: model.disconnect(); lan.disconnect()
            case .allow, .retry: model.selectedPeer = peer; model.allow()
            }
          }.buttonStyle(.bordered).controlSize(.small)
            .disabled(occupied && !ownsBluetooth && !ownsLan)
          Button { onOpenDevice(peer.deviceId) } label: { Image(systemName: "chevron.right") }
            .buttonStyle(.borderless).accessibilityLabel("Open Devices for " + peer.deviceName)
        }
      }
      if lan.allowing && lan.authenticatedPeer == nil {
        Text("Local network · " + lan.state).font(.caption)
        Button("Stop allowing local network", action: lan.disconnect).buttonStyle(.bordered)
      }
      if model.allowing && model.selectedPeer == nil && model.authenticatedPeer == nil && androidPeers.count > 1 {
        Text(presentation.summary + " · Any trusted phone").font(.caption)
        Button("Cancel") { model.disconnect(); lan.disconnect() }.buttonStyle(.bordered)
      }
    }
  }

  private var overview: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(device?.deviceName ?? "Any trusted phone")
        .font(.headline).fixedSize(horizontal: false, vertical: true)
      Text(presentation.summary + (device.map { " · " + $0.fingerprint.prefix(8) } ?? ""))
        .font(.subheadline.weight(.medium))
        .foregroundStyle(presentation.connected ? AniCePalette.success(scheme) : AniCePalette.secondaryText(scheme))
      Toggle("Connect automatically", isOn: Binding(
        get: { ownsBluetooth && model.automatic }, set: { model.selectedPeer = device; model.setAutomatic($0) }))
        .tint(AniCePalette.accent(scheme))
        .disabled(androidPeers.isEmpty || !automaticEnabled || !peerAvailable)
      if ownsBluetooth, model.state != "Secured", !model.status.isEmpty,
        model.allowing || !presentation.connected || model.state == "Failed" {
        Text("Bluetooth: " + model.status).font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
      }
      if ownsLan, lan.state != "Secured", !lan.status.isEmpty, lan.allowing || lan.state == "Failed" {
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
        case .allow, .retry: model.selectedPeer = device; model.allow()
        }
      }.buttonStyle(.bordered).disabled(!peerAvailable)
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
      Text("Bluetooth · " + (ownsBluetooth ? (model.state == "Secured" ? "Connected" : model.state) : "Connected to another phone")).font(.subheadline.weight(.medium))
      Text(ownsBluetooth ? model.status : "Open the connected phone to manage its Bluetooth session.").font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
      if model.allowing {
        Button(model.state == "Secured" ? "Disconnect Bluetooth" : "Stop allowing Bluetooth", action: model.disconnect).disabled(!ownsBluetooth)
      } else { Button("Allow Bluetooth connections") { model.selectedPeer = device; model.allow() }.disabled(!peerAvailable) }
      Divider()
      Text("Local network · " + (ownsLan ? (lan.state == "Secured" ? "Connected" : lan.state) : "Connected to another phone")).font(.subheadline.weight(.medium))
      Text(ownsLan ? lan.status : "Open the connected phone to manage its local-network session.").font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
      if lan.allowing {
        Button(lan.state == "Secured" ? "Disconnect local network" : "Stop allowing local network", action: lan.disconnect).disabled(!ownsLan)
      } else {
        Button("Allow local-network connections") { lan.allow(selected: device, bluetooth: model) }
        .disabled(!peerAvailable)
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
            Text("Bluetooth checks received: \(ownsBluetooth ? model.receivedChecks : 0)")
            if ownsBluetooth && model.state == "Secured" { Button("Send Bluetooth check", action: model.checkConnection) }
            Text("Local-network checks received: \(ownsLan ? lan.receivedChecks : 0)")
            if ownsLan && lan.state == "Secured" { Button("Send local-network check", action: lan.checkConnection) }
            if let discovery {
              Text("Nearby discovery compatibility check").font(.subheadline.weight(.medium))
              if !canDiscover { Text("Stop Bluetooth admission or pairing before checking discovery.").font(.caption) }
              MacDiscoveryView(model: discovery).disabled(!canDiscover)
            } else { Button("Check nearby discovery…", action: onOpenDiagnostics) }
          }.padding(.top, 8)
        }
      }
      if peerAvailable && (model.allowing || lan.allowing || model.automatic) {
        Button("Disconnect all") { model.disconnect(); lan.disconnect() }
      }
    }
    .buttonStyle(.bordered)
  }
}
