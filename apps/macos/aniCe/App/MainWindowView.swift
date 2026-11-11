// SPDX-License-Identifier: GPL-3.0-or-later
// Hosts workspace navigation and presentation leases for application-owned native features.
import AppKit
import SwiftUI
import Observation

struct MainWindowView: View {
  let delegate: AppDelegate
  @Bindable var identity: IdentityViewModel
  let discovery: MacDiscoveryModel
  let pairing: MacPairingModel
  let session: MacSessionModel
  let lan: MacLanSessionModel
  let playback: MacPlaybackModel
  let transfer: MacTransferModel
  let edgeDrop: MacEdgeDropController
  let clipboard: MacClipboardModel
  let findDevice: MacFindDeviceModel
  let findNotifier: MacFindDeviceNotifier?
  let sms: MacSmsModel
  let keyboardTrackpad: MacKeyboardTrackpadModel
  let phoneInput: MacPhoneInputModel
  let smsPreferences: SmsPreferences
  let onInitialRender: () -> Void
  @Bindable var dndSync: MacDndSyncModel
  @Bindable var deskDeck: MacDeskDeckModel
  @Bindable var phonePower: MacPhonePowerModel
  @Bindable var navigation: ConnectionNavigation
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.openWindow) private var openWindow
  @State private var systemAppearance = SystemAppearance()
  @State var activeSettingsSection = "appearance"
  @State var hoveredSettingsSection: String?
  @State var hoveredAboutLink: String?
  @State var focusedSettingsSection: String?
  @State var settingsFocusToken = UUID()
  @State var settingsScroller = SettingsScrollCoordinator()
  @State var showingLocalIdentity = false
  var colorScheme: ColorScheme {
    WindowAppearance.stored(appearance).colorScheme(system: systemAppearance.colorScheme)
  }

  private var mediaSurfaceVisible: Bool {
    (navigation.destination == .home && playback.showOnMac) ||
      (navigation.destination == .features && navigation.featurePanel == .playback)
  }

  @AppStorage("window.appearance") var appearance = WindowAppearance.system.rawValue
  @AppStorage("ui.fontScale") var fontScale: Double = 1.0

  private var dynamicTypeSizeForScale: DynamicTypeSize {
    if fontScale < 0.88 { return .small }
    else if fontScale < 0.98 { return .medium }
    else if fontScale <= 1.05 { return .large }
    else if fontScale <= 1.15 { return .xLarge }
    else { return .xxLarge }
  }

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
          Image("BrandMark")
            .resizable().scaledToFit().frame(width: 22, height: 22)
            .accessibilityHidden(true)
          AniCeWordmark(size: 21 * fontScale, weight: .semibold)
        }.foregroundStyle(AniCePalette.primaryText(colorScheme))
          .padding(.horizontal, 14).padding(.top, 28).padding(.bottom, 24)
        Text("Workspace").font(.system(size: 11 * fontScale)).foregroundStyle(AniCePalette.secondaryText(colorScheme))
          .padding(.horizontal, 14).padding(.bottom, 12)
        ForEach([AppDestination.home, .devices, .features, .favourites]) { sidebarItem($0) }
        Spacer(minLength: 24)
        sidebarItem(.settings)
        sidebarItem(.about)
      }.padding(.horizontal, 14).padding(.bottom, 24)
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        .background(AniCePalette.secondarySurface(colorScheme))
        .overlay(alignment: .trailing) { AniCePalette.separator(colorScheme).frame(width: 0.5) }
        .overlay(alignment: .top) { AniCePalette.separator(colorScheme).frame(height: 0.5) }
        .toolbar {
          ToolbarItemGroup(placement: .navigation) {
            Button(action: navigation.goBack) { Image(systemName: "arrow.left") }
              .disabled(!navigation.canGoBack).help("Back")
              .accessibilityLabel("Back").keyboardShortcut("[", modifiers: .command)
            Button(action: navigation.goForward) { Image(systemName: "arrow.right") }
              .disabled(!navigation.canGoForward).help("Forward")
              .accessibilityLabel("Forward").keyboardShortcut("]", modifiers: .command)
          }
        }
    } detail: { detailContent }
    .sheet(isPresented: $showingLocalIdentity) {
      IdentityView(model: identity).preferredColorScheme(colorScheme)
    }
    .disclosureGroupStyle(ClickableDisclosureStyle())
    .preferredColorScheme(colorScheme)
    .frame(minWidth: 620, minHeight: 420)
    .tint(AniCePalette.primaryText(colorScheme))
    .font(.system(size: 13 * fontScale))
    .task {
      // Let SwiftUI present the first window before loading saved identity or starting radios.
      await Task.yield()
      onInitialRender()
      if !IdentityView.isTesting {
        await identity.load()
        if identity.local != nil { await pairing.refresh() }
      }
    }
    .onChange(of: identity.local?.identity.fingerprint) { _, _ in Task { await pairing.refresh() } }
    .onAppear { updateKeyboardTrackpadTargets() }
    .onChange(of: pairing.peers.map(\.peer)) { _, _ in updateKeyboardTrackpadTargets() }
    .onChange(of: session.authenticatedPeer) { _, _ in updateKeyboardTrackpadTargets() }
    .onChange(of: lan.authenticatedPeer) { _, _ in updateKeyboardTrackpadTargets() }
    .onChange(of: navigation.focusedPeer) { _, _ in updateKeyboardTrackpadTargets() }
    // Pairing signs the identity snapshot captured by its invitation; renaming requires a fresh invitation.
    .onChange(of: identity.local?.identity.deviceName) { old, new in
      if old != nil, old != new, pairing.active {
        pairing.cancel(message: "Device name updated. Start a fresh invitation to share it.")
      }
    }
    .onChange(of:navigation.destination) { _,_ in if !IdentityView.isTesting { playback.presented("main",mediaSurfaceVisible) } }
    .onChange(of:navigation.featurePanel) { _,_ in if !IdentityView.isTesting { playback.presented("main",mediaSurfaceVisible) } }
    .onChange(of:playback.showOnMac) { _,_ in if !IdentityView.isTesting { playback.presented("main",mediaSurfaceVisible) } }
    .onDisappear { playback.presented("main",false) }
    .onAppear {
      if !IdentityView.isTesting { playback.presented("main",mediaSurfaceVisible) }
      let action = openWindow
      delegate.reopenMainWindow = {
        action(id: "main")
        playback.presented("main",mediaSurfaceVisible)
      }
    }
  }

  private var detailContent: some View {
    VStack(spacing: 0) {
      pendingRequestRows
      destinationContent
    }
    .navigationTitle("aniCe")
    .toolbarBackground(AniCePalette.background(colorScheme), for: .windowToolbar)
    .toolbarBackground(.visible, for: .windowToolbar)
    .background(AniCePalette.background(colorScheme))
    .overlay(alignment: .top) { AniCePalette.separator(colorScheme).frame(height: 0.5) }
    .background(TitlebarWordmarkFormatter(colorScheme: colorScheme))
  }

  @ViewBuilder private var pendingRequestRows: some View {
    if pairing.active && !(navigation.destination == .devices && navigation.deviceRoute == .pairing) {
      PendingRequestRow(title: pairing.phase == "approval" ? "Review pairing" : "Pairing in progress",
        detail: pairing.status) { navigation.show(.devices, route: .pairing) }
    }
    if let offer = transfer.pendingOffer,
      navigation.destination != .home && !(navigation.destination == .features && navigation.featurePanel == .files) {
      PendingRequestRow(title: "Incoming files", detail: "\(offer.files.count) files from \(offer.peerName)") {
        navigation.openFeature(.files)
      }
    }
  }

  @ViewBuilder private var destinationContent: some View {
    switch navigation.destination {
    case .home: homeContent
    case .devices: devicesContent
    case .features: featureDestination(favouritesOnly: false)
    case .favourites: featureDestination(favouritesOnly: true)
    case .about: aboutContent
    case .settings: settingsContent
    }
  }

  private func featureDestination(favouritesOnly: Bool) -> some View {
    FeaturesView(playback: playback, transfer: transfer, clipboard: clipboard, findDevice: findDevice,
      sms: sms, keyboardTrackpad: keyboardTrackpad, smsPreferences: smsPreferences,
      findNotifier: findNotifier, peers: pairing.peers, edgeDrop: edgeDrop,
      navigation: navigation, favouritesOnly: favouritesOnly)
  }

  private func updateKeyboardTrackpadTargets() {
    let connected = Set([session.authenticatedPeer, lan.authenticatedPeer].compactMap { $0?.deviceId })
    keyboardTrackpad.updateTargets(pairing.peers.map(\.peer), connectedPeerIDs: connected, peerContextID: navigation.focusedPeer,
      connectedBLEPeerID: session.authenticatedPeer?.deviceId)
  }

  private func sidebarItem(_ destination: AppDestination) -> some View {
    let selected = navigation.destination == destination
    return Button {
      navigation.select(destination)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: destination.symbol).frame(width: 18).accessibilityHidden(true)
        Text(destination.rawValue).font(.system(size: 13 * fontScale, weight: selected ? .medium : .regular))
        Spacer(minLength: 0)
      }
      .foregroundStyle(selected ? AniCePalette.primaryText(colorScheme) : AniCePalette.secondaryText(colorScheme))
      .padding(.horizontal, 14).padding(.vertical, 8)
      .frame(minHeight: 34)
      .background(selected ? AniCePalette.subtleAccent(colorScheme) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
      .overlay {
        if selected {
          RoundedRectangle(cornerRadius: 7).stroke(AniCePalette.separator(colorScheme), lineWidth: 0.5)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(AniCeHoverButtonStyle())
    .accessibilityAddTraits(selected ? [.isSelected] : [])
    .padding(.bottom, 4)
  }

}

struct ClickableDisclosureStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Button { configuration.isExpanded.toggle() } label: {
        HStack {
          HStack {
            Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.forward")
              .font(.caption).accessibilityHidden(true)
            configuration.label
          }.aniCeControlFeedback()
          Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
      if configuration.isExpanded { configuration.content }
    }
  }
}


// Keeps pending decisions visible while the person visits another section.
struct PendingRequestRow: View {
  let title: String
  let detail: String
  let review: () -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Button(action: review) {
      HStack(spacing: 12) {
        Image(systemName: "info.circle").accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.callout.weight(.medium))
          Text(detail).font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Text("Review").font(.callout).foregroundStyle(AniCePalette.accent(scheme))
          .padding(.horizontal, 10).padding(.vertical, 5)
          .overlay { RoundedRectangle(cornerRadius: 6).stroke(AniCePalette.separator(scheme)) }
      }.padding(.horizontal, 24).padding(.vertical, 12).contentShape(Rectangle())
    }.buttonStyle(AniCeHoverButtonStyle())
      .foregroundStyle(AniCePalette.primaryText(scheme))
      .background(AniCePalette.secondarySurface(scheme))
      .overlay(alignment: .bottom) { Divider() }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(title + ". " + detail + ". Review")
  }
}
