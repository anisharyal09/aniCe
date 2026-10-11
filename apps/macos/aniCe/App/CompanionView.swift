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
  let playback: MacPlayback
  let navigation: ConnectionNavigation
  let openMainWindow: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if pairing.peers.count > 3 { ScrollView { deviceContent }.frame(maxHeight: 520) }
      else { deviceContent }
      if playback.showOnMac && !playback.playback.source.isEmpty { MediaView(model:playback,compact:true,visible:playback.companionVisible,playerPicker:false) { navigation.open(.features,present:openMain) } }
      footer
    }
    .padding(24)
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

  private var footer: some View {
    HStack(spacing: 12) {
      Button("Open aniCe") {
        openMain()
      }
      .buttonStyle(.borderedProminent)
      .foregroundStyle(AniCePalette.onAccent(colorScheme))
      .frame(maxWidth: .infinity)

      Menu {
        Button("Settings") {
          navigation.open(.settings, present: openMain)
        }
        Button("Quit aniCe") { NSApp.terminate(nil) }
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("More options")
    }
  }
}

// Owns status-item presentation only; closing either surface leaves shared sessions running.
@MainActor final class CompanionHost: NSObject, NSPopoverDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let popover = NSPopover()
  private let playback: MacPlayback
  private let onOpen: () -> Void
  private let onManage: () -> Void
  private let onDetails: () -> Void

  init(content: CompanionView, onOpen: @escaping () -> Void,
    onManage: @escaping () -> Void, onDetails: @escaping () -> Void) {
    self.playback = content.playback
    self.onOpen = onOpen
    self.onManage = onManage
    self.onDetails = onDetails
    super.init()
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
    if Self.showsContextMenu(eventType: NSApp.currentEvent?.type,
      modifiers: NSApp.currentEvent?.modifierFlags ?? []) {
      popover.performClose(nil)
      Self.makeMenu(target: self).popUp(positioning: nil,
        at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    } else if popover.isShown { popover.performClose(nil) }
    else {
      NSApp.activate()
      popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
    }
  }

  static func showsContextMenu(eventType: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags) -> Bool {
    eventType == .rightMouseUp || modifiers.contains(.control)
  }

  static func makeMenu(target: AnyObject) -> NSMenu {
    let menu = NSMenu()
    for (title, action) in [("Open aniCe", #selector(openMain)),
                             ("Connection details", #selector(openDetails)),
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

  @objc private func openMain() { popover.performClose(nil); onOpen() }
  @objc private func openDetails() { popover.performClose(nil); onDetails() }
  @objc private func manageDevices() { popover.performClose(nil); onManage() }
  @objc private func quitApp() { NSApp.terminate(nil) }
  func close() { popover.performClose(nil) }

  func popoverDidShow(_ notification: Notification) { playback.presented("companion",true) }

  func popoverDidClose(_ notification: Notification) {
    playback.presented("companion",false)
    if let button = item.button { button.window?.makeFirstResponder(button) }
  }
}

@MainActor private final class CompanionHostingController: NSHostingController<CompanionView> {
  var onCancel: () -> Void = {}
  override func cancelOperation(_ sender: Any?) { onCancel() }
}
