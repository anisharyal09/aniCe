// SPDX-License-Identifier: GPL-3.0-or-later
// Presents shared device and transport actions in the native menu-bar companion.
import AppKit
import SwiftUI

struct CompanionView: View {
  let identity: IdentityViewModel
  let discovery: MacDiscoveryModel
  let pairing: MacPairingModel
  let session: MacSessionModel
  let lan: MacLanSessionModel
  let playback: MacPlaybackModel
  let transfer: MacTransferModel
  let clipboard: MacClipboardModel
  let keyboardTrackpad: MacKeyboardTrackpadModel
  @Bindable var floatingKeyboard: FloatingKeyboardController
  @Bindable var phonePower: MacPhonePowerModel
  let navigation: ConnectionNavigation
  let openMainWindow: () -> Void
  @AppStorage("ui.companionPinnedFeatures") private var companionPinnedFeatures = AppFeature.defaultPinnedToCompanion
  @AppStorage("ui.fontScale") private var fontScale = 1.0
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Text("aniCe").font(.headline)
        Spacer()
        Menu {
          Button("Quick Paste Tray (⌥⌘V)") {
            PasteTrayController.shared.show()
          }
          Button("Manage devices") { navigation.open(.devices, present: openMain) }
          Button("Settings") { navigation.open(.settings, present: openMain) }
          Button("Quit aniCe") { NSApp.terminate(nil) }
        } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
          .menuStyle(.borderlessButton).aniCeControlFeedback()
          .menuIndicator(.hidden).fixedSize().accessibilityLabel("More options")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          deviceContent
          if pairing.hasTrustedAndroid, clipboard.recent != nil {
            Divider()
            ClipboardActivityView(model: clipboard, compact: true, open: { navigation.openFeature(.clipboard); openMainWindow() })
          }
          if hasLiveActivity {
            Divider()
            liveActivitySection
          }
          Group {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
              sendActions
              if pairing.hasTrustedAndroid,
                 !["Ready to share text", "Clipboard received", "Clipboard delivered"].contains(clipboard.status) {
                Text(clipboard.status).font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
              }
            }
          }
        }
      }.fixedSize(horizontal: false, vertical: true).frame(maxHeight: 520)
      footer
    }
    .padding(16)
    .frame(width: 350)
    .background(AniCePalette.surface(colorScheme))
    .tint(AniCePalette.primaryText(colorScheme))
    .task {
      if !IdentityView.isTesting {
        await identity.load()
        if identity.local != nil { await pairing.refresh() }
      }
    }
  }

  private func openMain() {
    openMainWindow()
  }

  @ViewBuilder private var sendActions: some View {
    VStack(alignment: .leading, spacing: 8) {
      companionActionsGrid
      pinnedQuickActions
    }
  }

  private var companionActionsGrid: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        if clipboard.selected.map(clipboard.supports) == true {
          ClipboardSendButton(model: clipboard, compact: true)
            .frame(maxWidth: .infinity)
        }
        Button { PasteTrayController.shared.toggle() } label: {
          Label { Text("Paste tray") } icon: {
            Image(systemName: "rectangle.stack").foregroundStyle(AniCePalette.secondaryText(colorScheme))
          }
        }
        .buttonStyle(AniCeButtonStyle(compact: true))
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Open clipboard tray")
        .help("Open clipboard tray (⌥⌘V)")
      }

      HStack(spacing: 8) {
        if let sendFilesAction {
          Button(action: sendFilesAction) {
            Label { Text("Send files") } icon: {
              Image(systemName: "paperplane").foregroundStyle(AniCePalette.secondaryText(colorScheme))
            }
          }
          .buttonStyle(AniCeButtonStyle(compact: true))
          .frame(maxWidth: .infinity)
        }
        Button { floatingKeyboard.toggleVisibility() } label: {
          Label {
            Text(floatingKeyboard.isVisible ? "Hide Floating Key" : "Floating Key")
          } icon: {
            Image(systemName: "keyboard").foregroundStyle(AniCePalette.secondaryText(colorScheme))
          }
        }
        .buttonStyle(AniCeButtonStyle(compact: true))
        .frame(maxWidth: .infinity)
        .accessibilityLabel(floatingKeyboard.isVisible ? "Hide Floating Key" : "Show Floating Key")
        .help("Show Floating Key to type directly on Android; right-click for full controls including trackpad (⌥⌘K).")
      }
    }
  }

  @ViewBuilder private var pinnedQuickActions: some View {
    let pinned = AppFeature.pinnedToCompanion(in: companionPinnedFeatures)
    if !pinned.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("Quick actions").font(.system(size: 11 * fontScale, weight: .medium))
          .foregroundStyle(AniCePalette.secondaryText(colorScheme))
        ScrollView(.horizontal) {
          HStack(spacing: 6) {
            ForEach(pinned) { feature in
              Button {
                executeQuickAction(feature)
              } label: {
                HStack(spacing: 4) {
                  Image(systemName: feature.symbol).font(.system(size: 10 * fontScale))
                  Text(feature.title).font(.system(size: 11 * fontScale))
                }
                .foregroundStyle(AniCePalette.secondaryText(colorScheme))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(AniCePalette.separator(colorScheme), lineWidth: 0.75) }
              }
              .buttonStyle(AniCeHoverButtonStyle())
            }
          }
        }
        .scrollIndicators(.hidden)
      }
    }
  }

  private func executeQuickAction(_ feature: AppFeature) {
    switch feature {
    case .files:
      if let sendFilesAction {
        sendFilesAction()
      } else {
        navigation.openFeature(.files)
        openMain()
      }
    case .keyboardTrackpad, .clipboard, .messages, .findDevice, .playback:
      navigation.openFeature(feature)
      openMain()
    }
  }

  // Gated on idle state, peer compatibility and readiness matching TransferView.idleContent.
  // Hides the row while a transfer is active/visible, avoiding redundant duplicate actions.
  private var sendFilesAction: (() -> Void)? {
    guard transfer.state == .idle && transfer.peerConnected && transfer.peerCompatible && !transfer.preparing else { return nil }
    return {
      promptAndSendTransferFiles(model: transfer)
    }
  }

  private var deviceContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      if pairing.active {
        Text(pairing.status).fixedSize(horizontal: false, vertical: true)
        Button("Review pairing") { navigation.open(.devices, route: .pairing, present: openMain) }
        Button("Stop pairing") { pairing.cancel() }
      } else if session.allowing || lan.allowing || pairing.hasTrustedAndroid {
        MacSessionView(peers: pairing.peers, model: session, lan: lan, phonePower: phonePower,
          details: .constant(false), diagnostics: .constant(false), compact: true, keyboardTrackpad: keyboardTrackpad,
          onManageDevices: { navigation.open(.devices, present: openMain) },
          onOpenDevice: { peer in navigation.open(.devices, peer: peer, present: openMain) })
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text("Add your Android phone")
            .font(.headline)
          Text("Open aniCe to pair your phone.")
            .font(.caption)
            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
          Button("Add device") { navigation.open(.devices, route: .pairing, present: openMain) }
            .buttonStyle(AniCeButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var hasLiveActivity: Bool {
    transfer.preparing || transfer.state != .idle || (playback.showOnMac && playback.compactVisible)
  }

  @ViewBuilder
  private var liveActivitySection: some View {
    if hasLiveActivity {
      VStack(alignment: .leading, spacing: 16) {
        if playback.showOnMac && playback.compactVisible {
          MediaView(model: playback, compact: true, visible: playback.companionVisible)
        }
        if transfer.preparing || transfer.state != .idle {
          if playback.showOnMac && playback.compactVisible { Divider() }
          TransferView(model: transfer, compact: true)
        }
      }
    }
  }

  private var footer: some View {
    VStack(spacing: 12) {
      Divider()
      Button(action: openMain) {
        HStack {
          Text("Open aniCe")
          Spacer()
          Image(systemName: "arrow.up.right").accessibilityHidden(true)
        }.contentShape(Rectangle())
      }.buttonStyle(AniCeHoverButtonStyle()).foregroundStyle(AniCePalette.accent(colorScheme))
    }
  }
}

// Owns status-item presentation only; closing either surface leaves shared sessions running.
@MainActor final class CompanionHost: NSObject, NSPopoverDelegate {
  static weak var currentHost: CompanionHost?
  var isPickingFile = false

  private let item = NSStatusBar.system.statusItem(withLength: 24)
  private let popover = NSPopover()
  private let playback: MacPlaybackModel
  private let floatingKeyboard: FloatingKeyboardController
  private let onOpen: () -> Void
  private let onManage: () -> Void
  private var handoffCompletion: (() -> Void)?
  private var suppressRefocusAfterClose = false

  init(content: CompanionView, floatingKeyboard: FloatingKeyboardController, onOpen: @escaping () -> Void,
    onManage: @escaping () -> Void) {
    self.playback = content.playback
    self.floatingKeyboard = floatingKeyboard
    self.onOpen = onOpen
    self.onManage = onManage
    super.init()
    Self.currentHost = self
    let controller = CompanionHostingController(rootView: content)
    controller.onCancel = { [weak self] in self?.close() }
    controller.sizingOptions = [.preferredContentSize]
    popover.contentViewController = controller
    popover.behavior = .transient
    popover.animates = false
    popover.delegate = self
    if let button = item.button {
      let image = NSImage(named: "StatusBarMark")
        ?? NSImage(systemSymbolName: "laptopcomputer.and.iphone", accessibilityDescription: "aniCe")
      image?.size = NSSize(width: 21.5, height: 21.5)
      image?.isTemplate = true
      button.image = image
      button.setAccessibilityLabel("aniCe")
      button.target = self
      button.action = #selector(clicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
  }

  @objc private func clicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    if Self.showsContextMenu(eventType: event?.type,
      modifiers: event?.modifierFlags ?? []) {
      popover.performClose(nil)
      item.popUpMenu(Self.makeMenu(target: self, floatingKeyboardVisible: floatingKeyboard.isVisible))
    } else if popover.isShown {
      popover.performClose(nil)
    } else {
      popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
    }
  }

  static func showsContextMenu(eventType: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags) -> Bool {
    eventType == .rightMouseUp || eventType == .rightMouseDown || modifiers.contains(.control)
  }

  /// Constructs the status bar menu for window routes, Floating Key and Quit.
  static func makeMenu(target: AnyObject, floatingKeyboardVisible: Bool = false) -> NSMenu {
    let menu = NSMenu()
    for (title, action) in [("Open aniCe", #selector(openMain)),
                             ("Manage devices", #selector(manageDevices))] {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
      entry.target = target
      menu.addItem(entry)
    }

    let keyboard = NSMenuItem(title: (floatingKeyboardVisible ? "Hide Floating Key" : "Show Floating Key") + "  ⌥⌘K",
      action: #selector(toggleFloatingKeyboard), keyEquivalent: "")
    keyboard.target = target
    menu.addItem(keyboard)

    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit aniCe", action: #selector(quitApp), keyEquivalent: "")
    quit.target = target
    menu.addItem(quit)
    return menu
  }

  @objc private func openMain() {
    popover.performClose(nil)
    NSApp.activate(ignoringOtherApps: true)
    onOpen()
  }

  @objc private func manageDevices() {
    popover.performClose(nil)
    NSApp.activate(ignoringOtherApps: true)
    onManage()
  }
  @objc private func toggleFloatingKeyboard() { floatingKeyboard.toggleVisibility() }
  @objc private func quitApp() { NSApp.terminate(nil) }
  func close() { popover.performClose(nil) }

  var isShown: Bool { popover.isShown }

  @discardableResult
  func closeForInputHandoff(completion: @escaping () -> Void) -> Bool {
    guard !isPickingFile else { return false }
    guard popover.isShown else { completion(); return true }
    handoffCompletion = completion
    suppressRefocusAfterClose = true
    popover.performClose(nil)
    guard !popover.isShown else {
      handoffCompletion = nil
      suppressRefocusAfterClose = false
      return false
    }
    return true
  }

  func popoverDidShow(_ notification: Notification) { playback.presented("companion",true) }

  func popoverDidClose(_ notification: Notification) {
    playback.presented("companion",false)
    if suppressRefocusAfterClose {
      suppressRefocusAfterClose = false
      let completion = handoffCompletion
      handoffCompletion = nil
      completion?()
      return
    }
    if let button = item.button { button.window?.makeFirstResponder(button) }
  }

  func popoverShouldClose(_ popover: NSPopover) -> Bool {
    return !isPickingFile
  }

  func refocus() {
    if popover.isShown {
      popover.contentViewController?.view.window?.makeKey()
    }
  }
}

@MainActor private final class CompanionHostingController: NSHostingController<CompanionView> {
  var onCancel: () -> Void = {}
  override func cancelOperation(_ sender: Any?) { onCancel() }
}
