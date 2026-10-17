// SPDX-License-Identifier: GPL-3.0-or-later
// Composes the device overview, nested management and settings through application-scoped owners.
import SwiftUI
import AppKit

extension MainWindowView {
  @ViewBuilder var homeContent: some View {
GeometryReader { geometry in
ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              if pairing.active {
                Text(pairing.status)
                Button("Review pairing") { navigation.show(.devices, route: .pairing) }
              }
              if pairing.hasTrustedAndroid {
                MacSessionView(peers: pairing.peers, model: session, lan: lan,
                  details: $navigation.details, diagnostics: $navigation.diagnostics, workspaceHeader: true,
                  focusedPeer: navigation.focusedPeer, discovery: discovery,
                  canDiscover: !pairing.active && !session.allowing, automaticEnabled: !pairing.active,
                  onManageDevices: { navigation.show(.devices) })
              } else {
                Text("No devices paired yet").font(.headline)
                Button("Pair a device") { navigation.show(.devices, route: .pairing) }.buttonStyle(.bordered)
              }
              if playback.showOnMac && playback.compactVisible {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: geometry.size.width >= 720 && (pairing.hasTrustedAndroid || transfer.state != .idle) ? 2 : 1), alignment: .leading, spacing: 20) {
                  MediaView(model: playback, visible: playback.mainVisible, open: { navigation.openFeature(.playback) })
                  if pairing.hasTrustedAndroid || transfer.state != .idle { TransferView(model: transfer, open: { navigation.openFeature(.files) }) }
                }
              } else if pairing.hasTrustedAndroid || transfer.state != .idle {
                TransferView(model: transfer, open: { navigation.openFeature(.files) })
              }

            }.frame(maxWidth: .infinity, alignment: .leading).padding(32)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
    }
  }
  @ViewBuilder var devicesContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if navigation.deviceRoute == .pairing || !pairing.hasTrustedAndroid {
          if pairing.hasTrustedAndroid {
            Button { navigation.show(.devices) } label: { Label("Devices", systemImage: "chevron.backward") }
          }
          Toggle("Connect automatically after pairing", isOn: Binding(
            get: { navigation.automaticAfterPairing && navigation.automaticLanAfterPairing },
            set: { navigation.automaticAfterPairing = $0; navigation.automaticLanAfterPairing = $0 }))
            .tint(AniCePalette.accent(colorScheme)).disabled(pairing.phase == "paired")
          Text("Uses Bluetooth, and Wi-Fi when both devices are on the same network.")
            .font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
          MacPairingView(model: pairing)
        } else {
          HStack {
            Text("Devices").font(.title2.weight(.semibold))
            Spacer()
            Button("Add device") { navigation.show(.devices, route: .pairing) }.buttonStyle(.bordered)
          }
          let phones = pairing.peers.filter { $0.peer.platform == "android" }
          let primary = ConnectionPresentation.primaryPeers(phones) { record in
            let bluetooth = session.authenticatedPeer ?? session.selectedPeer
            return (session.state == "Secured" && bluetooth?.deviceId == record.peer.deviceId && bluetooth?.fingerprint == record.peer.fingerprint)
              || (lan.state == "Secured" && lan.authenticatedPeer?.deviceId == record.peer.deviceId && lan.authenticatedPeer?.fingerprint == record.peer.fingerprint)
          }
          ForEach(primary) { record in
            MacSessionView(peers: pairing.peers, model: session, lan: lan,
              details: Binding(get: { navigation.details && navigation.focusedPeer == record.peer.deviceId },
                set: { navigation.focusedPeer = record.peer.deviceId; navigation.details = $0 }),
              diagnostics: $navigation.diagnostics, focusedPeer: record.peer.deviceId, discovery: discovery,
              canDiscover: !pairing.active && !session.allowing, automaticEnabled: !pairing.active,
              onManageDevices: { navigation.show(.devices, route: .pairing) })
          }
          DisclosureGroup("Trust and saved devices") {
            MacPairingView(model: pairing, showPairingControls: false)
          }.font(.callout)
        }
        Divider()
        Button {
          navigation.settingsRoute = .identity
          navigation.show(.settings)
        } label: {
          HStack(spacing: 10) {
            Label("This device", systemImage: "desktopcomputer")
            Spacer()
            Text(identity.local?.identity.deviceName ?? "This Mac").foregroundStyle(AniCePalette.secondaryText(colorScheme))
            Image(systemName: "chevron.right").accessibilityHidden(true)
          }.padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain)
      }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  var aboutContent: some View {
    ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              Text("aniCe").font(.title2.weight(.semibold))
              if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                let channel = Bundle.main.object(forInfoDictionaryKey: "AniCeReleaseChannel") as? String ?? ""
                Text("Version " + version + (channel.isEmpty ? "" : "-" + channel)).font(.callout)
              }
              Text("Connect your Mac and Android.").font(.callout)
              HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Made by")
                Link("@anisharyal09", destination: URL(string: "https://anisharyal09.com.np/")!)
              }
              Link("Source code", destination: URL(string: "https://github.com/anisharyal09/aniCe")!)
              Link("License · GPL-3.0-or-later", destination: URL(string: "https://github.com/anisharyal09/aniCe/blob/main/LICENSE")!)
              Link(destination: URL(string: "https://anisharyal09.com.np/support?from=anice")!) {
                Image(systemName: "heart")
                  .foregroundStyle(AniCePalette.secondaryText(colorScheme).opacity(0.8))
                  .frame(width: 32, height: 32)
                  .frame(maxWidth: .infinity)
              }.buttonStyle(.plain).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                .accessibilityLabel("Support aniCe").help("Support aniCe")
              Spacer()
            }.padding(24).frame(maxWidth: 680, alignment: .leading)
              .frame(maxWidth: .infinity, alignment: .leading)

    }
  }
  @ViewBuilder var settingsContent: some View {
if navigation.settingsRoute == .identity {
            IdentityView(model: identity, embedded: true, onBack: { navigation.settingsRoute = .overview })
          } else if navigation.settingsRoute == .about {
            aboutContent
          } else {
            ScrollView {
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text("Window appearance")
                Spacer()
                Picker("Window appearance", selection: Binding(get: { WindowAppearance.stored(appearance).rawValue }, set: { appearance = $0 })) {
                  ForEach(WindowAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }.labelsHidden().pickerStyle(.menu).frame(width: 130)
              }.padding(.horizontal, 24).padding(.top, 20)
              Text("The menu-bar companion follows macOS appearance.")
                .font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme)).padding(.horizontal, 24)
              Divider().padding(.vertical, 12)
              Toggle("Use local network automatically", isOn: Binding(get: { lan.automatic }, set: { lan.setAutomatic($0) }))
                .padding(.horizontal, 24)
              Text("Uses Bluetooth, and Wi-Fi when both devices are on the same network. Enable this on both devices.")
                .font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme)).padding(.horizontal, 24)
              Divider().padding(.vertical, 12)
              Toggle("Show Now Playing on this Mac",isOn:Binding(get:{playback.showOnMac},set:{playback.setShowOnMac($0)}))
                .padding(.horizontal,24)
              Text("Show local playback in the workspace and menu-bar companion.")
                .font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme)).padding(.horizontal,24)
              Divider().padding(.vertical,12)
              Button { navigation.settingsRoute = .identity } label: {
                HStack(spacing: 12) {
                  Image(systemName: "desktopcomputer").accessibilityHidden(true)
                  VStack(alignment: .leading, spacing: 4) {
                    Text("This device")
                    if let local = identity.local {
                      Text(local.identity.deviceName).font(.callout)
                        .foregroundStyle(AniCePalette.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                  }
                  Spacer()
                  Image(systemName: "chevron.right").accessibilityHidden(true)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
              }.buttonStyle(.plain)
                .background(AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
              Spacer()
            }.frame(maxWidth: 680, alignment: .leading)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
  }
}
