// SPDX-License-Identifier: GPL-3.0-or-later
// Composes the device overview, nested management and settings through application-scoped owners.
import SwiftUI
import AppKit
import UserNotifications

struct MacPermissionSummary: View {
  let clipboard: MacClipboardModel
  let notifications: UNAuthorizationStatus?
  let showGranted: Bool
  var onPermissionsChanged: () -> Void = {}
  @State private var requestingNotifications = false
  @State private var notificationError: String?
  @Environment(\.colorScheme) private var scheme
  @AppStorage("ui.fontScale") private var fontScale = 1.0

  static func notificationsAllowed(_ status: UNAuthorizationStatus?) -> Bool {
    status == .authorized || status == .provisional
  }

  private var notificationStatus: String {
    switch notifications {
    case .authorized?, .provisional?: "Allowed"
    case .denied?: "Not allowed"
    case .notDetermined?: "Not requested"
    case nil: "Checking"
    default: "Unavailable"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if showGranted || notifications != nil && !Self.notificationsAllowed(notifications) {
        permission("Notifications", status: notificationStatus,
          purpose: "Show phone alerts, Messages, Find Device, transfers and updates.")
        if notifications == .notDetermined {
          Button("Allow notifications") {
            guard !requestingNotifications else { return }
            requestingNotifications = true
            notificationError = nil
            Task {
              defer { requestingNotifications = false }
              do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
              catch { notificationError = "Notification access could not be requested. Open notification settings." }
              onPermissionsChanged()
            }
          }.buttonStyle(AniCeButtonStyle()).disabled(requestingNotifications)
        } else if notifications != nil, !Self.notificationsAllowed(notifications) {
          Button("Notification settings") {
            openSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
          }.buttonStyle(AniCeButtonStyle())
        }
        if let notificationError {
          Text(notificationError).font(.system(size: 12 * fontScale))
            .foregroundStyle(AniCePalette.error(scheme)).fixedSize(horizontal: false, vertical: true)
          Button("Notification settings") {
            openSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
          }.buttonStyle(AniCeButtonStyle())
        }
      }
      if showGranted || !clipboard.automaticAccessAllowed {
        permission("Automatic pasteboard reading",
          status: clipboard.automaticAccessAllowed ? "Available" : "Not allowed",
          purpose: "Read copied text for enabled history or automatic sharing.")
        if !clipboard.automaticAccessAllowed {
          Button("Pasteboard settings") {
            openSettings("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
          }.buttonStyle(AniCeButtonStyle())
        }
      }
    }
  }
  private func permission(_ title: String, status: String, purpose: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(title)
        Spacer(minLength: 8)
        Text(status).foregroundStyle(AniCePalette.secondaryText(scheme))
          .fixedSize(horizontal: true, vertical: false)
      }
      if showGranted {
        Text(purpose).font(.system(size: 12 * fontScale))
          .foregroundStyle(AniCePalette.secondaryText(scheme))
          .fixedSize(horizontal: false, vertical: true)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func openSettings(_ address: String) {
    if let url = URL(string: address) { NSWorkspace.shared.open(url) }
  }
}

struct AboutFeedbackLinks: View {
  var reportURL: URL
  var fontScale: Double = 1.0
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        reportTitle
        Spacer(minLength: 12)
        actions
      }
      VStack(alignment: .leading, spacing: 0) {
        reportTitle
        actions.frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
    .overlay(alignment: .bottom) { AniCePalette.separator(colorScheme).frame(height: 0.5) }
  }

  private var reportTitle: some View {
    Link(destination: reportURL) {
      Text("Report an issue").font(.system(size: 13 * fontScale))
        .foregroundStyle(AniCePalette.primaryText(colorScheme)).fixedSize()
        .frame(minHeight: 36).contentShape(Rectangle())
    }
    .buttonStyle(AniCeHoverButtonStyle())
    .accessibilityLabel("Report an issue")
  }

  private var actions: some View {
    HStack(spacing: 8) {
      Link(destination: reportURL) {
        Label("GitHub form", systemImage: "arrow.up.right")
          .font(.system(size: 12 * fontScale)).fixedSize()
          .padding(.horizontal, 4).frame(minHeight: 36).contentShape(Rectangle())
      }
      .buttonStyle(AniCeHoverButtonStyle())
      .accessibilityLabel("GitHub issue form")
      Link(destination: IssueReport.emailURL) {
        Label("Email", systemImage: "envelope")
          .font(.system(size: 12 * fontScale)).fixedSize()
          .padding(.horizontal, 4).frame(minHeight: 36).contentShape(Rectangle())
      }
      .buttonStyle(AniCeHoverButtonStyle())
      .accessibilityLabel("Email aniCe")
      .help("Email anish.creations.hq@gmail.com")
    }
    .foregroundStyle(AniCePalette.secondaryText(colorScheme)).fixedSize()
  }
}

struct AboutSupportLinks: View {
  var fontScale: Double = 1.0
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 0) {
      Link(destination: AniCeSupport.url) {
        HStack(spacing: 6) {
          Image(systemName: "heart").font(.system(size: 13 * fontScale)).accessibilityHidden(true)
          AniCeWordmark(size: 13 * fontScale, weight: .regular, prefix: "Support ", suffix: " :)")
            .multilineTextAlignment(.center)
        }
        .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(minHeight: 32)
        .contentShape(Rectangle())
      }
      .buttonStyle(AniCeHoverButtonStyle())
      .accessibilityIdentifier("about.support")
      .accessibilityLabel("Support aniCe")
      .help("Support aniCe")

      Link(destination: URL(string: "https://github.com/anisharyal09/aniCe")!) {
        AniCeWordmark(size: 12 * fontScale, weight: .regular, prefix: "☆ Star ", suffix: " on GitHub")
          .foregroundStyle(AniCePalette.secondaryText(colorScheme))
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 8).padding(.vertical, 4)
          .frame(minHeight: 32)
          .contentShape(Rectangle())
      }
      .buttonStyle(AniCeHoverButtonStyle())
      .accessibilityIdentifier("about.star")
      .accessibilityLabel("Star aniCe on GitHub")
      .help("Open aniCe on GitHub to star the repository")
    }
    .frame(maxWidth: .infinity)
  }
}

extension MainWindowView {
  @ViewBuilder var homeContent: some View {
    GeometryReader { geometry in
      let activityWidth = geometry.size.width - 56
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text("Overview").font(.system(size: 20 * fontScale, weight: .medium))
          if pairing.hasTrustedAndroid {
            MacSessionView(peers: pairing.peers, model: session, lan: lan,
              connectionPause: connectionPause, phonePower: phonePower,
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
              Text("Open aniCe on your Android phone and bring it close. Confirm the matching code on both screens. Use Add device for QR or manual-code pairing.")
                .font(.callout).foregroundStyle(AniCePalette.secondaryText(colorScheme))
              Button("Add device") { navigation.show(.devices, route: .pairing) }.buttonStyle(AniCeButtonStyle())
            }
          }
          if transfer.pendingOffer != nil {
            TransferView(model: transfer, peers: pairing.peers, overview: true, open: { navigation.openFeature(.files) })
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
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
          .transferFileDropTarget(model: transfer, cornerRadius: 0)
      }
    }
  }

  @ViewBuilder private func homeActivities(isResult: Bool, availableWidth: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      if availableWidth >= 720 {
        let showPlayback = playback.showOnMac && playback.compactVisible
        let showFileTransfer = pairing.hasTrustedAndroid && transfer.pendingOffer == nil && !isResult
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
              homeFileTransferActivity()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        if playback.showOnMac && playback.compactVisible {
          MediaView(model: playback, compact: true, overview: true, origin: identity.local?.identity.deviceName,
            visible: playback.mainVisible, open: { navigation.openFeature(.playback) })
        }
        if pairing.hasTrustedAndroid && transfer.pendingOffer == nil && !isResult {
          homeFileTransferActivity()
        }
      }
      if isResult { TransferView(model: transfer, peers: pairing.peers, overview: true, open: { navigation.openFeature(.files) }) }
    }
  }

  @ViewBuilder private func homeFileTransferActivity() -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HomeTransferHeading { navigation.openFeature(.files) }
      if transfer.state == .idle && !transfer.preparing {
        HStack(spacing: 16) {
          Image(systemName: "arrow.up.to.line").font(.system(size: 24)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
          VStack(alignment: .leading, spacing: 6) {
            Text("Send files").font(.system(size: 14 * fontScale, weight: .medium))
            Text(transfer.connectedAndroidRecipient.map { "Drop files here to send to " + $0.displayName } ?? "Connect a compatible Android phone to send files")
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
      } else { TransferView(model: transfer, peers: pairing.peers, overview: true) }
    }
  }

  @ViewBuilder var devicesContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Devices").font(.system(size: 20 * fontScale, weight: .medium))
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
              connectionPause: connectionPause, phonePower: phonePower,
              details: Binding(get: { navigation.details && navigation.focusedPeer == record.peer.deviceId },
                set: { navigation.focusedPeer = record.peer.deviceId; navigation.details = $0 }),
              diagnostics: $navigation.diagnostics, focusedPeer: record.peer.deviceId, discovery: discovery,
               canDiscover: !pairing.active && !session.allowing, automaticEnabled: !pairing.active,
               onManageDevices: { navigation.show(.devices, route: .pairing) },
               onRenamePeer: { nicknamePeer = $0 })
          }
          if pairing.hasTrustedAndroid || pairing.trustRecoveryNeeded {
            DisclosureGroup("Trust and saved devices") {
              MacPairingView(model: pairing, showPairingControls: false, identityModel: identity)
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
           .contextMenu { Button("Edit name…") { editingLocalName = true } }
           .highPriorityGesture(LongPressGesture().onEnded { _ in editingLocalName = true })
           .accessibilityAction(named: "Edit device name") { editingLocalName = true }
      }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }
    .sheet(isPresented: Binding(get: { navigation.deviceRoute == .pairing }, set: { if !$0 { navigation.show(.devices) } })) {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          HStack {
            Text("Pair a device").font(.system(size: 20 * fontScale, weight: .medium))
            Spacer()
            Button { navigation.show(.devices) } label: { Image(systemName: "xmark") }
              .buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("Close pairing")
          }
          Toggle("Connect automatically after pairing", isOn: Binding(
            get: { navigation.automaticAfterPairing && navigation.automaticLanAfterPairing },
            set: { navigation.automaticAfterPairing = $0; navigation.automaticLanAfterPairing = $0 }))
            .toggleStyle(.checkbox).aniCeControlFeedback(feedbackPadding: 3).disabled(pairing.phase == "paired")
          MacPairingView(model: pairing, embedded: true, showTrustedDevices: false, identityModel: identity)
          if !pairing.nearbyEnabled {
            HStack {
              Spacer()
              Button("Cancel") { pairing.cancel(); navigation.show(.devices) }
                .buttonStyle(AniCeButtonStyle()).keyboardShortcut(.cancelAction)
            }
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
        Text("About").font(.system(size: 18 * fontScale, weight: .medium))
        Text("Android + Mac, like never before.")
          .font(.system(size: 14 * fontScale, weight: .regular))
          .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        VStack(spacing: 0) {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
              aboutMark
              AniCeWordmark(size: 18 * fontScale, weight: .semibold)
              Spacer(minLength: 8)
              aboutProductDetails(alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 12) {
                aboutMark
                AniCeWordmark(size: 18 * fontScale, weight: .semibold)
              }
              aboutProductDetails(alignment: .leading).padding(.leading, 32)
            }
          }
          .padding(.vertical, 16)
          .overlay(alignment: .bottom) { AniCePalette.separator(colorScheme).frame(height: 0.5) }
          aboutLink("Source code", detail: "GitHub", destination: "https://github.com/anisharyal09/aniCe")
          aboutLink("License", detail: "GPL-3.0-or-later", destination: "https://github.com/anisharyal09/aniCe/blob/main/LICENSE")
          AboutFeedbackLinks(reportURL: IssueReport.currentURL, fontScale: fontScale)
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
              Text("Reach out").font(.system(size: 13 * fontScale)).fixedSize()
              Spacer(minLength: 12)
              aboutContactLinks
            }
            VStack(alignment: .trailing, spacing: 4) {
              Text("Reach out").font(.system(size: 13 * fontScale))
                .frame(maxWidth: .infinity, alignment: .leading)
              aboutContactLinks
            }
          }
          .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
          .overlay(alignment: .bottom) { AniCePalette.separator(colorScheme).frame(height: 0.5) }
        }
        .frame(maxWidth: 660, alignment: .leading)

        VStack(alignment: .leading, spacing: 14) {
          Text("No account needed to connect your devices. No telemetry. Updates and issue reports use GitHub.")
            .font(.system(size: 13 * fontScale))
            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
            .fixedSize(horizontal: false, vertical: true)

          AboutSupportLinks(fontScale: fontScale)
        }
        .padding(.top, 4)
        .frame(maxWidth: 660, alignment: .leading)
      }
      .frame(maxWidth: 660, alignment: .leading).padding(24)
      .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  private var aboutContactLinks: some View {
    HStack(spacing: 8) {
      Link(destination: URL(string: "https://github.com/anisharyal09")!) {
        HStack(spacing: 4) {
          Text("@anisharyal09").font(.system(size: 13 * fontScale))
          Image(systemName: "arrow.up.right").font(.system(size: 11)).accessibilityHidden(true)
        }.frame(minHeight: 36).contentShape(Rectangle())
      }
      .buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("GitHub profile, @anisharyal09")
      aboutProfileLinks
    }.foregroundStyle(AniCePalette.secondaryText(colorScheme)).fixedSize()
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
    return "Version " + version + (channel.isEmpty ? "" : " (" + channel + ")")
  }

  private var aboutMark: some View {
    Image("BrandMark").resizable().scaledToFit()
      .frame(width: 28, height: 28).accessibilityHidden(true)
  }

  private func aboutProductDetails(alignment: HorizontalAlignment) -> some View {
    VStack(alignment: alignment, spacing: 2) {
      Text("macOS + Android").font(.system(size: 13 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme)).fixedSize(horizontal: true, vertical: false)
      if let version = aboutVersion { Text(version).font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme)).fixedSize(horizontal: true, vertical: false) }
    }
  }

  @ViewBuilder private func aboutLink(_ title: String, detail: String, destination: String, showSeparator: Bool = true) -> some View {
    if let url = URL(string: destination) {
      let hovered = hoveredAboutLink == title
      Link(destination: url) {
        HStack(spacing: 16) {
          Text(title).font(.system(size: 13 * fontScale)).foregroundStyle(AniCePalette.primaryText(colorScheme))
          Spacer()
          HStack(spacing: 8) {
            Text(detail).font(.system(size: 12 * fontScale)).fixedSize(horizontal: true, vertical: false).foregroundStyle(hovered ? AniCePalette.primaryText(colorScheme) : AniCePalette.secondaryText(colorScheme))
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
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                  ForEach(MacSettingsCategory.allCases, id: \.self) { category in settingsCategoryButton(category) }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110 * fontScale))]) {
                  ForEach(MacSettingsCategory.allCases, id: \.self) { category in settingsCategoryButton(category) }
                }
              }.padding(.bottom, 12)
              VStack(alignment: .leading, spacing: 0) {
                settingsCategoryHeading(.general)
                preferenceSection("Appearance", id: "appearance") {
                  VStack(alignment: .leading, spacing: 8) {
                    AniCePreferenceRow("Window appearance", fontScale: fontScale) {
                      Picker("Window appearance", selection: Binding(
                        get: { WindowAppearance.stored(appearance).rawValue }, set: { appearance = $0 })) {
                          ForEach(WindowAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                      }
                      .labelsHidden().pickerStyle(.menu).aniCeControlFeedback()
                    }.frame(minHeight: 40)
                    Divider()
                    HStack(spacing: 8) {
                      Text("Text size").font(.system(size: 13 * fontScale))
                      Spacer()
                      Text("\(Int(round(fontScale * 100)))%")
                        .font(.system(size: 12 * fontScale, design: .monospaced))
                        .foregroundStyle(AniCePalette.secondaryText(colorScheme))
                        .frame(width: 44, alignment: .trailing)
                      Slider(value: $fontScale, in: 0.80...1.20, step: 0.05)
                        .frame(width: 130)
                        .accessibilityLabel("Text size")
                      if abs(fontScale - 1.0) > 0.01 {
                        Button("Reset") { fontScale = 1.0 }
                          .buttonStyle(AniCeHoverButtonStyle())
                          .font(.system(size: 12 * fontScale))
                          .foregroundStyle(AniCePalette.secondaryText(colorScheme))
                      }
                    }.frame(minHeight: 40)
                    Divider()
                    NativeGlassPreferencesView()
                  }
                }
                preferenceSection("Updates", id: "updates") {
                  VStack(alignment: .leading, spacing: 8) {
                    if let message = updates.recoveryMessage {
                      Text(message).font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                    }
                    BetaUpdatePreference(checked: $updates.includeBeta)
                    Button("Check for updates") { Task { await updates.check(force: true) } }
                      .buttonStyle(AniCeButtonStyle()).disabled(updates.checking || updates.installing)
                    if updates.installing {
                      HStack {
                        ProgressView(value: updates.progress) { Text("Downloading update…") }
                        Button("Cancel") { updates.cancelInstall() }
                      }
                    } else if updates.installProblem == nil, let release = updates.release {
                      Button("Install \(release.version.tag)") { updates.install(release.version) }
                        .disabled(updates.checking)
                    }
                    if let error = updates.installError {
                      Text(error).font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.error(colorScheme))
                    } else if updates.release != nil, let problem = updates.installProblem {
                      Text(problem).font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                    }
                    if let release = updates.release, updates.installProblem != nil || updates.installError != nil {
                      Button("Open \(release.version.tag) on GitHub") { NSWorkspace.shared.open(release.pageURL) }
                    }
                    if !updates.status.isEmpty { Text(updates.status).font(.system(size: 12 * fontScale)) }
                    AutomaticUpdateCheckOptions(checked: $updates.automaticChecks)
                  }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                preferenceSection("Connection", id: "connection") {
                  Toggle("Use local network automatically", isOn: Binding(get: { lan.automatic }, set: { lan.setAutomatic($0) }))
                    .toggleStyle(AniCePreferenceToggleStyle(description: "Enable on both devices to use Wi-Fi."))
                    .padding(.vertical, 10)
                }
                preferenceSection("This device", id: "this-device") {
                  Button { showingLocalIdentity = true } label: {
                    HStack(spacing: 10) {
                      VStack(alignment: .leading, spacing: 2) {
                        Text(identity.local?.identity.deviceName ?? "This Mac")
                        Text("Identity and security").font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                      }
                      Spacer()
                      Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AniCePalette.secondaryText(colorScheme)).accessibilityHidden(true)
                    }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
                  }.buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("This device, identity and security")
                }
                preferenceSection("Guide", id: "guide") {
                  Button { navigation.openGuide(nil) } label: {
                    HStack(spacing: 10) {
                      VStack(alignment: .leading, spacing: 2) {
                        Text("aniCe Guide")
                        Text("Features, Quick Settings tile, shortcuts, and setup")
                          .font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
                      }
                      Spacer()
                      Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AniCePalette.secondaryText(colorScheme)).accessibilityHidden(true)
                    }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
                  }.buttonStyle(AniCeHoverButtonStyle()).accessibilityLabel("aniCe Guide")
                }
                if settingsCategory == .permissions || hasMissingPermissions {
                  settingsCategoryHeading(.permissions)
                  preferenceSection("Access", id: "permissions") {
                    VStack(alignment: .leading, spacing: 24) {
                      if settingsCategory == .permissions || phoneInput.needsPostEventAccess {
                        MacPhoneInputView(model: phoneInput, showGranted: settingsCategory == .permissions)
                      }
                      if settingsCategory == .permissions || !clipboard.automaticAccessAllowed ||
                        notificationPermissionStatus.map({ !MacPermissionSummary.notificationsAllowed($0) }) == true {
                        MacPermissionSummary(clipboard: clipboard, notifications: notificationPermissionStatus,
                          showGranted: settingsCategory == .permissions,
                          onPermissionsChanged: { Task { await refreshPermissionStatus() } })
                      }
                    }.padding(.vertical, 14)
                  }
                }
                settingsCategoryHeading(.features)
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
                    TransferNotificationControls(preferences: transfer.notificationPreferences, settingsFontScale: fontScale)
                    Divider().overlay(AniCePalette.separator(colorScheme))
                    TransferAutoReceiveSettings(preferences: transfer.autoReceivePreferences, peers: pairing.peers,
                      compact: true, settingsFontScale: fontScale)
                    Divider().overlay(AniCePalette.separator(colorScheme))
                    TransferReceiveDestinationControls(model: transfer, settingsFontScale: fontScale)
                    Divider().overlay(AniCePalette.separator(colorScheme))
                    EdgeDropSettingsView(controller: edgeDrop, settingsFontScale: fontScale)
                  }
                  .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                preferenceSection("Now Playing", id: "now-playing") {
                  Toggle("Show on Overview and menu bar", isOn: Binding(get: { playback.showOnMac }, set: { playback.setShowOnMac($0) }))
                    .toggleStyle(AniCePreferenceToggleStyle())
                }
                settingsCategoryHeading(.shortcuts)
                preferenceSection("Shortcuts", id: "shortcuts") {
                  GlobalShortcutSettingsView()
                }
              }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
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
      .task(id: navigation.settingsSection) {
        guard let section = navigation.settingsSection else { return }
        settingsCategory = MacSettingsCategory.category(for: section)
        settingsScroller.request(section) {
          focusedSettingsSection = section
          settingsFocusToken = UUID()
        }
      }
      .task { await refreshPermissionStatus() }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        Task { await refreshPermissionStatus() }
      }
    }
  }

  private var hasMissingPermissions: Bool {
    phoneInput.needsPostEventAccess || !clipboard.automaticAccessAllowed ||
      notificationPermissionStatus.map { !MacPermissionSummary.notificationsAllowed($0) } == true
  }

  private func refreshPermissionStatus() async {
    notificationPermissionStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    phoneInput.refreshAccessState()
    clipboard.refreshAccess()
  }

  @ViewBuilder private func preferenceSection<Content: View>(
    _ title: String,
    id: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    if settingsCategory == .all || MacSettingsCategory.category(for: id) == settingsCategory {
      let focused = focusedSettingsSection == id
      let group = VStack(alignment: .leading, spacing: 0, content: content)
        .font(.system(size: 13 * fontScale))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .background(focused ? AniCePalette.subtleAccent(colorScheme) : AniCePalette.surface(colorScheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(focused ? AniCePalette.accent(colorScheme) : AniCePalette.separator(colorScheme), lineWidth: focused ? 1 : 0.5) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: focused)
      VStack(alignment: .leading, spacing: 8) {
        if id != "permissions" {
          Text(title).font(.system(size: 13 * fontScale, weight: .medium)).foregroundStyle(AniCePalette.primaryText(colorScheme))
        }
        group
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.bottom, 18)
      .background(SettingsScrollAnchor(id: id, coordinator: settingsScroller))
      .id(id)
    }
  }

  private func settingsCategoryButton(_ category: MacSettingsCategory) -> some View {
    Button {
      settingsCategory = category
      focusedSettingsSection = nil
    } label: {
      Text(category.rawValue)
        .font(.system(size: 12 * fontScale, weight: settingsCategory == category ? .semibold : .regular))
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(settingsCategory == category ? AniCePalette.subtleAccent(colorScheme) : .clear,
          in: RoundedRectangle(cornerRadius: 6))
    }.buttonStyle(AniCeHoverButtonStyle())
      .accessibilityAddTraits(settingsCategory == category ? .isSelected : [])
  }

  @ViewBuilder private func settingsCategoryHeading(_ category: MacSettingsCategory) -> some View {
    if settingsCategory == .all || settingsCategory == category {
      Text(category.rawValue)
        .font(.system(size: 16 * fontScale, weight: .semibold))
        .foregroundStyle(AniCePalette.primaryText(colorScheme))
        .accessibilityAddTraits(.isHeader)
        .padding(.top, 12).padding(.bottom, 16)
    }
  }

}


@MainActor final class SettingsScrollCoordinator {
  var anchors: [String: NSView] = [:]
  private var pending: (String, @MainActor @Sendable () -> Void)?

  func request(_ id: String, completion: @escaping @MainActor @Sendable () -> Void) {
    pending = (id, completion)
    resolvePending()
  }

  func resolvePending() {
    guard let (id, completion) = pending, anchors[id]?.enclosingScrollView != nil else { return }
    pending = nil
    scroll(to: id, animated: false, completion: completion)
  }

  func scroll(to id: String, animated: Bool, completion: @escaping @MainActor @Sendable () -> Void) {
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
    // Detached or reduced-motion views reveal directly; AppKit cannot reliably complete offscreen animations.
    if animated, scroll.window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        clip.animator().setBoundsOrigin(origin)
      } completionHandler: {
        Task { @MainActor in
          scroll.reflectScrolledClipView(clip)
          completion()
        }
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
    let view = SettingsAnchorView()
    view.didAttach = { [weak coordinator] in coordinator?.resolvePending() }
    view.didDetach = { [weak coordinator, weak view] in
      if coordinator?.anchors[id] === view { coordinator?.anchors.removeValue(forKey: id) }
    }
    coordinator.anchors[id] = view
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    coordinator.anchors[id] = view
  }
  static func dismantleNSView(_ view: NSView, coordinator: ()) {
    (view as? SettingsAnchorView)?.didAttach = {}
    (view as? SettingsAnchorView)?.didDetach()
    (view as? SettingsAnchorView)?.didDetach = {}
  }
}

@MainActor private final class SettingsAnchorView: NSView {
  var didAttach: () -> Void = {}
  var didDetach: () -> Void = {}
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil {
      DispatchQueue.main.async { [weak self] in self?.didAttach() }
    } else { didDetach() }
  }
}

private struct DeskDeckSettingsView: View {
  @Bindable var model: MacDeskDeckModel
  let peers: [PeerTrustRecord]
  @Environment(\.colorScheme) private var colorScheme
  @State private var notice = ""
  @AppStorage("ui.fontScale") private var fontScale = 1.0

  private var androidPeers: [PeerTrustRecord] { peers.filter { $0.peer.platform == "android" } }

  var body: some View {
    let catalogGeneration = model.catalogGeneration
    return VStack(alignment: .leading, spacing: 8) {
      Text("Choose which apps each phone can launch from Desk Deck.")
        .font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
      if androidPeers.isEmpty {
        Text("Pair a phone to add approved apps.").font(.system(size: 12 * fontScale))
      } else {
        ForEach(androidPeers, id: \.peer.fingerprint) { record in
          let peer = record.peer
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(peer.displayName).font(.system(size: 13 * fontScale, weight: .medium)).lineLimit(1)
              Spacer()
              Button("Add app…") { chooseApplication(for: peer) }
                .disabled(model.availableApprovalCount(for: peer) >= 32)
            }.frame(minHeight: 32)
            let apps = model.approvedApps(for: peer)
            if apps.isEmpty {
              Text("No apps added").font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
            }
            ForEach(apps) { app in
              HStack(spacing: 10) {
                Text(app.name).lineLimit(1)
                Spacer(minLength: 8)
                if !model.applicationIsAvailable(app) {
                  Text("Unavailable").font(.system(size: 12 * fontScale))
                    .foregroundStyle(AniCePalette.secondaryText(colorScheme)).lineLimit(1)
                }
                Button("Remove") { model.removeApprovedApp(id: app.id, for: peer) }
                  .accessibilityLabel("Remove \(app.name) for \(peer.displayName)")
              }.frame(minHeight: 32)
            }
            if model.availableApprovalCount(for: peer) >= 32 {
              Text("This phone has reached the 32-app limit.").font(.system(size: 12 * fontScale))
                .foregroundStyle(AniCePalette.secondaryText(colorScheme))
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
          if peer.fingerprint != androidPeers.last?.peer.fingerprint {
            Divider().overlay(AniCePalette.separator(colorScheme)).padding(.vertical, 2)
          }
        }
      }
      if !notice.isEmpty { Text(notice).font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme)) }
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
