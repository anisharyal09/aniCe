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
  var dismissCompanion: () -> Void = {}
  @State private var selectedActivityIndex = 0
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if pairing.peers.count > 3 { ScrollView { deviceContent }.frame(maxHeight: 520) }
      else { deviceContent }
      liveActivitySection
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
          onOpenDevice: { peer in navigation.open(.devices, peer: peer, present: openMain) },
          onSendFiles: sendFilesAction)
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

  private enum ActivityKind: Equatable {
    case transfer
    case playback
  }

  private var presentActivities: [ActivityKind] {
    var list: [ActivityKind] = []
    if transfer.state != .idle {
      list.append(.transfer)
    }
    if playback.showOnMac && playback.compactVisible {
      list.append(.playback)
    }
    return list
  }

  @ViewBuilder
  private var liveActivitySection: some View {
    let activities = presentActivities
    if !activities.isEmpty {
      let currentIndex = min(selectedActivityIndex, activities.count - 1)
      let current = activities[currentIndex]
      VStack(alignment: .leading, spacing: 8) {
        if activities.count > 1 {
          HStack {
            HStack(spacing: 6) {
              ForEach(0..<activities.count, id: \.self) { idx in
                let isTransfer = activities[idx] == .transfer
                let hasAttention = isTransfer && transfer.pendingOffer != nil
                Circle()
                  .fill(idx == currentIndex
                        ? AniCePalette.primaryText(colorScheme)
                        : (hasAttention ? AniCePalette.accent(colorScheme) : AniCePalette.separator(colorScheme)))
                  .frame(width: 6, height: 6)
                  .overlay(
                    hasAttention && idx != currentIndex
                      ? Circle().stroke(AniCePalette.accent(colorScheme), lineWidth: 1.5).scaleEffect(1.8)
                      : nil
                  )
              }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Activity page \(currentIndex + 1) of \(activities.count)\(transfer.pendingOffer != nil ? ", incoming transfer offer waiting" : "")")

            Spacer()

            Text("\(currentIndex + 1) of \(activities.count)")
              .font(.caption2)
              .foregroundStyle(AniCePalette.secondaryText(colorScheme))

            Button {
              selectedActivityIndex = (currentIndex - 1 + activities.count) % activities.count
            } label: {
              Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Previous activity")

            Button {
              selectedActivityIndex = (currentIndex + 1) % activities.count
            } label: {
              Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Next activity")
          }
        }

        switch current {
        case .transfer:
          TransferView(model: transfer, compact: true)
            .gesture(
              activities.count > 1
                ? DragGesture(minimumDistance: 25)
                    .onEnded { value in
                      if value.translation.width < -30 {
                        selectedActivityIndex = (currentIndex + 1) % activities.count
                      } else if value.translation.width > 30 {
                        selectedActivityIndex = (currentIndex - 1 + activities.count) % activities.count
                      }
                    }
                : nil
            )
        case .playback:
          // Seek/volume sliders inside MediaView require swipe to be disabled per DESIGN.md §Live activities.
          MediaView(model: playback, compact: true, visible: playback.companionVisible, playerPicker: false) {
            navigation.open(.features, present: openMain)
          }
        }
      }
    }
  }

  private var footer: some View {
    ZStack {
      Button("Open aniCe") {
        openMain()
      }
      .buttonStyle(.borderedProminent)
      .foregroundStyle(AniCePalette.onAccent(colorScheme))

      HStack {
        Spacer()
        Menu {
          Button("Settings") {
            navigation.open(.settings, present: openMain)
          }
          Button("Quit aniCe") { NSApp.terminate(nil) }
        } label: {
          Image(systemName: "ellipsis")
            .font(.body)
            .foregroundStyle(AniCePalette.secondaryText(colorScheme))
            .padding(6)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("More options")
      }
    }
    .frame(maxWidth: .infinity)
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
  private let onDetails: () -> Void

  init(content: CompanionView, onOpen: @escaping () -> Void,
    onManage: @escaping () -> Void, onDetails: @escaping () -> Void) {
    self.playback = content.playback
    self.onOpen = onOpen
    self.onManage = onManage
    self.onDetails = onDetails
    super.init()
    Self.currentHost = self
    var hostedContent = content
    hostedContent.dismissCompanion = { [weak self] in self?.close() }
    let controller = CompanionHostingController(rootView: hostedContent)
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

  @objc private func openMain() {
    popover.performClose(nil)
    NSApp.activate(ignoringOtherApps: true)
    onOpen()
  }

  @objc private func openDetails() {
    popover.performClose(nil)
    NSApp.activate(ignoringOtherApps: true)
    onDetails()
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
