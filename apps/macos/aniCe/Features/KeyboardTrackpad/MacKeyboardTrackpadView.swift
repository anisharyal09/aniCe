// SPDX-License-Identifier: GPL-3.0-or-later
// Presents focused keyboard and pointer input through aniCe's native feature shell.
import AppKit
import SwiftUI

struct MacKeyboardTrackpadView: View {
  @Bindable var model: MacKeyboardTrackpadModel
  @Environment(\.colorScheme) private var scheme
  @State private var showLinkConfirmation = false
  @State private var linkCandidate: PairedBluetoothDevice?
  @State private var linkPeer: DeviceIdentity?
  @State private var keyboardFocused = false
  @State private var padFocused = false
  var onOpenDevices: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      targetHeader

      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: stateSymbol)
          .foregroundStyle(stateColor)
          .accessibilityHidden(true)
        Text(model.stateTitle).font(.system(size: 14, weight: .medium))
        Text(model.stateDetail)
          .font(.callout)
          .foregroundStyle(AniCePalette.secondaryText(scheme))
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Keyboard and trackpad status")
      .accessibilityValue(model.stateTitle + ". " + model.stateDetail)

      if let notice = model.notice {
        Text(notice)
          .font(.caption)
          .foregroundStyle(AniCePalette.secondaryText(scheme))
          .fixedSize(horizontal: false, vertical: true)
      }

      connectionActions

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
    .onAppear { model.enterPanel() }
    .onDisappear { model.leavePanel() }
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
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(model.targetPeer?.deviceName ?? "Choose a trusted phone")
          .font(.system(size: 16, weight: .medium))
          .fixedSize(horizontal: false, vertical: true)
        Text(model.targetPeer == nil
          ? "Only phones trusted in aniCe can receive input."
          : "Input uses the phone’s system-paired Bluetooth link.")
          .font(.caption)
          .foregroundStyle(AniCePalette.secondaryText(scheme))
          .fixedSize(horizontal: false, vertical: true)
        if let peer = model.targetPeer {
          Text("Fingerprint · \(peer.fingerprint.prefix(12))")
            .font(.caption.monospaced())
            .foregroundStyle(AniCePalette.secondaryText(scheme))
            .textSelection(.enabled)
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
      Text("aniCe reconnects when you open this feature. Click a surface to start input.")
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

  private var isKeyboardActive: Bool {
    model.isControlling && model.currentSurface == .keyboard
  }

  private var inputSurfaces: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 16) {
        controls.frame(width: 246, alignment: .topLeading)
        pad.frame(minWidth: 260, maxWidth: .infinity, minHeight: 326, idealHeight: 360, maxHeight: 440)
      }
      VStack(alignment: .leading, spacing: 16) {
        controls
        pad.frame(height: 360)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Keyboard").font(.system(size: 14, weight: .medium))
      ZStack {
        KeyboardCaptureSurface(model: model, focused: $keyboardFocused)
        VStack(spacing: 4) {
          Image(systemName: isKeyboardActive ? "keyboard.fill" : "keyboard")
            .font(.system(size: 20))
            .foregroundStyle(isKeyboardActive ? AniCePalette.accent(scheme) : AniCePalette.secondaryText(scheme))
          Text(isKeyboardActive ? "Typing to phone" : "Click here to type")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isKeyboardActive ? AniCePalette.primaryText(scheme) : AniCePalette.secondaryText(scheme))
          Text("⌘ acts as Ctrl · ⌘⇧Esc stops")
            .font(.caption2)
            .foregroundStyle(AniCePalette.secondaryText(scheme))
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

      HStack(spacing: 6) {
        shortcutKey("Tab", usage: 0x2B)
        shortcutKey("Esc", usage: 0x29)
        shortcutKey("⌫", usage: 0x2A)
        shortcutKey("Return", usage: 0x28)
      }
      .buttonStyle(AniCeButtonStyle())
      .controlSize(.small)

      HStack(spacing: 8) {
        Button("Back") { model.sendNavigation(usage: 0x0224) }
          .disabled(!model.canSendShortcut || !model.reportProtocol)
        Button("Home") { model.sendNavigation(usage: 0x0223) }
          .disabled(!model.canSendShortcut || !model.reportProtocol)
        Button("Recents", action: model.sendRecentApps)
          .disabled(!model.canSendShortcut)
      }
      .buttonStyle(AniCeButtonStyle())
      .controlSize(.small)

      Menu {
        ForEach(KeyboardTrackpadScrollSpeed.allCases) { speed in
          Button {
            model.scrollSpeed = speed
          } label: {
            if model.scrollSpeed == speed {
              Label(speed.title, systemImage: "checkmark")
            } else {
              Text(speed.title)
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

      if model.isTypingClipboard {
        VStack(alignment: .leading, spacing: 6) {
          ProgressView(value: Double(model.typingProgress), total: Double(max(model.typingLength, 1)))
          HStack {
            Text("\(model.typingProgress) of \(model.typingLength) characters")
              .font(.caption)
              .foregroundStyle(AniCePalette.secondaryText(scheme))
            Spacer()
            Button("Stop typing", action: model.stopTyping)
              .buttonStyle(AniCeButtonStyle())
              .controlSize(.small)
          }
        }
      } else {
        Button(action: model.typeClipboard) {
          Label("Type clipboard", systemImage: "doc.on.clipboard")
        }
        .buttonStyle(AniCeButtonStyle())
        .disabled(!model.canTypeClipboard)
        .help("Types supported plain text from the Mac clipboard after you click.")
      }

      Text("Stop input: ⌘⇧Esc")
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(scheme))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func shortcutKey(_ label: String, usage: UInt8) -> some View {
    Button(label) { model.sendTap(usage: usage) }
      .disabled(!model.canSendShortcut)
      .accessibilityLabel(label == "⌫" ? "Backspace" : label)
  }

  private var pad: some View {
    VStack(alignment: .leading, spacing: 8) {
      padSurface
      Text("Two fingers: up/down to scroll, sideways to drag. Android apps decide whether a drag selects text or moves content.")
        .font(.caption)
        .foregroundStyle(AniCePalette.secondaryText(scheme))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var padSurface: some View {
    ZStack {
      MousePadSurface(model: model, focused: $padFocused)
        .accessibilityLabel("Mouse and trackpad pad")
        .accessibilityHint("Click to connect and arm pointer input. The click is consumed. Move, drag or scroll after control starts.")
      VStack {
        HStack {
          Label("Phone pointer", systemImage: "cursorarrow")
            .font(.caption)
            .foregroundStyle(AniCePalette.secondaryText(scheme))
          Spacer()
          if padFocused {
            Image(systemName: "viewfinder")
              .foregroundStyle(AniCePalette.accent(scheme))
              .accessibilityLabel("Pad focused")
          }
        }
        Spacer()
        if !model.isControlling || model.currentSurface != .pad {
          Text("Click to control")
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
        .stroke(padFocused ? AniCePalette.accent(scheme) : AniCePalette.separator(scheme),
          lineWidth: padFocused ? 1.5 : 0.75)
        .allowsHitTesting(false)
    }
    .contentShape(RoundedRectangle(cornerRadius: 10))
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


private struct KeyboardCaptureSurface: NSViewRepresentable {
  let model: MacKeyboardTrackpadModel
  @Binding var focused: Bool

  func makeNSView(context: Context) -> KeyboardInputNSView {
    let view = KeyboardInputNSView()
    view.model = model
    view.onFocusChange = { focused = $0 }
    return view
  }

  func updateNSView(_ view: KeyboardInputNSView, context: Context) {
    view.model = model
    view.onFocusChange = { focused = $0 }
  }
}

@MainActor final class KeyboardInputNSView: NSView {
  var model: MacKeyboardTrackpadModel?
  var onFocusChange: ((Bool) -> Void)?
  // AppKit owns these views on the main thread; deinit is nonisolated in Swift 6.
  nonisolated(unsafe) private var keyWindowObserver: NSObjectProtocol?
  nonisolated(unsafe) private var localMonitor: Any?
  private var capsLockEnabled = false

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
      keyWindowObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: window, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.model?.surfaceLost(.keyboard) }
      }
      localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
        guard let self else { return event }
        return self.handleKeyboardEvent(event) ? nil : event
      }
    }
  }

  @discardableResult private func handleKeyboardEvent(_ event: NSEvent) -> Bool {
    guard let window, event.window === window, window.isKeyWindow, window.firstResponder === self,
          let model, model.isControlling, model.currentSurface == .keyboard else { return false }
    if event.type == .keyDown && event.keyCode == 53 && event.modifierFlags.contains([.command, .shift]) {
      model.stopControlling()
      return true
    }
    if event.type == .flagsChanged {
      let modifiers = Self.hidModifiers(event.modifierFlags)
      if event.keyCode == 0x39 {
        let enabled = event.modifierFlags.contains(.capsLock)
        if enabled != capsLockEnabled {
          capsLockEnabled = enabled
          // AppKit reports Caps Lock as a flag; HID needs a key press and release.
          model.keyDown(usage: 0x39, modifiers: modifiers)
          model.keyUp(usage: 0x39, modifiers: modifiers)
        }
      } else {
        model.modifiersChanged(modifiers)
      }
    } else {
      let usage = AniCeHIDProtocol.usage(forMacKeyCode: event.keyCode)
      if usage != 0 {
        if event.type == .keyDown && !event.isARepeat {
          model.keyDown(usage: usage, modifiers: Self.hidModifiers(event.modifierFlags))
        } else if event.type == .keyUp {
          model.keyUp(usage: usage, modifiers: Self.hidModifiers(event.modifierFlags))
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
    capsLockEnabled = event.modifierFlags.contains(.capsLock)
    window?.makeFirstResponder(self)
    model?.requestControl(on: .keyboard)
  }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { onFocusChange?(true) }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted {
      onFocusChange?(false)
      model?.surfaceLost(.keyboard)
    }
    return accepted
  }

  override func cancelOperation(_ sender: Any?) { model?.stopControlling() }

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
  @Binding var focused: Bool

  func makeNSView(context: Context) -> MousePadNSView {
    let view = MousePadNSView()
    view.allowedTouchTypes = [.indirect]
    view.model = model
    view.onFocusChange = { focused = $0 }
    return view
  }

  func updateNSView(_ view: MousePadNSView, context: Context) {
    view.model = model
    view.onFocusChange = { focused = $0 }
  }
}

@MainActor final class MousePadNSView: NSView {
  var model: MacKeyboardTrackpadModel?
  var onFocusChange: ((Bool) -> Void)?
  // AppKit owns these views on the main thread; deinit is nonisolated in Swift 6.
  nonisolated(unsafe) private var keyWindowObserver: NSObjectProtocol?
  private var mouseTrackingArea: NSTrackingArea?
  private var consumingArmingGesture = false
  private var blockedTouchSequence = false

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
      window.acceptsMouseMovedEvents = true
      keyWindowObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: window, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.model?.surfaceLost(.pad) }
      }
    }
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

  override func mouseDown(with event: NSEvent) {
    model?.cancelScrollGesture()
    let wasActivePad = model?.isControlling == true && model?.currentSurface == .pad
    consumingArmingGesture = !wasActivePad
    window?.makeFirstResponder(self)
    if wasActivePad { model?.pointerButtonDown() }
    else { model?.requestControl(on: .pad) }
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 && event.modifierFlags.contains([.command, .shift]) {
      model?.stopControlling()
      return
    }
    super.keyDown(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if consumingArmingGesture { consumingArmingGesture = false; return }
    if model?.isControlling == true && model?.currentSurface == .pad {
      model?.pointerButtonUp()
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    model?.cancelScrollGesture()
    let wasActivePad = model?.isControlling == true && model?.currentSurface == .pad
    consumingArmingGesture = !wasActivePad
    window?.makeFirstResponder(self)
    if wasActivePad { model?.pointerButtonDown(secondary: true) }
    else { model?.requestControl(on: .pad) }
  }

  override func rightMouseUp(with event: NSEvent) {
    if consumingArmingGesture { consumingArmingGesture = false; return }
    if model?.isControlling == true && model?.currentSurface == .pad {
      model?.pointerButtonUp()
    }
  }

  override func mouseMoved(with event: NSEvent) { sendMotion(event) }
  override func mouseDragged(with event: NSEvent) { sendMotion(event) }
  override func rightMouseDragged(with event: NSEvent) { sendMotion(event) }

  override func scrollWheel(with event: NSEvent) {
    guard !consumingArmingGesture, !blockedTouchSequence else { return }
    model?.scrollGesture(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
      phase: event.phase, precise: event.hasPreciseScrollingDeltas, momentum: !event.momentumPhase.isEmpty)
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
      model?.cancelScrollGesture()
    } else if count == 0 { blockedTouchSequence = false }
  }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { onFocusChange?(true) }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted {
      onFocusChange?(false)
      model?.surfaceLost(.pad)
    }
    return accepted
  }

  override func cancelOperation(_ sender: Any?) { model?.stopControlling() }

  deinit {
    if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
  }

  private func sendMotion(_ event: NSEvent) {
    guard !consumingArmingGesture, !blockedTouchSequence, model?.isScrolling != true,
          model?.isControlling == true, model?.currentSurface == .pad else { return }
    model?.pointerMoved(deltaX: event.deltaX, deltaY: -event.deltaY)
  }
}
