// SPDX-License-Identifier: GPL-3.0-or-later
// Projects independent transport readiness into shared device controls and explicit connection details.
import SwiftUI

struct ConnectionPresentation: Equatable {
  static func primaryPeers<T>(_ peers: [T], connected: (T) -> Bool) -> [T] {
    let ready = peers.filter(connected)
    return ready.isEmpty ? peers : ready
  }

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
  var workspaceHeader = false
  var companion = false
  var compact = false
  var focusedPeer: String?
  var discovery: MacDiscoveryModel?
  var canDiscover = true
  var automaticEnabled = true
  @State private var securityExpanded = false
  var onManageDevices: () -> Void
  var onOpenDevice: (String) -> Void = { _ in }
  var onChoosePhone: () -> Void = {}
  var onOpenDiagnostics: () -> Void = {}
  @Environment(\.colorScheme) private var scheme
  private var androidPeers: [PeerTrustRecord] { peers.filter { $0.peer.platform == "android" } }
  private var device: DeviceIdentity? {
    let peers = orderedAndroidPeers
    return peers.first { $0.peer.deviceId == focusedPeer }?.peer
      ?? peers.first { $0.peer == model.authenticatedPeer || $0.peer == lan.authenticatedPeer }?.peer
      ?? peers.first { $0.peer == model.selectedPeer }?.peer ?? peers.first?.peer
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
            Button("Back") { details = false }.buttonStyle(AniCeButtonStyle())
            detailContent
          }
        } else { overview }
      } else {
        Group { if workspaceHeader { workspaceSummary } else { overview } }
          .frame(maxWidth: .infinity, alignment: .leading)
          .sheet(isPresented: $details) {
            ScrollView {
              VStack(alignment: .leading, spacing: 16) {
                detailContent
                HStack {
                  Spacer()
                  if presentation.connected { Button("Disconnect") { model.disconnect(); lan.disconnect() }.buttonStyle(AniCeButtonStyle()) }
                  Button("Done") { details = false }.buttonStyle(AniCeButtonStyle(prominent: true)).keyboardShortcut(.cancelAction)
                }
              }.padding(24)
            }.frame(minWidth: 400, idealWidth: 460, maxHeight: 700)
              .preferredColorScheme(scheme)
              .foregroundStyle(AniCePalette.primaryText(scheme))
              .background(AniCePalette.surface(scheme))
              .tint(AniCePalette.primaryText(scheme))
          }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func isPeerConnected(_ record: PeerTrustRecord) -> Bool {
    let peer = record.peer
    let bluetoothPeer = model.authenticatedPeer ?? model.selectedPeer
    let ownsBluetooth = bluetoothPeer?.deviceId == peer.deviceId && bluetoothPeer?.fingerprint == peer.fingerprint ||
      (bluetoothPeer == nil && androidPeers.count == 1)
    let ownsLan = lan.authenticatedPeer?.deviceId == peer.deviceId && lan.authenticatedPeer?.fingerprint == peer.fingerprint
    let state = ConnectionPresentation(bluetooth: ownsBluetooth ? model.state : "Disconnected",
      lan: ownsLan ? lan.state : "Disconnected", bluetoothAllowing: ownsBluetooth && model.allowing,
      lanAllowing: ownsLan && lan.allowing, automatic: ownsBluetooth && model.automatic)
    return state.connected
  }

  // In compact overview, show only connected peers when any peer is connected,
  // avoiding menu-bar clutter from disconnected paired devices.
  private var orderedAndroidPeers: [PeerTrustRecord] {
    ConnectionPresentation.primaryPeers(androidPeers, connected: isPeerConnected)
  }

  private var compactOverview: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(orderedAndroidPeers) { record in
        let peer = record.peer
        let bluetoothPeer = model.authenticatedPeer ?? model.selectedPeer
        let ownsBluetooth = bluetoothPeer?.deviceId == peer.deviceId && bluetoothPeer?.fingerprint == peer.fingerprint ||
          (bluetoothPeer == nil && androidPeers.count == 1)
        let ownsLan = lan.authenticatedPeer?.deviceId == peer.deviceId && lan.authenticatedPeer?.fingerprint == peer.fingerprint
        let state = ConnectionPresentation(bluetooth: ownsBluetooth ? model.state : "Disconnected",
          lan: ownsLan ? lan.state : "Disconnected", bluetoothAllowing: ownsBluetooth && model.allowing,
          lanAllowing: ownsLan && lan.allowing, automatic: ownsBluetooth && model.automatic)
        let occupied = model.allowing || lan.allowing || model.automatic
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 12) {
            Button { onOpenDevice(peer.deviceId) } label: {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(peer.deviceName).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Text(state.connected ? "Connected" : state.summary).font(.caption)
                  .foregroundStyle(state.connected ? AniCePalette.success(scheme) : AniCePalette.secondaryText(scheme))
                  .fixedSize(horizontal: false, vertical: true)
              }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Device details for " + peer.deviceName)
              .accessibilityValue(state.summary)

            if !state.connected {
              Button(state.action.rawValue) {
                switch state.action {
                case .disconnect, .stop: model.disconnect(); lan.disconnect()
                case .allow, .retry: model.selectedPeer = peer; model.allow()
                }
              }.buttonStyle(AniCeButtonStyle()).controlSize(.small)
                .disabled(occupied && !ownsBluetooth && !ownsLan)
            }

            Button { onOpenDevice(peer.deviceId) } label: { Image(systemName: "chevron.right") }
              .buttonStyle(.borderless).accessibilityLabel("Device details for " + peer.deviceName)
          }
        }
      }
      if lan.allowing && lan.authenticatedPeer == nil {
        Text("Local network · " + lan.state).font(.caption)
        Button("Stop allowing local network", action: lan.disconnect).buttonStyle(AniCeButtonStyle())
      }
      if model.allowing && model.selectedPeer == nil && model.authenticatedPeer == nil && androidPeers.count > 1 {
        Text(presentation.summary + " · Any trusted phone").font(.caption)
        Button("Cancel") { model.disconnect(); lan.disconnect() }.buttonStyle(AniCeButtonStyle())
      }
    }
  }

  private var automaticControl: some View {
    Toggle("Auto connect", isOn: Binding(
      get: { ownsBluetooth && model.automatic },
      set: { model.selectedPeer = device; model.setAutomatic($0) }))
      .toggleStyle(.checkbox).tint(AniCePalette.accent(scheme))
      .disabled(androidPeers.isEmpty || !automaticEnabled || !peerAvailable)
  }

  private var workspaceSummary: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 16) {
        workspaceName
        Spacer(minLength: 8)
        workspaceActions
      }
      VStack(alignment: .leading, spacing: 12) {
        workspaceName
        HStack(spacing: 12) { workspaceActions }
      }
    }.padding(.bottom, 16).overlay(alignment: .bottom) { Divider() }
  }

  private var workspaceName: some View {
    Button { diagnostics = false; details = true } label: {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Image(systemName: "iphone").foregroundStyle(AniCePalette.secondaryText(scheme)).accessibilityHidden(true)
          Text(device?.deviceName ?? "Your phone").font(.system(size: 15, weight: .medium))
          Image(systemName: "chevron.forward").font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme)).accessibilityHidden(true)
        }
        .fixedSize(horizontal: false, vertical: true)
        Text(presentation.connected ? "Connected" : presentation.summary).font(.callout)
          .foregroundStyle(AniCePalette.secondaryText(scheme))
      }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel("Connection details for " + (device?.deviceName ?? "your phone"))
      .accessibilityValue(presentation.summary)
  }

  @ViewBuilder private var workspaceActions: some View {
    automaticControl
    Button(presentation.action.rawValue) {
      switch presentation.action {
      case .disconnect, .stop: model.disconnect(); lan.disconnect()
      case .allow, .retry: model.selectedPeer = device; model.allow()
      }
    }.buttonStyle(AniCeButtonStyle()).controlSize(.small).disabled(!peerAvailable)
    Menu {
      if lan.allowing {
        Button(lan.state == "Secured" ? "Disconnect LAN" : "Stop allowing LAN", action: lan.disconnect).disabled(!ownsLan)
      } else {
        Button("Allow LAN") { lan.allow(selected: device, bluetoothAllowing: model.allowing) }.disabled(!peerAvailable)
      }
      Button("Connection details") { diagnostics = false; details = true }
      Button("Devices", action: onManageDevices)
    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
      .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Connection options")
  }

  private var overview: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 16) {
        Image(systemName: "iphone").font(.system(size: 24)).foregroundStyle(AniCePalette.secondaryText(scheme)).accessibilityHidden(true)
        Button { diagnostics = false; details = true } label: {
          VStack(alignment: .leading, spacing: 6) {
            Text(device?.deviceName ?? "Any trusted phone").font(.system(size: 14, weight: .medium))
              .fixedSize(horizontal: false, vertical: true)
            Text(presentation.connected ? "Connected" : presentation.summary).font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Device details for " + (device?.deviceName ?? "your phone"))
        Button(presentation.action.rawValue) {
          switch presentation.action {
          case .disconnect, .stop: model.disconnect(); lan.disconnect()
          case .allow, .retry: model.selectedPeer = device; model.allow()
          }
        }.buttonStyle(AniCeButtonStyle()).disabled(!peerAvailable)
      }.padding(.vertical, 14)
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 16) {
          Button {
            model.selectedPeer = device; model.setAutomatic(!model.automatic)
          } label: {
            VStack(alignment: .leading, spacing: 7) {
              Text("Auto connect")
              Text("Reconnect when this device is available.").font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
          }.buttonStyle(.plain).disabled(androidPeers.isEmpty || !automaticEnabled || !peerAvailable)
          Toggle("Auto connect", isOn: Binding(get: { ownsBluetooth && model.automatic }, set: { model.selectedPeer = device; model.setAutomatic($0) }))
            .labelsHidden().toggleStyle(.checkbox).disabled(androidPeers.isEmpty || !automaticEnabled || !peerAvailable)
        }.padding(.vertical, 16)
        Divider()
        transportRow("Bluetooth", symbol: "antenna.radiowaves.left.and.right", state: ownsBluetooth ? model.state : "In use by another phone",
          active: ownsBluetooth && (model.allowing || model.state == "Secured"), enabled: peerAvailable,
          connect: { model.selectedPeer = device; model.allow() }, disconnect: model.disconnect)
        Divider()
        transportRow("Local network", symbol: "wifi", state: ownsLan ? lan.state : "In use by another phone",
          active: ownsLan && (lan.allowing || lan.state == "Secured"), enabled: peerAvailable,
          connect: { lan.allow(selected: device, bluetoothAllowing: model.allowing) }, disconnect: lan.disconnect)
        Divider()
        DisclosureGroup(isExpanded: $securityExpanded) {
          if let device {
            Text("Security fingerprint").font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
            Text(device.fingerprint).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          }
          diagnosticContent
        } label: { Text("Security and diagnostics") }.padding(.vertical, 14)
      }.overlay(alignment: .top) { Divider() }
      if ownsBluetooth && model.state == "Failed" { Text(model.status).font(.caption).foregroundStyle(AniCePalette.error(scheme)).padding(.vertical, 8) }
      if ownsLan && lan.state == "Failed" { Text(lan.status).font(.caption).foregroundStyle(AniCePalette.error(scheme)).padding(.vertical, 8) }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(AniCePalette.primaryText(scheme))
      .overlay(alignment: .bottom) { Divider() }
  }

  private func transportRow(_ name: String, symbol: String, state: String, active: Bool, enabled: Bool,
    connect: @escaping () -> Void, disconnect: @escaping () -> Void) -> some View {
    let action = Button(active ? (state == "Secured" ? "Disconnect" : "Cancel") : "Connect", action: active ? disconnect : connect)
      .buttonStyle(AniCeButtonStyle()).disabled(!active && !enabled)
    return ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        Label(name, systemImage: symbol).fixedSize(horizontal: true, vertical: false)
        Spacer(minLength: 8)
        Text(state).font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme)).fixedSize(horizontal: true, vertical: false)
        action.fixedSize()
      }
      VStack(alignment: .leading, spacing: 8) {
        Label(name, systemImage: symbol)
        HStack {
          Text(state).font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
          Spacer(minLength: 8)
          action
        }
      }
    }.padding(.vertical, 14)
  }

  private var detailContent: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(alignment: .top) {
        Text(device?.deviceName ?? "Connection details").font(.system(size: 20, weight: .medium))
        Spacer()
        Button { details = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close connection details")
      }
      HStack(spacing: 12) {
        Text(presentation.connected ? "Connected" : presentation.summary)
        if device != nil { Text("Trusted device") }
      }.font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
      VStack(spacing: 14) {
        HStack { Text("Bluetooth"); Spacer(); Text(ownsBluetooth ? model.state : "In use by another phone").foregroundStyle(AniCePalette.secondaryText(scheme)) }
        HStack { Text("Local network"); Spacer(); Text(ownsLan ? lan.state : "In use by another phone").foregroundStyle(AniCePalette.secondaryText(scheme)) }
      }.font(.callout)
      automaticControl
      if let device {
        VStack(alignment: .leading, spacing: 10) {
          Text("Security fingerprint").font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
          Text(device.fingerprint).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(AniCePalette.background(scheme), in: RoundedRectangle(cornerRadius: 8))
        }
      }
      Divider()
      DisclosureGroup("Diagnostics") { diagnosticContent }
    }
  }

  private var diagnosticContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      if companion {
        if androidPeers.count > 1 {
          Button("Choose allowed phone…", action: onChoosePhone).buttonStyle(AniCeButtonStyle())
        }
        Button("Manage devices", action: onManageDevices).buttonStyle(AniCeButtonStyle())
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
      if let device {
        DisclosureGroup("Security") {
          Text(device.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
        }
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
        Button("Allow local-network connections") { lan.allow(selected: device, bluetoothAllowing: model.allowing) }
        .disabled(!peerAvailable)
      }
      VStack(alignment: .leading, spacing: 0) {
        Button { diagnostics.toggle() } label: {
          HStack {
            Image(systemName: diagnostics ? "chevron.down" : "chevron.right")
            Text("Connection checks and discovery")
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
    .buttonStyle(AniCeButtonStyle())
  }
}
