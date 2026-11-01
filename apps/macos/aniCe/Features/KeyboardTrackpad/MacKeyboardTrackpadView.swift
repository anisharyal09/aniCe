// SPDX-License-Identifier: GPL-3.0-or-later
// Presents focused keyboard and pointer input through aniCe's native feature shell.
import AppKit
import SwiftUI

struct MacKeyboardTrackpadView: View {
  @Bindable var model: MacKeyboardTrackpadModel
  private let presentationID: UUID?
  private let floatingPresentation: Bool
  @Environment(\.colorScheme) private var scheme
  @State private var showLinkConfirmation = false
  @State private var linkCandidate: PairedBluetoothDevice?
  @State private var linkPeer: DeviceIdentity?
  @State private var keyboardFocused = false
  @State private var generatedPresentationID = UUID()
  @State private var keyboardInputID = UUID()
  @State private var fullScreenPad: FullScreenTrackpadController?
  @State private var inputWidth: CGFloat = 0
  var onOpenDevices: () -> Void = {}

  init(model: MacKeyboardTrackpadModel, presentationID: UUID? = nil, floatingPresentation: Bool = false,
    onOpenDevices: @escaping () -> Void = {}) {
    self.model = model
    self.presentationID = presentationID
    self.floatingPresentation = floatingPresentation
    self.onOpenDevices = onOpenDevices
  }

  private var activePresentationID: UUID { presentationID ?? generatedPresentationID }

  var body: some View {
    VStack(alignment: .leading, spacing: floatingPresentation ? 12 : 16) {
      targetHeader

      connectionStatus

      if let notice = model.notice {
        Text(notice)
          .font(.caption)
          .foregroundStyle(AniCePalette.secondaryText(scheme))
          .fixedSize(horizontal: false, vertical: true)
      }

      connectionActions

      if floatingPresentation, model.targetPeer != nil, !model.needsDeviceLink {
        keyboardActionRow
      }

      if model.targetPeer == nil {
        noTarget
      } else if model.needsDeviceLink {
        setupPanel
      } else {
        inputSurfaces
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(AniCePalette.primaryText(scheme))
    .onAppear { model.enterPanel(id: activePresentationID) }
    .onDisappear {
      fullScreenPad?.close()
      fullScreenPad = nil
      model.leavePanel(id: activePresentationID)
    }
    .alert(
      "Link device to \(linkPeer?.deviceName ?? "this phone")?",
      isPresented: $showLinkConfirmation,
      presenting: linkCandidate
    ) { candidate in
      Button("Link device") {
        if let linkPeer {
          _ = model.link(candidate, expectedPeerKey: KeyboardTrackpadAssociations.peerKey(linkPeer))
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { candidate in
      Text("Link “\(candidate.name)” (\(candidate.address)) to \(linkPeer?.deviceName ?? "this phone")?\n\naniCe fingerprint: \(linkPeer?.fingerprint ?? "")\n\nConfirm the device yourself; matching names do not prove identity. An existing link to another phone will be replaced.")
    }
  }

  private var targetHeader: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(model.targetPeer?.deviceName ?? "Choose a trusted phone")
          .font(.system(size: floatingPresentation ? 14 : 16, weight: .medium))
          .fixedSize(horizontal: false, vertical: true)
        if !floatingPresentation, model.targetPeer == nil {
          Text("Only trusted aniCe phones can receive input.")
            .font(.caption)
            .foregroundStyle(AniCePalette.secondaryText(scheme))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      if model.trustedPeers.count > 1 || model.targetPeer != nil {
        Menu {
          ForEach(model.trustedPeers, id: \.deviceId) { peer in
            peerMenuOption(peer)
          }
          if model.targetPeer != nil {
            if model.trustedPeers.count > 1 { Divider() }
            Button("Change Bluetooth device…", action: model.relinkBluetoothDevice)
          }
        } label: {
          Label(model.targetPeer == nil ? "Choose phone…" : "Other devices…", systemImage: "arrow.left.arrow.right")
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(AniCeButtonStyle())
        .accessibilityHint("Choose another trusted aniCe phone")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var connectionStatus: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Image(systemName: stateSymbol)
          .foregroundStyle(stateColor)
          .accessibilityHidden(true)
        Text("Bluetooth HID")
          .font(.caption.weight(.semibold))
          .foregroundStyle(AniCePalette.secondaryText(scheme))
        Text("·")
          .foregroundStyle(AniCePalette.secondaryText(scheme))
        Text(model.stateTitle)
          .font(.system(size: 14, weight: .medium))
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(model.stateDetail)
        .font(.callout)
        .foregroundStyle(AniCePalette.secondaryText(scheme))
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Bluetooth HID connection")
    .accessibilityValue(model.stateTitle + ". " + model.stateDetail)
  }

  private func peerMenuOption(_ peer: DeviceIdentity) -> some View {
    let selected = model.targetKey == KeyboardTrackpadAssociations.peerKey(peer)
    let title = "\(peer.deviceName) · \(peer.fingerprint.prefix(8))"
    return Button {
      model.selectTarget(peer)
      model.refreshPairedDevices()
    } label: {
      if selected {
        Label("\(peer.deviceName) · selected", systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }

  private var noTarget: some View {
    VStack(alignment: .leading, spacing: 10) {
      if model.trustedPeers.isEmpty {
        Text("Pair and trust an Android phone in Devices, then return here.")
          .font(.callout)
          .foregroundStyle(AniCePalette.secondaryText(scheme))
        Button("Open Devices", action: onOpenDevices)
        .buttonStyle(AniCeButtonStyle())
      } else {
        Text("Choose which trusted phone to control.")
          .font(.callout)
          .foregroundStyle(AniCePalette.secondaryText(scheme))
        ForEach(model.trustedPeers, id: \.deviceId) { peer in
          Button {
            model.selectTarget(peer)
            model.refreshPairedDevices()
          } label: {
            HStack(spacing: 10) {
              Image(systemName: "iphone")
              VStack(alignment: .leading, spacing: 2) {
                Text(peer.deviceName)
                Text(peer.fingerprint.prefix(12))
                  .font(.caption.monospaced())
                  .foregroundStyle(AniCePalette.secondaryText(scheme))
              }
              Spacer()
              Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(AniCePalette.secondaryText(scheme))
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(AniCeHoverButtonStyle())
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AniCePalette.surface(scheme), in: RoundedRectangle(cornerRadius: 9))
    .overlay { RoundedRectangle(cornerRadius: 9).stroke(AniCePalette.separator(scheme), lineWidth: 0.75) }
  }

  private var setupPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Pair the phone in Bluetooth Settings, then link its paired device once.")
        .font(.callout)
        .foregroundStyle(AniCePalette.secondaryText(scheme))
        .fixedSize(horizontal: false, vertical: true)

      if model.pairedDevicesChecked {
        ForEach(model.matchingPairedDevices) { candidate in
          pairedDeviceRow(candidate)
        }
        let otherDevices = model.pairedDevices.filter { !model.matchingPairedDevices.contains($0) }
        if !otherDevices.isEmpty {
          DisclosureGroup("Other paired Bluetooth devices") {
            ForEach(otherDevices) { pairedDeviceRow($0) }
          }
        }
        if model.pairedDevices.isEmpty {
          Text("No paired devices found. Pair the phone, then refresh.")
            .font(.callout).foregroundStyle(AniCePalette.secondaryText(scheme))
        }
      } else {
        ProgressView("Checking Mac Bluetooth pairings…")
          .controlSize(.small)
      }

      HStack(spacing: 8) {
        Button("Open Bluetooth Settings") { openBluetoothSettings() }
          .buttonStyle(AniCeButtonStyle())
        Button("Refresh") { model.refreshPairedDevices() }
          .buttonStyle(AniCeButtonStyle())
          .disabled(!model.pairedDevicesChecked)
      }
      .controlSize(.small)
      Text("After linking, aniCe connects when this feature opens. Input starts only when you click the keyboard or pad.")
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(scheme))
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AniCePalette.surface(scheme), in: RoundedRectangle(cornerRadius: 9))
    .overlay { RoundedRectangle(cornerRadius: 9).stroke(AniCePalette.separator(scheme), lineWidth: 0.75) }
  }

  private func pairedDeviceRow(_ candidate: PairedBluetoothDevice) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(candidate.name).font(.system(size: 13, weight: .medium))
        Text(candidate.address).font(.caption.monospaced()).foregroundStyle(AniCePalette.secondaryText(scheme))
      }
      Spacer(minLength: 8)
      Button("Link device") {
        linkCandidate = candidate
        linkPeer = model.targetPeer
        showLinkConfirmation = true
      }
      .buttonStyle(AniCeButtonStyle(prominent: true))
      .accessibilityLabel("Link Bluetooth device \(candidate.name), \(candidate.address)")
      .disabled(model.phase == .disconnecting)
    }
  }

  @ViewBuilder private var connectionActions: some View {
    HStack(spacing: 8) {
      switch model.phase {
      case .disconnected, .failed, .setupNeeded:
        Button(model.phase == .failed ? "Retry" : "Connect", action: model.connect)
          .buttonStyle(AniCeButtonStyle(prominent: true))
          .disabled(!model.canConnect)
      case .connecting:
        Button("Cancel", action: model.disconnect).buttonStyle(AniCeButtonStyle())
      case .connectedIdle, .controlling, .suspended:
        Button("Disconnect", action: model.disconnect).buttonStyle(AniCeButtonStyle())
      case .disconnecting:
        EmptyView()
      }
      Spacer(minLength: 0)
      Button("Stop controlling", action: model.stopControlling)
        .buttonStyle(AniCeButtonStyle())
        .disabled(!model.isControlling)
    }
    .controlSize(.small)
  }

  private var keyboardOwner: KeyboardTrackpadCaptureOwner {
    KeyboardTrackpadCaptureOwner(presentationID: activePresentationID, inputID: keyboardInputID, surface: .keyboard)
  }

  private var isKeyboardActive: Bool { model.isControlling(owner: keyboardOwner) }

  private var inputSurfaces: some View {
    let sideBySide = inputWidth >= 522
    let layout = sideBySide
      ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
      : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
    return VStack(alignment: .leading, spacing: 12) {
      // Rearrange the same native input views so resizing cannot replace the capturing responder.
      layout {
        controls.frame(width: sideBySide ? 246 : nil, alignment: .topLeading)
        pad.frame(maxWidth: .infinity).frame(height: 360)
      }
      .background(GeometryReader { geometry in
        Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in inputWidth = width }
      })

      if !floatingPresentation { keyboardActionRow }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { pointerSettings }
        VStack(alignment: .leading, spacing: 8) { pointerSettings }
      }
      .controlSize(.small)
      Text("Stop input: ⌘⇧Esc")
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(scheme))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var pointerSettings: some View {
    scrollSpeedControl
    Menu {
      ForEach(KeyboardTrackpadSpeed.allCases) { speed in
        Button {
          model.pointerSpeed = speed
        } label: {
          if model.pointerSpeed == speed {
            Label("\(speed.title) · \(speed.scale.formatted())×", systemImage: "checkmark")
          } else {
            Text("\(speed.title) · \(speed.scale.formatted())×")
          }
        }
      }
      Divider()
      Toggle("Reverse vertical pointer", isOn: $model.reverseVerticalPointer)
    } label: {
      Label("Pointer · \(model.pointerSpeed.title)", systemImage: "cursorarrow")
    }
    .menuStyle(.borderlessButton)
    .buttonStyle(AniCeButtonStyle())
    Button {
      if let fullScreenPad, fullScreenPad.window?.isVisible == true {
        fullScreenPad.showWindow(nil)
        return
      }
      let controller = FullScreenTrackpadController(model: model)
      fullScreenPad = controller
      controller.start()
    } label: {
      Label("Full-screen trackpad", systemImage: "arrow.up.left.and.arrow.down.right")
    }
    .buttonStyle(AniCeButtonStyle())
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Keyboard").font(.system(size: 14, weight: .medium))
      ZStack {
        KeyboardCaptureSurface(model: model, presentationID: activePresentationID,
          inputID: keyboardInputID, focused: $keyboardFocused)
        VStack(spacing: 4) {
          Image(systemName: isKeyboardActive ? "keyboard.fill" : "keyboard")
            .font(.system(size: 20))
            .foregroundStyle(isKeyboardActive ? AniCePalette.accent(scheme) : AniCePalette.secondaryText(scheme))
          Text(isKeyboardActive ? "Typing to phone" : "Click here to type")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isKeyboardActive ? AniCePalette.primaryText(scheme) : AniCePalette.secondaryText(scheme))
        }
        .allowsHitTesting(false)
      }
      .frame(height: 94)
      .background(AniCePalette.background(scheme), in: RoundedRectangle(cornerRadius: 7))
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .stroke(isKeyboardActive ? AniCePalette.accent(scheme) : AniCePalette.separator(scheme),
            lineWidth: isKeyboardActive ? 1.5 : 0.75)
          .allowsHitTesting(false)
      }
      .accessibilityLabel("Keyboard input area")
      .accessibilityHint("Click to start typing on your Mac to the phone.")

      Text(isKeyboardActive ? "Keyboard active · type on your Mac" : "Click to start, then type on your Mac")
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(scheme))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var keyboardActionRow: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) {
        shortcutKeys
        navigationActions
        typeClipboardAction
      }
      HStack(spacing: 4) {
        shortcutKeys
        navigationActions
        compactClipboardAction
      }
      HStack(spacing: 3) {
        compactShortcutKeys
        navigationActions
        compactClipboardAction
      }
    }
    .buttonStyle(AniCeButtonStyle(compact: true))
    .controlSize(.small)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Keyboard, navigation and clipboard controls")
  }

  private var shortcutKeys: some View {
    HStack(spacing: 4) {
      shortcutKey("Tab", usage: 0x2B)
      shortcutKey("Esc", usage: 0x29)
      shortcutKey("⌫", usage: 0x2A)
      shortcutKey("Return", usage: 0x28)
    }
  }

  private var compactShortcutKeys: some View {
    HStack(spacing: 3) {
      shortcutKey("Tab", usage: 0x2B)
      shortcutKey("Esc", usage: 0x29)
      shortcutKey("⌫", usage: 0x2A)
      shortcutKey("↵", usage: 0x28, accessibleName: "Return")
    }
  }

  private var navigationActions: some View {
    HStack(spacing: 4) {
      Button { model.sendNavigation(usage: 0x0224) } label: {
        Image(systemName: "chevron.left")
      }
        .accessibilityLabel("Back")
        .help("Back")
        .disabled(!model.canSendShortcut || !model.reportProtocol)
      Button { model.sendNavigation(usage: 0x0223) } label: {
        Image(systemName: "house")
      }
        .accessibilityLabel("Home")
        .help("Home")
        .disabled(!model.canSendShortcut || !model.reportProtocol)
      Button(action: model.sendRecentApps) {
        Image(systemName: "square.on.square")
      }
        .accessibilityLabel("Recents")
        .help("Recents")
        .disabled(!model.canSendShortcut)
    }
    .buttonStyle(AniCeButtonStyle(compact: true))
  }

  @ViewBuilder private var typeClipboardAction: some View {
    if model.isTypingClipboard {
      HStack(spacing: 5) {
        ProgressView(value: Double(model.typingProgress), total: Double(max(model.typingLength, 1)))
          .frame(width: 58)
          .accessibilityLabel("Clipboard typing progress")
          .accessibilityValue("\(model.typingProgress) of \(model.typingLength) characters")
        Text("\(model.typingProgress)/\(model.typingLength)")
          .font(.caption)
          .foregroundStyle(AniCePalette.secondaryText(scheme))
        Button("Stop typing", action: model.stopTyping)
      }
    } else {
      Button(action: model.typeClipboard) {
        Label("Type clipboard", systemImage: "doc.on.clipboard")
      }
      .disabled(!model.canTypeClipboard)
      .help("Types supported plain text from the Mac clipboard after you click.")
    }
  }

  @ViewBuilder private var compactClipboardAction: some View {
    if model.isTypingClipboard {
      HStack(spacing: 3) {
        ProgressView(value: Double(model.typingProgress), total: Double(max(model.typingLength, 1)))
          .frame(width: 24)
          .accessibilityLabel("Clipboard typing progress")
          .accessibilityValue("\(model.typingProgress) of \(model.typingLength) characters")
        Button(action: model.stopTyping) {
          Image(systemName: "stop.fill")
        }
        .accessibilityLabel("Stop typing")
        .help("Stop typing")
      }
    } else {
      Button(action: model.typeClipboard) {
        Image(systemName: "doc.on.clipboard")
      }
      .accessibilityLabel("Type clipboard")
      .help("Type clipboard")
      .disabled(!model.canTypeClipboard)
    }
  }

  private var scrollSpeedControl: some View {
    Menu {
      ForEach(KeyboardTrackpadSpeed.allCases) { speed in
        Button {
          model.scrollSpeed = speed
        } label: {
          if model.scrollSpeed == speed {
            Label("\(speed.title) · \(speed.scale.formatted())×", systemImage: "checkmark")
          } else {
            Text("\(speed.title) · \(speed.scale.formatted())×")
          }
        }
      }
    } label: {
      Label("Scroll · \(model.scrollSpeed.title)", systemImage: "arrow.up.and.down")
    }
    .menuStyle(.borderlessButton)
    .buttonStyle(AniCeButtonStyle())
    .controlSize(.small)
    .disabled(!model.reportProtocol)
  }

  private func shortcutKey(_ label: String, usage: UInt8, accessibleName: String? = nil) -> some View {
    let spokenName = accessibleName ?? (label == "⌫" ? "Backspace" : label)
    return Button(label) { model.sendTap(usage: usage) }
      .disabled(!model.canSendShortcut)
      .accessibilityLabel(spokenName)
      .help(spokenName)
  }

  private var pad: some View {
    VStack(alignment: .leading, spacing: 8) {
      TrackpadPad(model: model, presentationID: activePresentationID)
      Text("Two fingers: up/down to scroll; left/right to drag the phone pointer. Use it to pan, drag or select.")
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(scheme))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var stateSymbol: String {
    switch model.phase {
    case .connectedIdle, .controlling: "checkmark.circle"
    case .connecting, .disconnecting: "arrow.triangle.2.circlepath"
    case .suspended: "pause.circle"
    case .failed: "exclamationmark.circle"
    case .setupNeeded, .disconnected: "circle"
    }
  }

  private var stateColor: Color {
    switch model.phase {
    case .connectedIdle, .controlling: AniCePalette.success(scheme)
    case .failed: AniCePalette.error(scheme)
    case .suspended, .setupNeeded: AniCePalette.warning(scheme)
    case .connecting, .disconnecting, .disconnected: AniCePalette.secondaryText(scheme)
    }
  }

  private func openBluetoothSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Bluetooth") else { return }
    NSWorkspace.shared.open(url)
  }
}


private struct TrackpadPad: View {
  let model: MacKeyboardTrackpadModel
  let presentationID: UUID
  @Environment(\.colorScheme) private var scheme
  @State private var focused = false
  @State private var inputID = UUID()

  private var captureOwner: KeyboardTrackpadCaptureOwner {
    KeyboardTrackpadCaptureOwner(presentationID: presentationID, inputID: inputID, surface: .pad)
  }

  var body: some View {
    ZStack {
      MousePadSurface(model: model, presentationID: presentationID, inputID: inputID, focused: $focused)
        .accessibilityLabel("Mouse and trackpad pad")
        .accessibilityHint("Click to arm pointer input; the first click is consumed. Two-finger scrolling browses this panel until the pad is active, then scrolls the phone.")
      VStack {
        HStack {
          Label("Phone pointer", systemImage: "cursorarrow")
            .font(.caption)
            .foregroundStyle(AniCePalette.secondaryText(scheme))
          Spacer()
          if focused {
            Image(systemName: "viewfinder")
              .foregroundStyle(AniCePalette.accent(scheme))
              .accessibilityLabel("Pad focused")
          }
        }
        Spacer()
        if !model.isControlling(owner: captureOwner) {
          Text("Click to control · scroll to browse")
            .font(.caption)
            .foregroundStyle(AniCePalette.secondaryText(scheme))
        } else {
          Text(model.pointerActivity)
            .font(.caption)
            .foregroundStyle(AniCePalette.secondaryText(scheme))
        }
      }
      .padding(14)
      .allowsHitTesting(false)
    }
    .background(AniCePalette.surface(scheme), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(focused ? AniCePalette.accent(scheme) : AniCePalette.separator(scheme),
          lineWidth: focused ? 1.5 : 0.75)
        .allowsHitTesting(false)
    }
    .contentShape(RoundedRectangle(cornerRadius: 10))
  }
}

@MainActor final class FullScreenTrackpadController: NSWindowController, NSWindowDelegate {
  private let model: MacKeyboardTrackpadModel
  private let presentationID = UUID()

  init(model: MacKeyboardTrackpadModel) {
    self.model = model
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Phone trackpad"
    window.minSize = NSSize(width: 480, height: 320)
    window.collectionBehavior = [.fullScreenPrimary]
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    window.contentView = NSHostingView(rootView: FullScreenTrackpadContent(
      model: model, presentationID: presentationID) { [weak self] in self?.close() })
    window.center()
    model.enterPanel(id: presentationID, automaticallyConnect: false, refreshPairedDevices: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(model:)") }

  func start() {
    // Opening another surface releases the old owner; a fresh click arms the full-screen pad.
    model.stopControlling()
    showWindow(nil)
    window?.toggleFullScreen(nil)
  }

  func windowWillClose(_ notification: Notification) {
    model.leavePanel(id: presentationID)
    window?.contentView = nil
  }

  func windowDidExitFullScreen(_ notification: Notification) { close() }
  func windowDidFailToEnterFullScreen(_ window: NSWindow) { close() }
}

private struct FullScreenTrackpadContent: View {
  @Bindable var model: MacKeyboardTrackpadModel
  @Environment(\.colorScheme) private var scheme
  let presentationID: UUID
  let onDone: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(model.targetPeer?.deviceName ?? "Phone trackpad").font(.headline)
          Text("\(model.stateTitle) · ⌘⇧Esc stops input")
            .font(.caption)
            .foregroundStyle(AniCePalette.secondaryText(scheme))
        }
        Spacer(minLength: 8)
        Button("Stop controlling") { model.stopControl(presentationID: presentationID) }
          .disabled(!model.isControlling)
        Button("Done", action: onDone)
      }
      .buttonStyle(AniCeButtonStyle())
      TrackpadPad(model: model, presentationID: presentationID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .foregroundStyle(AniCePalette.primaryText(scheme))
    .background(AniCePalette.background(scheme))
  }
}

private struct KeyboardCaptureSurface: NSViewRepresentable {
  let model: MacKeyboardTrackpadModel
  let presentationID: UUID
  let inputID: UUID
  @Binding var focused: Bool

  func makeNSView(context: Context) -> KeyboardInputNSView {
    let view = KeyboardInputNSView()
    view.configure(model: model, presentationID: presentationID, inputID: inputID)
    view.onFocusChange = { focused = $0 }
    return view
  }

  func updateNSView(_ view: KeyboardInputNSView, context: Context) {
    view.configure(model: model, presentationID: presentationID, inputID: inputID)
    view.onFocusChange = { focused = $0 }
  }
}

@MainActor final class KeyboardInputNSView: NSView {
  var model: MacKeyboardTrackpadModel?
  var presentationID = UUID()
  var inputID = UUID()
  var captureOwner: KeyboardTrackpadCaptureOwner {
    KeyboardTrackpadCaptureOwner(presentationID: presentationID, inputID: inputID, surface: .keyboard)
  }
  var onFocusChange: ((Bool) -> Void)?
  var floatingToggleEnabled = false
  var onFloatingMouseDown: (() -> Void)?
  var onFloatingClick: (() -> Void)?
  var onFloatingRightClick: (() -> Void)?
  var onFloatingFocusLost: (() -> Void)?
  // AppKit owns these views on the main thread; deinit is nonisolated in Swift 6.
  nonisolated(unsafe) private var keyWindowObserver: NSObjectProtocol?
  nonisolated(unsafe) private var localMonitor: Any?
  private var capsLockEnabled = false
  private var floatingMouseDownPoint: NSPoint?
  private var floatingWindowOrigin: NSPoint?
  private var floatingDidDrag = false
  private var focusedOwner: KeyboardTrackpadCaptureOwner?

  override var acceptsFirstResponder: Bool { true }
  override var allowsVibrancy: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
    keyWindowObserver = nil
    if let localMonitor {
      NSEvent.removeMonitor(localMonitor)
      self.localMonitor = nil
    }
    if let window {
      observeFocusLoss(in: window)
      localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
        guard let self else { return event }
        return self.handleKeyboardEvent(event) ? nil : event
      }
    }
  }

  private func observeFocusLoss(in window: NSWindow) {
    if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
    let observedOwner = captureOwner
    keyWindowObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.model?.surfaceLost(owner: observedOwner)
        self.onFloatingFocusLost?()
      }
    }
  }

  func configure(model: MacKeyboardTrackpadModel, presentationID: UUID, inputID: UUID) {
    let previousOwner = captureOwner
    let identityChanged = self.model !== model || previousOwner.presentationID != presentationID || previousOwner.inputID != inputID
    if identityChanged { self.model?.surfaceLost(owner: previousOwner) }
    self.model = model
    self.presentationID = presentationID
    self.inputID = inputID
    if identityChanged, let window { observeFocusLoss(in: window) }
    if window?.firstResponder === self {
      focusedOwner = captureOwner
    } else if focusedOwner == previousOwner {
      focusedOwner = nil
    }
  }

  @discardableResult private func handleKeyboardEvent(_ event: NSEvent) -> Bool {
    guard let window, event.window === window, window.isKeyWindow, window.firstResponder === self,
          let model, model.isControlling(owner: captureOwner) else { return false }
    if event.type == .keyDown && event.keyCode == 53 && event.modifierFlags.contains([.command, .shift]) {
      model.stopControl(owner: captureOwner)
      return true
    }
    if event.type == .flagsChanged {
      let modifiers = Self.hidModifiers(event.modifierFlags)
      if event.keyCode == 0x39 {
        let enabled = event.modifierFlags.contains(.capsLock)
        if enabled != capsLockEnabled {
          capsLockEnabled = enabled
          // AppKit reports Caps Lock as a flag; HID needs a key press and release.
          model.keyDown(usage: 0x39, modifiers: modifiers, owner: captureOwner)
          model.keyUp(usage: 0x39, modifiers: modifiers, owner: captureOwner)
        }
      } else {
        model.modifiersChanged(modifiers, owner: captureOwner)
      }
    } else {
      let usage = AniCeHIDProtocol.usage(forMacKeyCode: event.keyCode)
      if usage != 0 {
        if event.type == .keyDown && !event.isARepeat {
          model.keyDown(usage: usage, modifiers: Self.hidModifiers(event.modifierFlags), owner: captureOwner)
        } else if event.type == .keyUp {
          model.keyUp(usage: usage, modifiers: Self.hidModifiers(event.modifierFlags), owner: captureOwner)
        }
      }
    }
    return true
  }

  override func keyDown(with event: NSEvent) { handleKeyboardEvent(event) }
  override func keyUp(with event: NSEvent) { handleKeyboardEvent(event) }
  override func flagsChanged(with event: NSEvent) { handleKeyboardEvent(event) }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    handleKeyboardEvent(event) || super.performKeyEquivalent(with: event)
  }

  override func mouseDown(with event: NSEvent) {
    if floatingToggleEnabled {
      floatingMouseDownPoint = window?.convertPoint(toScreen: event.locationInWindow)
      floatingWindowOrigin = window?.frame.origin
      floatingDidDrag = false
      onFloatingMouseDown?()
      window?.makeKeyAndOrderFront(nil)
      window?.makeFirstResponder(self)
      return
    }
    capsLockEnabled = event.modifierFlags.contains(.capsLock)
    window?.makeFirstResponder(self)
    model?.requestControl(owner: captureOwner)
  }

  override func mouseDragged(with event: NSEvent) {
    guard floatingToggleEnabled, let window,
          let start = floatingMouseDownPoint, let origin = floatingWindowOrigin else { return }
    let current = window.convertPoint(toScreen: event.locationInWindow)
    let delta = NSPoint(x: current.x - start.x, y: current.y - start.y)
    if !floatingDidDrag && hypot(delta.x, delta.y) >= 5 { floatingDidDrag = true }
    if floatingDidDrag {
      window.setFrameOrigin(NSPoint(x: origin.x + delta.x, y: origin.y + delta.y))
    }
  }

  override func mouseUp(with event: NSEvent) {
    guard floatingToggleEnabled else { return }
    if !floatingDidDrag { onFloatingClick?() }
    floatingMouseDownPoint = nil
    floatingWindowOrigin = nil
    floatingDidDrag = false
  }

  override func rightMouseDown(with event: NSEvent) {
    if floatingToggleEnabled {
      floatingMouseDownPoint = nil
      floatingWindowOrigin = nil
      floatingDidDrag = false
      onFloatingRightClick?()
      return
    }
    super.rightMouseDown(with: event)
  }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted {
      focusedOwner = captureOwner
      onFocusChange?(true)
    }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted {
      let lostOwner = focusedOwner ?? captureOwner
      focusedOwner = nil
      onFocusChange?(false)
      model?.surfaceLost(owner: lostOwner)
      onFloatingFocusLost?()
    }
    return accepted
  }

  override func cancelOperation(_ sender: Any?) { model?.stopControl(owner: captureOwner) }

  deinit {
    if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
  }

  private static func hidModifiers(_ flags: NSEvent.ModifierFlags) -> UInt8 {
    AniCeHIDProtocol.physicalModifiers(for: flags)
  }
}

private struct MousePadSurface: NSViewRepresentable {
  let model: MacKeyboardTrackpadModel
  let presentationID: UUID
  let inputID: UUID
  @Binding var focused: Bool

  func makeNSView(context: Context) -> MousePadNSView {
    let view = MousePadNSView()
    view.allowedTouchTypes = [.indirect]
    view.configure(model: model, presentationID: presentationID, inputID: inputID)
    view.onFocusChange = { focused = $0 }
    return view
  }

  func updateNSView(_ view: MousePadNSView, context: Context) {
    view.configure(model: model, presentationID: presentationID, inputID: inputID)
    view.onFocusChange = { focused = $0 }
  }
}

@MainActor final class MousePadNSView: NSView {
  var model: MacKeyboardTrackpadModel?
  var presentationID = UUID()
  var inputID = UUID()
  var captureOwner: KeyboardTrackpadCaptureOwner {
    KeyboardTrackpadCaptureOwner(presentationID: presentationID, inputID: inputID, surface: .pad)
  }
  var onFocusChange: ((Bool) -> Void)?
  // AppKit owns these views on the main thread; deinit is nonisolated in Swift 6.
  nonisolated(unsafe) private var keyWindowObserver: NSObjectProtocol?
  private var mouseTrackingArea: NSTrackingArea?
  private var consumingArmingGesture = false
  private var blockedTouchSequence = false
  private var focusedOwner: KeyboardTrackpadCaptureOwner?

  override var acceptsFirstResponder: Bool { true }
  override var isOpaque: Bool { false }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let mouseTrackingArea { removeTrackingArea(mouseTrackingArea) }
    let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved], owner: self, userInfo: nil)
    addTrackingArea(area)
    mouseTrackingArea = area
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
    keyWindowObserver = nil
    if let window {
      observeFocusLoss(in: window)
      window.acceptsMouseMovedEvents = true
    }
  }

  private func observeFocusLoss(in window: NSWindow) {
    if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
    let observedOwner = captureOwner
    keyWindowObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.model?.surfaceLost(owner: observedOwner)
      }
    }
  }

  func configure(model: MacKeyboardTrackpadModel, presentationID: UUID, inputID: UUID) {
    let previousOwner = captureOwner
    let identityChanged = self.model !== model || previousOwner.presentationID != presentationID || previousOwner.inputID != inputID
    if identityChanged { self.model?.surfaceLost(owner: previousOwner) }
    self.model = model
    self.presentationID = presentationID
    self.inputID = inputID
    if identityChanged, let window { observeFocusLoss(in: window) }
    if window?.firstResponder === self {
      focusedOwner = captureOwner
    } else if focusedOwner == previousOwner {
      focusedOwner = nil
    }
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

  override func mouseDown(with event: NSEvent) {
    model?.cancelScrollGesture(owner: captureOwner)
    let wasActivePad = model?.isControlling(owner: captureOwner) == true
    consumingArmingGesture = !wasActivePad
    window?.makeFirstResponder(self)
    if wasActivePad { model?.pointerButtonDown(owner: captureOwner) }
    else { model?.requestControl(owner: captureOwner) }
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 && event.modifierFlags.contains([.command, .shift]) {
      model?.stopControl(owner: captureOwner)
      return
    }
    super.keyDown(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if consumingArmingGesture { consumingArmingGesture = false; return }
    if model?.isControlling(owner: captureOwner) == true {
      model?.pointerButtonUp(owner: captureOwner)
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    model?.cancelScrollGesture(owner: captureOwner)
    let wasActivePad = model?.isControlling(owner: captureOwner) == true
    consumingArmingGesture = !wasActivePad
    window?.makeFirstResponder(self)
    if wasActivePad { model?.pointerButtonDown(secondary: true, owner: captureOwner) }
    else { model?.requestControl(owner: captureOwner) }
  }

  override func rightMouseUp(with event: NSEvent) {
    if consumingArmingGesture { consumingArmingGesture = false; return }
    if model?.isControlling(owner: captureOwner) == true {
      model?.pointerButtonUp(owner: captureOwner)
    }
  }

  override func mouseMoved(with event: NSEvent) { sendMotion(event) }
  override func mouseDragged(with event: NSEvent) { sendMotion(event) }
  override func rightMouseDragged(with event: NSEvent) { sendMotion(event) }

  override func scrollWheel(with event: NSEvent) {
    guard let model else { super.scrollWheel(with: event); return }
    guard !consumingArmingGesture, !blockedTouchSequence else {
      super.scrollWheel(with: event)
      return
    }
    guard model.isControlling(owner: captureOwner) else {
      // Let the containing feature or floating-panel scroll view handle inactive-pad gestures.
      super.scrollWheel(with: event)
      return
    }
    guard isInsidePad(event) else {
      // A gesture ending outside the pad must still release its held drag.
      if let window, window.isKeyWindow, event.window === window {
        model.cancelScrollGesture(owner: captureOwner)
      }
      return
    }
    model.scrollGesture(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
      phase: event.phase, precise: event.hasPreciseScrollingDeltas,
      momentum: !event.momentumPhase.isEmpty, owner: captureOwner)
  }

  override func touchesBegan(with event: NSEvent) { trackTouches(event) }
  override func touchesMoved(with event: NSEvent) { trackTouches(event) }
  override func touchesEnded(with event: NSEvent) { trackTouches(event) }
  override func touchesCancelled(with event: NSEvent) {
    // AppKit can cancel raw touches when the scroll recognizer takes ownership.
    if model?.isScrolling != true { trackTouches(event) }
  }

  private func trackTouches(_ event: NSEvent) {
    let count = event.touches(matching: .touching, in: self).count
    if count >= 3 {
      blockedTouchSequence = true
      model?.cancelScrollGesture(owner: captureOwner)
    } else if count == 0 { blockedTouchSequence = false }
  }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted {
      focusedOwner = captureOwner
      onFocusChange?(true)
    }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted {
      let lostOwner = focusedOwner ?? captureOwner
      focusedOwner = nil
      onFocusChange?(false)
      model?.surfaceLost(owner: lostOwner)
    }
    return accepted
  }

  override func cancelOperation(_ sender: Any?) { model?.stopControl(owner: captureOwner) }

  deinit {
    if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
  }

  private func isInsidePad(_ event: NSEvent) -> Bool {
    guard let window, window.isKeyWindow, event.window === window else { return false }
    return visibleRect.contains(convert(event.locationInWindow, from: nil))
  }

  private func sendMotion(_ event: NSEvent) {
    guard !consumingArmingGesture, !blockedTouchSequence, model?.isScrolling != true,
          model?.isControlling(owner: captureOwner) == true else { return }
    guard isInsidePad(event), let model else { return }
    // Keep the legacy inverted mapping available without changing canonical HID coordinates in the model.
    let deltaY = model.reverseVerticalPointer ? event.deltaY : -event.deltaY
    model.pointerMoved(deltaX: event.deltaX, deltaY: deltaY, owner: captureOwner)
  }
}
