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
  let navigation: ConnectionNavigation
  let openMainWindow: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("aniCe").font(.headline)
        Spacer()
        Menu {
          if session.state == "Secured" || lan.state == "Secured" {
            Button("Disconnect device") { session.disconnect(); lan.disconnect() }
          }
          Button("Manage devices") { navigation.open(.devices, route: .pairing, present: openMain) }
          Button("Settings") { navigation.open(.settings, present: openMain) }
          Button("Quit aniCe") { NSApp.terminate(nil) }
        } label: { Image(systemName: "ellipsis") }
          .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More options")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          deviceContent
          if hasLiveActivity {
            Divider()
            liveActivitySection
          }
          if let sendFilesAction {
            Divider()
            Button(action: sendFilesAction) {
              HStack(spacing: 12) {
                Image(systemName: "paperplane").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                  Text("Send files").font(.subheadline.weight(.medium))
                  if let peer = transfer.activeChannel?.descriptor.peer {
                    Text("Choose files for " + peer.deviceName).font(.caption)
                      .foregroundStyle(AniCePalette.secondaryText(colorScheme))
                  }
                }
                Spacer()
                Image(systemName: "chevron.right").accessibilityHidden(true)
              }.padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain)
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
  private let onOpen: () -> Void
  private let onManage: () -> Void
  private let onDevices: () -> Void

  init(content: CompanionView, onOpen: @escaping () -> Void,
    onManage: @escaping () -> Void, onDevices: @escaping () -> Void) {
    self.playback = content.playback
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
      item.popUpMenu(Self.makeMenu(target: self))
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

  static func makeMenu(target: AnyObject) -> NSMenu {
    let menu = NSMenu()
    for (title, action) in [("Open aniCe", #selector(openMain)),
                             ("Devices", #selector(openDevices)),
                             ("Manage devices", #selector(manageDevices))] {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
      entry.target = target
      menu.addItem(entry)
    }
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
