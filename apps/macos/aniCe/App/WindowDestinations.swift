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
              phonePower: phonePower,
              details: $navigation.details, diagnostics: $navigation.diagnostics, workspaceHeader: true,
              focusedPeer: navigation.focusedPeer, discovery: discovery,
              canDiscover: !pairing.active && !session.allowing, automaticEnabled: !pairing.active,
              onManageDevices: { navigation.show(.devices) },
              onOpenDevice: { navigation.show(.devices, peer: $0) })
            HomeFeatureAccess(
              onOpen: { navigation.openFeature($0) },
              onBrowse: { navigation.show(.features) })
          } else {
            VStack(alignment: .leading, spacing: 12) {
              Text("Connect your Android phone").font(.title3.weight(.semibold))
              Text("Choose Add device on this Mac. Then choose Add device on your phone to scan the QR code or enter the six-digit code shown here.")
                .font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
              Button("Add device") { navigation.show(.devices, route: .pairing) }.buttonStyle(AniCeButtonStyle())
            }
          }
          if transfer.pendingOffer != nil {
            TransferView(model: transfer, peers: pairing.peers, open: { navigation.openFeature(.files) })
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
        let showFileTransfer = pairing.hasTrustedAndroid && transfer.pendingOffer == nil
        if showPlayback || showFileTransfer {
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
        }
      } else {
        if playback.showOnMac && playback.compactVisible {
          MediaView(model: playback, compact: true, overview: true, origin: identity.local?.identity.deviceName,
            visible: playback.mainVisible, open: { navigation.openFeature(.playback) })
        }
        if pairing.hasTrustedAndroid && transfer.pendingOffer == nil { homeFileTransferActivity(isResult: isResult) }
      }
      if isResult { TransferView(model: transfer, peers: pairing.peers, open: { navigation.openFeature(.files) }) }
    }
  }

  @ViewBuilder private func homeFileTransferActivity(isResult: Bool) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Button { navigation.openFeature(.files) } label: {
        HStack(spacing: 8) { Text("File transfer"); Image(systemName: "chevron.forward").font(.caption).accessibilityHidden(true) }
          .font(.system(size: 14, weight: .medium)).contentShape(Rectangle())
      }.buttonStyle(AniCeHoverButtonStyle(feedbackPadding: 3))
      if transfer.state == .idle && !transfer.preparing {
        HStack(spacing: 16) {
          Image(systemName: "arrow.up.to.line").font(.system(size: 24)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
          VStack(alignment: .leading, spacing: 6) {
            Text("Send files").font(.system(size: 14, weight: .medium))
            Text(transfer.connectedAndroidRecipient.map { "Drop files here to send to " + $0.deviceName } ?? "Connect a compatible Android phone to send files")
              .font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
          }
          Spacer(minLength: 12)
          Button("Choose files") { promptAndSendTransferFiles(model: transfer) }
            .buttonStyle(AniCeButtonStyle()).disabled(!transfer.peerConnected || !transfer.peerCompatible)
        }.padding(24).frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
          .overlay { RoundedRectangle(cornerRadius: 8).stroke(AniCePalette.separator(colorScheme), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
          .transferFileDropTarget(model: transfer, cornerRadius: 8)
        if let dropStatus = transfer.dropStatus {
          Text(dropStatus).font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
        }
      } else if !isResult { TransferView(model: transfer, peers: pairing.peers, open: { navigation.openFeature(.files) }) }
    }
  }

  @ViewBuilder var devicesContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
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
              phonePower: phonePower,
              details: Binding(get: { navigation.details && navigation.focusedPeer == record.peer.deviceId },
                set: { navigation.focusedPeer = record.peer.deviceId; navigation.details = $0 }),
              diagnostics: $navigation.diagnostics, focusedPeer: record.peer.deviceId, discovery: discovery,
              canDiscover: !pairing.active && !session.allowing, automaticEnabled: !pairing.active,
              onManageDevices: { navigation.show(.devices, route: .pairing) })
          }
          if pairing.hasTrustedAndroid || pairing.trustRecoveryNeeded {
            DisclosureGroup("Trust and saved devices") {
              MacPairingView(model: pairing, showPairingControls: false)
            }.font(.callout).frame(minHeight: 36, alignment: .leading).padding(.top, 8)
          }

        Divider()
        Button { showingLocalIdentity = true } label: {
          HStack(spacing: 12) {
            Image(systemName: "laptopcomputer").font(.title3).accessibilityHidden(true)
            Text("This device")
            Text(identity.local?.identity.deviceName ?? "This Mac").foregroundStyle(AniCePalette.secondaryText(colorScheme))
            Spacer()
            Image(systemName: "chevron.forward").accessibilityHidden(true)
          }.frame(minHeight: 36).contentShape(Rectangle())
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
            .toggleStyle(.checkbox).aniCeControlFeedback(feedbackPadding: 3).disabled(pairing.phase == "paired")
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
        Text("About").font(.system(size: 18, weight: .medium))
        Text("Connect your Mac and Android.").font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
        VStack(spacing: 0) {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
              aboutMark
              Text("aniCe").font(.system(size: 18, weight: .medium))
              Spacer(minLength: 8)
              aboutProductDetails(alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 12) {
                aboutMark
                Text("aniCe").font(.system(size: 18, weight: .medium))
              }
              aboutProductDetails(alignment: .leading).padding(.leading, 32)
            }
          }
          .padding(.vertical, 16)
          .overlay(alignment: .bottom) { AniCePalette.separator(colorScheme).frame(height: 0.5) }
          aboutLink("Source code", detail: "GitHub", destination: "https://github.com/anisharyal09/aniCe")
          aboutLink("License", detail: "GPL-3.0-or-later", destination: "https://github.com/anisharyal09/aniCe/blob/main/LICENSE")
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
              aboutLink("Developer", detail: "@anisharyal09", destination: "https://github.com/anisharyal09", showSeparator: false)
              aboutProfileLinks
            }
            VStack(spacing: 0) {
              aboutLink("Developer", detail: "@anisharyal09", destination: "https://github.com/anisharyal09", showSeparator: false)
              aboutProfileLinks.frame(maxWidth: .infinity, alignment: .trailing)
            }
          }
          .overlay(alignment: .bottom) { AniCePalette.separator(colorScheme).frame(height: 0.5) }
          HStack {
            Spacer()
            Link(destination: URL(string: "https://anisharyal09.com.np/support?from=anice")!) {
              Image(systemName: "heart").font(.system(size: 14))
                .foregroundStyle(AniCePalette.secondaryText(colorScheme))
                .frame(width: 40, height: 40).contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("Support aniCe").help("Support aniCe")
            Spacer()
          }
          .padding(.top, 4)
        }
        .frame(maxWidth: 660, alignment: .leading)
      }
      .frame(maxWidth: 660, alignment: .leading).padding(24)
      .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  private var aboutProfileLinks: some View {
    HStack(spacing: 2) {
      Link(destination: URL(string: "https://x.com/anisharyal09")!) {
        ZStack {
          Path { path in
            path.move(to: CGPoint(x: 3, y: 2)); path.addLines([CGPoint(x: 7.2, y: 2), CGPoint(x: 21, y: 22), CGPoint(x: 16.8, y: 22)]); path.closeSubpath()
            path.move(to: CGPoint(x: 5.4, y: 3.4)); path.addLines([CGPoint(x: 6.4, y: 3.4), CGPoint(x: 18.6, y: 20.6), CGPoint(x: 17.6, y: 20.6)]); path.closeSubpath()
          }.fill(style: FillStyle(eoFill: true))
          Path { path in
            path.move(to: CGPoint(x: 19.2, y: 2)); path.addLines([CGPoint(x: 21.6, y: 2), CGPoint(x: 4.8, y: 22), CGPoint(x: 2.4, y: 22)]); path.closeSubpath()
          }.fill()
        }
        .frame(width: 24, height: 24).scaleEffect(0.67)
        .frame(width: 36, height: 36).contentShape(RoundedRectangle(cornerRadius: 7))
      }
      .buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("X profile").help("X profile")
      Link(destination: URL(string: "https://www.linkedin.com/in/anisharyal09/")!) {
        Text("in").font(.system(size: 14, weight: .bold))
          .frame(width: 36, height: 36).contentShape(RoundedRectangle(cornerRadius: 7))
      }
      .buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("LinkedIn profile").help("LinkedIn profile")
    }.foregroundStyle(AniCePalette.secondaryText(colorScheme)).fixedSize()
  }

  private var aboutVersion: String? {
    guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
    let channel = Bundle.main.object(forInfoDictionaryKey: "AniCeReleaseChannel") as? String ?? ""
    return "Version v" + version + (channel.isEmpty ? "" : "-" + channel)
  }

  private var aboutMark: some View {
    Image("BrandMark").resizable().scaledToFit()
      .frame(width: 28, height: 28).accessibilityHidden(true)
  }

  private func aboutProductDetails(alignment: HorizontalAlignment) -> some View {
    VStack(alignment: alignment, spacing: 2) {
      Text("macOS + Android").font(.system(size: 12)).foregroundStyle(AniCePalette.secondaryText(colorScheme)).fixedSize(horizontal: true, vertical: false)
      if let version = aboutVersion { Text(version).font(.system(size: 11)).foregroundStyle(AniCePalette.secondaryText(colorScheme)).fixedSize(horizontal: true, vertical: false) }
    }
  }

  @ViewBuilder private func aboutLink(_ title: String, detail: String, destination: String, showSeparator: Bool = true) -> some View {
    if let url = URL(string: destination) {
      let hovered = hoveredAboutLink == title
      Link(destination: url) {
        HStack(spacing: 16) {
          Text(title).font(.system(size: 12)).foregroundStyle(AniCePalette.primaryText(colorScheme))
          Spacer()
          HStack(spacing: 8) {
            Text(detail).font(.system(size: 11)).fixedSize(horizontal: true, vertical: false).foregroundStyle(hovered ? AniCePalette.primaryText(colorScheme) : AniCePalette.secondaryText(colorScheme))
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
      .overlay(alignment: .bottom) { if showSeparator { AniCePalette.separator(colorScheme).frame(height: 0.5) } }
      .accessibilityLabel("\(title), \(detail)")
    }
  }

  @ViewBuilder var settingsContent: some View {
    if navigation.settingsRoute == .about {
      aboutContent
    } else {
      Group {
        GeometryReader { geometry in
          let expanded = geometry.size.width >= 880
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              let jumps = [
                ("appearance", "Appearance"), ("connection", "Connection"), ("permissions", "Permissions"), ("desk-deck", "Desk Deck"),
                ("dnd-sync", "Do Not Disturb"), ("clipboard", "Clipboard"),
                ("messages", "Messages"), ("file-transfer", "File transfer"),
                ("now-playing", "Now Playing"), ("this-device", "This device")
              ]
              ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                  ForEach(jumps, id: \.0) { id, label in settingsJump(label, id: id) }
                }
                .fixedSize(horizontal: true, vertical: false)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 6) {
                  ForEach(jumps, id: \.0) { id, label in settingsJump(label, id: id) }
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.bottom, 16)
              .overlay(alignment: .bottom) { AniCePalette.separator(colorScheme).frame(height: 0.5) }
              .padding(.bottom, 18)

              SettingsSectionLayout(columns: expanded ? 2 : 1) {
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
                      .toggleStyle(.checkbox).aniCeControlFeedback(feedbackPadding: 3).controlSize(.small)
                    Text("Enable on both devices to use Wi-Fi.").font(.caption)
                      .foregroundStyle(AniCePalette.secondaryText(colorScheme)).padding(.leading, 20)
                  }.frame(minHeight: 48, alignment: .leading)
                }
                preferenceSection("Permissions", id: "permissions") {
                  MacPhoneInputView(model: phoneInput, onOpenDevices: { navigation.show(.devices) })
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                preferenceSection("Desk Deck", id: "desk-deck") {
                  DeskDeckSettingsView(model: deskDeck, peers: pairing.peers)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                preferenceSection("Do Not Disturb", id: "dnd-sync") {
                  DndSyncSettingsView(model: dndSync, deskDeck: deskDeck)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
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
                  VStack(alignment: .leading, spacing: 8) {
                    TransferNotificationControls(preferences: transfer.notificationPreferences)
                    Divider().overlay(AniCePalette.separator(colorScheme))
                    TransferAutoReceiveSettings(preferences: transfer.autoReceivePreferences, peers: pairing.peers, compact: true)
                    Divider().overlay(AniCePalette.separator(colorScheme))
                    TransferReceiveDestinationControls(model: transfer)
                    Divider().overlay(AniCePalette.separator(colorScheme))
                    EdgeDropSettingsView(controller: edgeDrop)
                  }
                  .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                preferenceSection("Now Playing", id: "now-playing") {
                  Toggle("Show on Overview and menu bar", isOn: Binding(get: { playback.showOnMac }, set: { playback.setShowOnMac($0) }))
                    .toggleStyle(.checkbox).aniCeControlFeedback(feedbackPadding: 3).controlSize(.small).frame(minHeight: 48)
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
      // Repeated jumps restart the highlight lifetime; replacing the task cancels the previous fade.
      .task(id: settingsFocusToken) {
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
    .background(SettingsScrollAnchor(id: id, coordinator: settingsScroller))
    .id(id)
  }

  private func settingsJump(_ label: String, id: String) -> some View {
    let selected = activeSettingsSection == id
    let hovered = hoveredSettingsSection == id
    return Button {
      activeSettingsSection = id
      focusedSettingsSection = nil
      settingsScroller.scroll(to: id, animated: !reduceMotion) {
        // An older scroll completion must not highlight a section superseded by another shortcut.
        guard activeSettingsSection == id else { return }
        focusedSettingsSection = id
        settingsFocusToken = UUID()
      }
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


// Eager, balanced columns keep section anchors available without leaving gaps beside tall groups.
private struct SettingsSectionLayout: Layout {
  let columns: Int
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 680
    let cellWidth = max(0, (width - CGFloat(columns - 1) * 24) / CGFloat(columns))
    var columnHeights = Array(repeating: CGFloat.zero, count: columns)
    for subview in subviews {
      let column = columnHeights.enumerated().min { $0.element < $1.element }?.offset ?? 0
      columnHeights[column] += subview.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height
    }
    return CGSize(width: width, height: columnHeights.max() ?? 0)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let width = max(0, (bounds.width - CGFloat(columns - 1) * 24) / CGFloat(columns))
    var columnHeights = Array(repeating: CGFloat.zero, count: columns)
    for index in subviews.indices {
      let column = columnHeights.enumerated().min { $0.element < $1.element }?.offset ?? 0
      let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
      subviews[index].place(
        at: CGPoint(x: bounds.minX + CGFloat(column) * (width + 24), y: bounds.minY + columnHeights[column]),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: width, height: size.height))
      columnHeights[column] += size.height
    }
  }
}


@MainActor final class SettingsScrollCoordinator {
  var anchors: [String: NSView] = [:]

  func scroll(to id: String, animated: Bool, completion: @escaping () -> Void) {
    guard let anchor = anchors[id], let scroll = anchor.enclosingScrollView,
          let document = scroll.documentView else { return }
    document.layoutSubtreeIfNeeded()
    var target = anchor.convert(anchor.bounds, to: document)
    let clip = scroll.contentView
    let visible = scroll.documentVisibleRect
    // Oversized groups reveal their heading rather than trying to fit the entire group.
    if target.height > visible.height - 24 {
      let height = max(0, visible.height - 24)
      if !document.isFlipped { target.origin.y = target.maxY - height }
      target.size.height = height
    }
    var desired = clip.bounds.origin.y
    if target.minY < visible.minY { desired -= visible.minY - target.minY + 12 }
    else if target.maxY > visible.maxY { desired += target.maxY - visible.maxY + 12 }
    else { completion(); return }
    let lower = document.bounds.minY
    let upper = max(lower, document.bounds.maxY - clip.bounds.height)
    let origin = NSPoint(x: clip.bounds.origin.x, y: min(upper, max(lower, desired)))
    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        clip.animator().setBoundsOrigin(origin)
      } completionHandler: {
        scroll.reflectScrolledClipView(clip)
        completion()
      }
    } else {
      clip.scroll(to: origin)
      scroll.reflectScrolledClipView(clip)
      completion()
    }
  }
}

private struct SettingsScrollAnchor: NSViewRepresentable {
  let id: String
  let coordinator: SettingsScrollCoordinator
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    coordinator.anchors[id] = view
    return view
  }
  func updateNSView(_ view: NSView, context: Context) { coordinator.anchors[id] = view }
}

private struct DeskDeckSettingsView: View {
  @Bindable var model: MacDeskDeckModel
  let peers: [PeerTrustRecord]
  @Environment(\.colorScheme) private var colorScheme
  @State private var notice = ""

  private var androidPeers: [PeerTrustRecord] { peers.filter { $0.peer.platform == "android" } }

  var body: some View {
    let catalogGeneration = model.catalogGeneration
    return VStack(alignment: .leading, spacing: 8) {
      Text("Choose which apps each phone can launch from Desk Deck.")
        .font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      if androidPeers.isEmpty {
        Text("Pair a phone to add approved apps.").font(.callout)
      } else {
        ForEach(androidPeers, id: \.peer.fingerprint) { record in
          let peer = record.peer
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(peer.deviceName).font(.system(size: 13, weight: .medium)).lineLimit(1)
              Spacer()
              Button("Add app…") { chooseApplication(for: peer) }
                .controlSize(.small).disabled(model.availableApprovalCount(for: peer) >= 32)
            }.frame(minHeight: 32)
            let apps = model.approvedApps(for: peer)
            if apps.isEmpty {
              Text("No apps added").font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
            }
            ForEach(apps) { app in
              HStack(spacing: 10) {
                Text(app.name).lineLimit(1)
                Spacer(minLength: 8)
                if !model.applicationIsAvailable(app) {
                  Text("Unavailable").font(.caption)
                    .foregroundStyle(AniCePalette.secondaryText(colorScheme)).lineLimit(1)
                }
                Button("Remove") { model.removeApprovedApp(id: app.id, for: peer) }
                  .controlSize(.small).accessibilityLabel("Remove \(app.name) for \(peer.deviceName)")
              }.frame(minHeight: 32)
            }
            if model.availableApprovalCount(for: peer) >= 32 {
              Text("This phone has reached the 32-app limit.").font(.caption)
                .foregroundStyle(AniCePalette.secondaryText(colorScheme))
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
          if peer.fingerprint != androidPeers.last?.peer.fingerprint {
            Divider().overlay(AniCePalette.separator(colorScheme)).padding(.vertical, 2)
          }
        }
      }
      if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme)) }
    }
    .id(catalogGeneration)
  }

  private func chooseApplication(for peer: DeviceIdentity) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Add App"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if model.addApprovedApp(at: url, for: peer) {
      notice = ""
    } else {
      notice = "App could not be approved."
    }
  }
}
