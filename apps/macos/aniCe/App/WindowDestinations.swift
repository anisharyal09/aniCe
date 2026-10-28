// SPDX-License-Identifier: GPL-3.0-or-later
// Composes the device overview, nested management and settings through application-scoped owners.
import SwiftUI
import AppKit

extension MainWindowView {
  @ViewBuilder var homeContent: some View {
    GeometryReader { geometry in
      let activityWidth = geometry.size.width - 56
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Text("Overview").font(.system(size: 20, weight: .medium))
          if pairing.hasTrustedAndroid {
            MacSessionView(peers: pairing.peers, model: session, lan: lan,
              details: $navigation.details, diagnostics: $navigation.diagnostics, workspaceHeader: true,
              focusedPeer: navigation.focusedPeer, discovery: discovery,
              canDiscover: !pairing.active && !session.allowing, automaticEnabled: !pairing.active,
              onManageDevices: { navigation.show(.devices) })
          } else {
            VStack(alignment: .leading, spacing: 12) {
              Text("Pair your Android phone").font(.title3.weight(.semibold))
              Text("Open aniCe on your phone, then scan a QR code or enter a six-digit code.")
                .font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
              Button("Pair a device") { navigation.show(.devices, route: .pairing) }.buttonStyle(AniCeButtonStyle())
            }
          }
          if transfer.pendingOffer != nil {
            TransferView(model: transfer, open: { navigation.openFeature(.files) })
          }
          if pairing.hasTrustedAndroid {
            HStack(spacing: 8) {
              Button { promptAndSendTransferFiles(model: transfer) } label: {
                Label("Send files…", systemImage: "arrow.up.doc")
              }.buttonStyle(AniCeButtonStyle()).controlSize(.small)
                .disabled(!transfer.peerConnected || !transfer.peerCompatible || transfer.preparing || transfer.state != .idle)
              ClipboardSendButton(model: clipboard)
            }
            if clipboard.status != "Ready to share text" && clipboard.status != "Confirm sending sensitive text" {
              Text(clipboard.status).font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
            }
          }
          let isResult: Bool = switch transfer.state {
          case .completed, .rejected, .failed, .cancelled: true
          default: false
          }
          homeActivities(isResult: isResult, availableWidth: activityWidth)
          if clipboard.recent != nil {
            Text("Recent").font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
            ClipboardActivityView(model: clipboard, compact: true, open: { navigation.openFeature(.clipboard) })
          }
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  @ViewBuilder private func homeActivities(isResult: Bool, availableWidth: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 24) {
      if availableWidth >= 720 {
        let showPlayback = playback.showOnMac && playback.compactVisible
        let showFileTransfer = transfer.pendingOffer == nil
        HStack(alignment: .top, spacing: 16) {
          if showPlayback {
            MediaView(model: playback, compact: true, overview: true, origin: identity.local?.identity.deviceName,
              visible: playback.mainVisible, open: { navigation.openFeature(.playback) })
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          if showPlayback && showFileTransfer {
            Rectangle()
              .fill(AniCePalette.separator(colorScheme))
              .frame(width: 1)
              .frame(maxHeight: .infinity)
          }
          if showFileTransfer {
            homeFileTransferActivity(isResult: isResult)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      } else {
        if playback.showOnMac && playback.compactVisible {
          MediaView(model: playback, compact: true, overview: true, origin: identity.local?.identity.deviceName,
            visible: playback.mainVisible, open: { navigation.openFeature(.playback) })
        }
        if transfer.pendingOffer == nil { homeFileTransferActivity(isResult: isResult) }
      }
      if isResult { TransferView(model: transfer, open: { navigation.openFeature(.files) }) }
    }
  }

  @ViewBuilder private func homeFileTransferActivity(isResult: Bool) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Button { navigation.openFeature(.files) } label: {
        HStack(spacing: 8) { Text("File transfer"); Image(systemName: "chevron.forward").font(.caption).accessibilityHidden(true) }
          .font(.system(size: 14, weight: .medium)).contentShape(Rectangle())
      }.buttonStyle(.plain)
      if transfer.state == .idle && !transfer.preparing {
        HStack(spacing: 16) {
          Image(systemName: "arrow.up.to.line").font(.system(size: 24)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
          VStack(alignment: .leading, spacing: 6) {
            Text("Send files").font(.system(size: 14, weight: .medium))
            Text(transfer.activeChannel.map { "Send to " + $0.descriptor.peer.deviceName } ?? "Connect your phone to send files")
              .font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
          }
          Spacer(minLength: 12)
          Button("Choose files") { promptAndSendTransferFiles(model: transfer) }
            .buttonStyle(AniCeButtonStyle()).disabled(!transfer.peerConnected || !transfer.peerCompatible)
        }.padding(24).frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
          .overlay { RoundedRectangle(cornerRadius: 8).stroke(AniCePalette.separator(colorScheme), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
      } else if !isResult { TransferView(model: transfer, open: { navigation.openFeature(.files) }) }
    }
  }

  @ViewBuilder var devicesContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Devices").font(.system(size: 20, weight: .medium))
            Text("Connection and trust.").font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
          }
          Spacer()
          Button { navigation.show(.devices, route: .pairing) } label: { Label("Add device", systemImage: "plus") }
            .buttonStyle(AniCeButtonStyle())
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

        Divider()
        Button { navigation.showSettings(.identity) } label: {
          HStack(spacing: 12) {
            Image(systemName: "laptopcomputer").font(.title3).accessibilityHidden(true)
            Text("This device")
            Text(identity.local?.identity.deviceName ?? "This Mac").foregroundStyle(AniCePalette.secondaryText(colorScheme))
            Spacer()
            Image(systemName: "chevron.forward").accessibilityHidden(true)
          }.padding(.vertical, 16).contentShape(Rectangle())
        }.buttonStyle(.plain)
        Divider()
      }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }
    .sheet(isPresented: Binding(get: { navigation.deviceRoute == .pairing }, set: { if !$0 { navigation.show(.devices) } })) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          HStack {
            Text("Pair a device").font(.system(size: 20, weight: .medium))
            Spacer()
            Button { navigation.show(.devices) } label: { Image(systemName: "xmark") }
              .buttonStyle(.plain).accessibilityLabel("Close pairing")
          }
          Toggle("Connect automatically after pairing", isOn: Binding(
            get: { navigation.automaticAfterPairing && navigation.automaticLanAfterPairing },
            set: { navigation.automaticAfterPairing = $0; navigation.automaticLanAfterPairing = $0 }))
            .toggleStyle(.checkbox).disabled(pairing.phase == "paired")
          MacPairingView(model: pairing, embedded: true, showTrustedDevices: false)
          HStack {
            Spacer()
            Button("Cancel") { pairing.cancel(); navigation.show(.devices) }
              .buttonStyle(AniCeButtonStyle()).keyboardShortcut(.cancelAction)
          }
        }.padding(24)
      }.frame(minWidth: 400, idealWidth: 460, maxHeight: 680)
        .preferredColorScheme(colorScheme).background(AniCePalette.surface(colorScheme))
        .foregroundStyle(AniCePalette.primaryText(colorScheme))
    }
  }
  var aboutContent: some View {
    ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              Text("aniCe").font(.title2.weight(.semibold))
              if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                let channel = Bundle.main.object(forInfoDictionaryKey: "AniCeReleaseChannel") as? String ?? ""
                Text("Version v" + version + (channel.isEmpty ? "" : "-" + channel)).font(.callout)
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
              ClipboardSettingsView(model: clipboard, peers: pairing.peers).padding(.horizontal, 24)
              Divider().padding(.vertical, 12)
              SmsSettingsView(preferences: smsPreferences, peers: pairing.peers).padding(.horizontal, 24)
              Divider().padding(.vertical, 12)
              VStack(alignment: .leading, spacing: 8) {
                Text("File transfer").font(.headline)
                TransferNotificationControls(preferences: transfer.notificationPreferences)
                Text("Applies to all phones. The same switches are available from the gear in Files.")
                  .font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
              }.padding(.horizontal, 24)
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
