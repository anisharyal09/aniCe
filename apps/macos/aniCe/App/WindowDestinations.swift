// SPDX-License-Identifier: GPL-3.0-or-later
// Composes Home, Devices and Settings content from existing application owners and navigation.
import SwiftUI

extension MainWindowView {
  @ViewBuilder var homeContent: some View {
ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              if pairing.active {
                Text(pairing.status)
                Button("Review pairing") { navigation.show(.devices, route: .pairing) }
              }
              if pairing.hasTrustedAndroid {
                MacSessionView(peers: pairing.peers, model: session, lan: lan,
                  details: $navigation.details, diagnostics: $navigation.diagnostics,
                  compact: true, onManageDevices: { navigation.show(.devices) },
                  onOpenDevice: { peer in navigation.show(.devices, peer: peer) })
              } else {
                Text("No devices paired yet").font(.headline)
                Button("Pair a device") { navigation.show(.devices, route: .pairing) }.buttonStyle(.bordered)
              }
              if playback.showOnMac && playback.compactVisible { MediaView(model:playback,compact:true,visible:playback.mainVisible) { navigation.show(.features) } }
            }.frame(maxWidth: 760, alignment: .leading).padding(24)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
  }
  @ViewBuilder var devicesContent: some View {
ScrollView {
            VStack(alignment: .leading, spacing: 20) {
              if navigation.deviceRoute == .pairing || !pairing.hasTrustedAndroid {
                if pairing.hasTrustedAndroid {
                  Button { navigation.deviceRoute = .overview } label: { Label("Back", systemImage: "chevron.backward") }
                }
                Toggle("Connect automatically after pairing", isOn: $navigation.automaticAfterPairing)
                  .tint(AniCePalette.accent(colorScheme)).disabled(pairing.phase == "paired")
                MacPairingView(model: pairing)
              } else {
                if pairing.peers.filter({ $0.peer.platform == "android" }).count > 1 {
                  Picker("Device", selection: $navigation.focusedPeer) {
                    Text("Current device").tag(String?.none)
                    ForEach(pairing.peers.filter { $0.peer.platform == "android" }) { record in
                      Text(record.peer.deviceName).tag(Optional(record.peer.deviceId))
                    }
                  }
                }
                MacSessionView(peers: pairing.peers, model: session, lan: lan,
                  details: $navigation.details, diagnostics: $navigation.diagnostics,
                  focusedPeer: navigation.focusedPeer, discovery: discovery, canDiscover: !pairing.active && !session.allowing,
                  automaticEnabled: !pairing.active,
                  onManageDevices: { navigation.deviceRoute = .pairing })
                Button(pairing.active ? "Review pairing" : "Manage devices") { navigation.deviceRoute = .pairing }
                  .buttonStyle(.bordered)
              }
            }.frame(maxWidth: 760, alignment: .leading).padding(24)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
  }
  @ViewBuilder var settingsContent: some View {
if navigation.settingsRoute == .identity {
            IdentityView(model: identity, embedded: true, onBack: { navigation.settingsRoute = .overview })
          } else {
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
              Toggle("Show Now Playing on this Mac",isOn:Binding(get:{playback.showOnMac},set:{playback.setShowOnMac($0)}))
                .padding(.horizontal,24)
              Text("Show a local playback card in Home and the menu-bar companion.")
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
            }
          }
  }
}
