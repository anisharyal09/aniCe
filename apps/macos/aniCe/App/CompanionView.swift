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
  let navigation: ConnectionNavigation
  let openMainWindow: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Text("aniCe").font(.headline)
        Spacer()
        Menu {
          // Quick actions and clipboard tools
          Button("Quick Paste Tray (⌥⌘V)") {
            PasteTrayController.shared.show()
          }
          if clipboard.isPaused {
            Button("Resume clipboard (\(clipboard.pauseStatusText ?? "Paused"))") {
              clipboard.resume()
            }
          } else {
            Menu("Pause clipboard") {
              ForEach(ClipboardPauseDuration.allCases) { duration in
                Button(duration.rawValue) { clipboard.pause(for: duration) }
              }
            }
          }

          Divider()

          // Device connection and pairing navigation
          if session.state == "Secured" || lan.state == "Secured" {
            Button("Disconnect device") { session.disconnect(); lan.disconnect() }
          }
          Button("Manage devices") { navigation.open(.devices, route: .pairing, present: openMain) }

          Divider()

          // Preferences and application termination
          Button("Settings") { navigation.open(.settings, present: openMain) }
          Button("Quit aniCe") { NSApp.terminate(nil) }
        } label: { Image(systemName: "ellipsis") }
          .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More options")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          deviceContent
          if clipboard.recent != nil {
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
              ViewThatFits(in: .horizontal) {
                HStack { sendActions }
                VStack(alignment: .leading, spacing: 8) { sendActions }
              }
              if let peer = transfer.activeChannel?.descriptor.peer, sendFilesAction != nil {
                Text("To " + peer.deviceName).font(.caption).foregroundStyle(AniCePalette.secondaryText(colorScheme))
              }
              if !["Ready to share text", "Clipboard received", "Clipboard delivered"].contains(clipboard.status) {
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
    HStack(spacing: 6) {
      if clipboard.selected.map(clipboard.supports) == true { ClipboardSendButton(model: clipboard) }
      Button { PasteTrayController.shared.toggle() } label: {
        Image(systemName: "rectangle.stack").frame(width: 20, height: 18)
      }
      .buttonStyle(.bordered).controlSize(.small)
      .accessibilityLabel("Open clipboard tray")
      .help("Open clipboard tray (⌥⌘V)")
    }
    if let sendFilesAction {
      Button(action: sendFilesAction) { Label("Send files", systemImage: "paperplane") }
        .buttonStyle(.bordered).controlSize(.small)
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
        MacSessionView(peers: pairing.peers, model: session, lan: lan,
          details: .constant(false), diagnostics: .constant(false), compact: true,
          onManageDevices: { navigation.open(.devices, present: openMain) },
          onOpenDevice: { peer in navigation.open(.devices, peer: peer, present: openMain) })
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text("No devices paired yet")
            .font(.headline)
          Button("Pair a device") { navigation.open(.devices, route: .pairing, present: openMain) }
            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
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
      }.buttonStyle(.plain).foregroundStyle(AniCePalette.accent(colorScheme))
    }
  }
}

// Owns status-item presentation only; closing either surface leaves shared sessions running.
@MainActor final class CompanionHost: NSObject, NSPopoverDelegate {
  static weak var currentHost: CompanionHost?
  var isPickingFile = false

  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let popover = NSPopover()
  private let playback: MacPlaybackModel
  private let clipboard: MacClipboardModel
  private let onOpen: () -> Void
  private let onManage: () -> Void
  private let onDevices: () -> Void

  init(content: CompanionView, onOpen: @escaping () -> Void,
    onManage: @escaping () -> Void, onDevices: @escaping () -> Void) {
    self.playback = content.playback
    self.clipboard = content.clipboard
    self.onOpen = onOpen
    self.onManage = onManage
    self.onDevices = onDevices
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
      let image = NSImage(systemSymbolName: "laptopcomputer.and.iphone", accessibilityDescription: "aniCe")
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
      item.popUpMenu(Self.makeMenu(target: self, clipboard: clipboard))
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

  /// Constructs the right-click status bar menu with distinct sections:
  /// 1. Navigation items (Open aniCe, Devices, Manage devices)
  /// 2. Feature options (Clipboard Pause submenu or Resume action) separated by dividers
  /// 3. App termination
  static func makeMenu(target: AnyObject, clipboard: MacClipboardModel? = nil) -> NSMenu {
    let menu = NSMenu()
    for (title, action) in [("Open aniCe", #selector(openMain)),
                             ("Devices", #selector(openDevices)),
                             ("Manage devices", #selector(manageDevices))] {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
      entry.target = target
      menu.addItem(entry)
    }

    // Feature controls section (separated from navigation)
    menu.addItem(.separator())
    if let clipboard, clipboard.isPaused {
      // Direct click resumes observation immediately if already paused.
      let resume = NSMenuItem(title: "Resume clipboard (\(clipboard.pauseStatusText ?? "Paused"))", action: #selector(resumeClipboard), keyEquivalent: "")
      resume.target = target
      menu.addItem(resume)
    } else {
      // When active, clicking the parent item pauses indefinitely; submenu allows picking timed durations.
      let pauseItem = NSMenuItem(title: "Pause clipboard", action: #selector(pauseClipboardItem), keyEquivalent: "")
      pauseItem.target = target
      let pauseSubmenu = NSMenu()
      for duration in ClipboardPauseDuration.allCases {
        let subItem = NSMenuItem(title: duration.rawValue, action: #selector(pauseDurationSelected(_:)), keyEquivalent: "")
        subItem.target = target
        subItem.representedObject = duration
        pauseSubmenu.addItem(subItem)
      }
      pauseItem.submenu = pauseSubmenu
      menu.addItem(pauseItem)
    }

    // App lifecycle section
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit aniCe", action: #selector(quitApp), keyEquivalent: "")
    quit.target = target
    menu.addItem(quit)
    return menu
  }

  /// AppKit action to resume observation when user clicks "Resume clipboard".
  @objc private func resumeClipboard() {
    clipboard.resume()
  }

  /// AppKit action when user directly clicks "Pause clipboard" root item (pauses until turned back on).
  @objc private func pauseClipboardItem() {
    clipboard.pause(for: .untilTurnedOn)
  }

  /// AppKit action when user selects a specific timed interval from the "Pause clipboard" submenu.
  @objc private func pauseDurationSelected(_ sender: NSMenuItem) {
    guard let duration = sender.representedObject as? ClipboardPauseDuration else { return }
    clipboard.pause(for: duration)
  }

  @objc private func openMain() {
    popover.performClose(nil)
    NSApp.activate(ignoringOtherApps: true)
    onOpen()
  }

  @objc private func openDevices() {
    popover.performClose(nil)
    NSApp.activate(ignoringOtherApps: true)
    onDevices()
  }

  @objc private func manageDevices() {
    popover.performClose(nil)
    NSApp.activate(ignoringOtherApps: true)
    onManage()
  }
  @objc private func quitApp() { NSApp.terminate(nil) }
  func close() { popover.performClose(nil) }

  func popoverDidShow(_ notification: Notification) { playback.presented("companion",true) }

  func popoverDidClose(_ notification: Notification) {
    playback.presented("companion",false)
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
