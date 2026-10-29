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
      }.buttonStyle(AniCeHoverButtonStyle())
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
      VStack(alignment: .leading, spacing: 12) {
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
        Button { showingLocalIdentity = true } label: {
          HStack(spacing: 12) {
            Image(systemName: "laptopcomputer").font(.title3).accessibilityHidden(true)
            Text("This device")
            Text(identity.local?.identity.deviceName ?? "This Mac").foregroundStyle(AniCePalette.secondaryText(colorScheme))
            Spacer()
            Image(systemName: "chevron.forward").accessibilityHidden(true)
          }.padding(.vertical, 8).contentShape(Rectangle())
        }.buttonStyle(AniCeHoverButtonStyle())
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
              .buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("Close pairing")
          }
          Toggle("Connect automatically after pairing", isOn: Binding(
            get: { navigation.automaticAfterPairing && navigation.automaticLanAfterPairing },
            set: { navigation.automaticAfterPairing = $0; navigation.automaticLanAfterPairing = $0 }))
            .toggleStyle(.checkbox).aniCeControlFeedback().disabled(pairing.phase == "paired")
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
        Text("About").font(.system(size: 20, weight: .medium))
        Text("Connect your Mac and Android.").font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
        VStack(spacing: 0) {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
              aboutMark
              Text("aniCe").font(.system(size: 20, weight: .medium))
              Spacer(minLength: 8)
              aboutProductDetails(alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 12) {
                aboutMark
                Text("aniCe").font(.system(size: 20, weight: .medium))
              }
              aboutProductDetails(alignment: .leading).padding(.leading, 32)
            }
          }
          .padding(.vertical, 16)
          .overlay(alignment: .bottom) { AniCePalette.separator(colorScheme).frame(height: 0.5) }
          aboutLink("Source code", detail: "GitHub", destination: "https://github.com/anisharyal09/aniCe")
          aboutLink("License", detail: "GPL-3.0-or-later", destination: "https://github.com/anisharyal09/aniCe/blob/main/LICENSE")
          aboutLink("Developer", detail: "@anisharyal09", destination: "https://github.com/anisharyal09")
          HStack(spacing: 6) {
            Link(destination: URL(string: "https://x.com/anisharyal09")!) {
              Image(systemName: "xmark").font(.system(size: 14, weight: .medium))
                .foregroundStyle(AniCePalette.secondaryText(colorScheme))
                .frame(width: 40, height: 40).contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("X profile").help("X profile")
            Link(destination: URL(string: "https://www.linkedin.com/in/anisharyal09/")!) {
              Text("in").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AniCePalette.secondaryText(colorScheme))
                .frame(width: 40, height: 40).contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("LinkedIn profile").help("LinkedIn profile")
            Link(destination: URL(string: "https://anisharyal09.com.np/support?from=anice")!) {
              Image(systemName: "heart").font(.system(size: 16))
                .foregroundStyle(AniCePalette.secondaryText(colorScheme))
                .frame(width: 40, height: 40).contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("Support aniCe").help("Support aniCe")
          }
          .padding(.top, 14)
        }
        .frame(maxWidth: 660, alignment: .leading)
      }
      .padding(24).frame(maxWidth: 660, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var aboutVersion: String? {
    guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
    let channel = Bundle.main.object(forInfoDictionaryKey: "AniCeReleaseChannel") as? String ?? ""
    return "Version v" + version + (channel.isEmpty ? "" : "-" + channel)
  }

  private var aboutMark: some View {
    Image(systemName: "link").font(.system(size: 17)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      .frame(width: 20).accessibilityHidden(true)
  }

  private func aboutProductDetails(alignment: HorizontalAlignment) -> some View {
    VStack(alignment: alignment, spacing: 2) {
      Text("macOS + Android").font(.system(size: 12)).foregroundStyle(AniCePalette.secondaryText(colorScheme)).fixedSize(horizontal: true, vertical: false)
      if let version = aboutVersion { Text(version).font(.system(size: 11)).foregroundStyle(AniCePalette.secondaryText(colorScheme)).fixedSize(horizontal: true, vertical: false) }
    }
  }

  @ViewBuilder private func aboutLink(_ title: String, detail: String, destination: String) -> some View {
    if let url = URL(string: destination) {
      let hovered = hoveredAboutLink == title
      Link(destination: url) {
        HStack(spacing: 16) {
          Text(title).font(.system(size: 13)).foregroundStyle(AniCePalette.primaryText(colorScheme))
          Spacer()
          HStack(spacing: 8) {
            Text(detail).font(.system(size: 12)).foregroundStyle(hovered ? AniCePalette.primaryText(colorScheme) : AniCePalette.secondaryText(colorScheme))
            Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(hovered ? AniCePalette.primaryText(colorScheme) : AniCePalette.secondaryText(colorScheme))
              .accessibilityHidden(true)
          }
        }
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(AniCeHoverButtonStyle())
      .onHover { isHovered in hoveredAboutLink = isHovered ? title : (hoveredAboutLink == title ? nil : hoveredAboutLink) }
      .animation(.easeOut(duration: 0.14), value: hovered)
      .overlay(alignment: .bottom) { AniCePalette.separator(colorScheme).frame(height: 0.5) }
      .accessibilityLabel("\(title), \(detail)")
    }
  }

  @ViewBuilder var settingsContent: some View {
    if navigation.settingsRoute == .about {
      aboutContent
    } else {
      ScrollViewReader { proxy in
        GeometryReader { geometry in
          let expanded = geometry.size.width >= 880
          let columns = Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: expanded ? 2 : 1)
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              let jumps = [
                ("appearance", "Appearance"), ("connection", "Connection"), ("clipboard", "Clipboard"),
                ("messages", "Messages"), ("this-device", "This device")
              ]
              ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                  ForEach(jumps, id: \.0) { id, label in settingsJump(label, id: id, proxy: proxy) }
                }
                .fixedSize(horizontal: true, vertical: false)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 6) {
                  ForEach(jumps, id: \.0) { id, label in settingsJump(label, id: id, proxy: proxy) }
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.bottom, 16)
              .overlay(alignment: .bottom) { AniCePalette.separator(colorScheme).frame(height: 0.5) }
              .padding(.bottom, 18)

              LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                preferenceSection("Appearance", id: "appearance") {
                  HStack {
                    Text("Window appearance")
                    Spacer()
                    Picker("Window appearance", selection: Binding(
                      get: { WindowAppearance.stored(appearance).rawValue }, set: { appearance = $0 })) {
                        ForEach(WindowAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 130)
                  }.frame(minHeight: 48)
                }
                preferenceSection("Connection", id: "connection") {
                  VStack(alignment: .leading, spacing: 5) {
                    Toggle("Use local network automatically", isOn: Binding(get: { lan.automatic }, set: { lan.setAutomatic($0) }))
                      .toggleStyle(.checkbox).aniCeControlFeedback().controlSize(.small)
                    Text("Enable on both devices to use Wi-Fi.").font(.caption)
                      .foregroundStyle(AniCePalette.secondaryText(colorScheme)).padding(.leading, 20)
                  }.frame(minHeight: 48, alignment: .leading)
                }
                preferenceSection("Clipboard", id: "clipboard") {
                  ClipboardSettingsView(model: clipboard, peers: pairing.peers, compactSettings: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                preferenceSection("Messages", id: "messages") {
                  SmsSettingsView(preferences: smsPreferences, peers: pairing.peers, showTitle: false)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                preferenceSection("File transfer", id: "file-transfer") {
                  TransferNotificationControls(preferences: transfer.notificationPreferences)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                preferenceSection("Now Playing", id: "now-playing") {
                  Toggle("Show on Overview and menu bar", isOn: Binding(get: { playback.showOnMac }, set: { playback.setShowOnMac($0) }))
                    .toggleStyle(.checkbox).aniCeControlFeedback().controlSize(.small).frame(minHeight: 48)
                }
                preferenceSection("This device", id: "this-device") {
                  Button { showingLocalIdentity = true } label: {
                    HStack(spacing: 10) {
                      VStack(alignment: .leading, spacing: 2) {
                        Text(identity.local?.identity.deviceName ?? "This Mac")
                        Text("Identity and security").font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                      }
                      Spacer()
                      Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AniCePalette.secondaryText(colorScheme)).accessibilityHidden(true)
                    }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
                  }.buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("This device, identity and security")
                }
              }
            }
            .padding(24)
            .frame(maxWidth: expanded ? 1120 : 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
          }
        }
      }
      .task(id: focusedSettingsSection) {
        guard focusedSettingsSection != nil else { return }
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { focusedSettingsSection = nil }
      }
    }
  }

  @ViewBuilder private func preferenceSection<Content: View>(
    _ title: String,
    id: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    let focused = focusedSettingsSection == id
    let group = VStack(alignment: .leading, spacing: 0, content: content)
      .font(.system(size: 13))
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .background(focused ? AniCePalette.subtleAccent(colorScheme) : AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 10))
      .overlay { RoundedRectangle(cornerRadius: 10).stroke(focused ? AniCePalette.accent(colorScheme) : AniCePalette.separator(colorScheme), lineWidth: focused ? 1 : 0.5) }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: focused)
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      group
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, 18)
    .id(id)
  }

  private func settingsJump(_ label: String, id: String, proxy: ScrollViewProxy) -> some View {
    let selected = activeSettingsSection == id
    let hovered = hoveredSettingsSection == id
    return Button {
      activeSettingsSection = id
      focusedSettingsSection = id
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .top) }
    } label: {
      Text(label)
        .font(.system(size: 12, weight: selected ? .medium : .regular))
        .foregroundStyle(selected || hovered ? AniCePalette.primaryText(colorScheme) : AniCePalette.secondaryText(colorScheme))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(selected ? AniCePalette.subtleAccent(colorScheme) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(selected ? AniCePalette.separator(colorScheme) : .clear, lineWidth: 0.75) }
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(AniCeHoverButtonStyle())
    .onHover { isHovered in hoveredSettingsSection = isHovered ? id : (hoveredSettingsSection == id ? nil : hoveredSettingsSection) }
    .animation(.easeOut(duration: 0.14), value: hovered)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityHint("Scroll to \(label) settings")
  }
}
