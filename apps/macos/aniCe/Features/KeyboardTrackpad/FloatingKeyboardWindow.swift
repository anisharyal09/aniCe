// SPDX-License-Identifier: GPL-3.0-or-later
// Owns the persistent menu-bar keyboard button and its expanded input panel.
import AppKit
import Observation
import SwiftUI

@MainActor
private final class FloatingKeyboardPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@Observable @MainActor
final class FloatingKeyboardController: NSObject, NSWindowDelegate {
  private static let visibilityKey = "keyboardTrackpad.floatingVisible"
  private static let positionKey = "keyboardTrackpad.floatingPosition"
  private static let compactSize = NSSize(width: 48, height: 48)

  let model: MacKeyboardTrackpadModel
  private let preferences: UserDefaults
  private let presentationID = UUID()
  private let inputID = UUID()
  let expandedPresentationID = UUID()
  private var panel: FloatingKeyboardPanel?
  private var screenObserver: NSObjectProtocol?
  private var interruptionObservers: [NSObjectProtocol] = []
  private weak var previousKeyWindow: NSWindow?
  private var compactPositionBeforeExpansion: NSPoint?
  private var didMoveWhileExpanded = false
  private var isAdjustingPanelFrame = false
  private var didRestoreVisibility = false
  private var waitingForPairingCheck = false
  private var waitingForConnectionResult = false
  private var isShuttingDown = false
  var onOpenDevices: () -> Void = {}

  private(set) var isVisible = false
  private(set) var isExpanded = false

  init(model: MacKeyboardTrackpadModel, preferences: UserDefaults = .standard) {
    self.model = model
    self.preferences = preferences
    super.init()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.clampToVisibleScreen() }
    }
    let interruptionNames: [Notification.Name] = [
      NSApplication.didResignActiveNotification,
      NSMenu.didBeginTrackingNotification,
      NSPopover.willShowNotification,
      NSWindow.willBeginSheetNotification
    ]
    interruptionObservers = interruptionNames.map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.cancelPendingActivation() }
      }
    }
  }

  var captureOwner: KeyboardTrackpadCaptureOwner {
    KeyboardTrackpadCaptureOwner(presentationID: presentationID, inputID: inputID, surface: .keyboard)
  }

  var expandedSize: NSSize {
    guard let frame = screenForCurrentPanel()?.visibleFrame else { return NSSize(width: 680, height: 700) }
    return NSSize(width: min(680, max(300, frame.width - 24)), height: min(700, max(320, frame.height - 24)))
  }

  var accessibilityName: String {
    let phone = model.targetPeer?.deviceName ?? "no phone selected"
    return "Phone keyboard, \(phone), \(statusDescription)"
  }

  var statusDescription: String {
    if model.isControlling(owner: captureOwner) { return "active" }
    if model.isPending(owner: captureOwner) { return "connecting" }
    switch model.phase {
    case .setupNeeded: return "setup needed"
    case .disconnected: return "disconnected"
    case .connecting: return "connecting"
    case .connectedIdle: return "ready"
    case .controlling: return "active in another control"
    case .suspended: return "paused by phone"
    case .disconnecting: return "disconnecting"
    case .failed: return "connection failed"
    }
  }

  var symbolName: String {
    if model.isControlling(owner: captureOwner) { return "keyboard.fill" }
    switch model.phase {
    case .connecting, .disconnecting: return "arrow.triangle.2.circlepath"
    case .setupNeeded, .failed, .suspended: return "exclamationmark.triangle.fill"
    default: return "keyboard"
    }
  }

  func restoreIfNeeded() {
    guard !didRestoreVisibility, !isShuttingDown else { return }
    didRestoreVisibility = true
    guard preferences.bool(forKey: Self.visibilityKey) else { return }
    show(restoring: true)
  }

  func toggleVisibility() {
    if isVisible { hide() } else { show() }
  }

  func show(restoring: Bool = false) {
    guard !isVisible, !isShuttingDown else { return }
    let present: () -> Void = { [weak self] in
      guard let self else { return }
      self.present()
    }
    if !restoring, let host = CompanionHost.currentHost, host.isShown {
      _ = host.closeForInputHandoff(completion: present)
    } else {
      present()
    }
  }

  private func present() {
    guard !isShuttingDown else { return }
    isExpanded = false
    isVisible = true
    preferences.set(true, forKey: Self.visibilityKey)
    model.enterPanel(id: presentationID, automaticallyConnect: false, refreshPairedDevices: false)
    let panel = makePanelIfNeeded()
    // Snapshot the saved position before replacing an expanded hosting view can resize the panel.
    let compactFrame = positionedFrame(size: Self.compactSize)
    panel.contentView = NSHostingView(rootView: FloatingKeyboardPanelView(
      controller: self, model: model, onOpenDevices: onOpenDevices))
    setPanelFrame(compactFrame, display: false)
    preferences.set(NSStringFromRect(compactFrame), forKey: Self.positionKey)
    panel.orderFront(nil)
  }

  func expand() {
    guard isVisible, !isExpanded else { return }
    cancelPendingActivation()
    model.stopControl(owner: captureOwner)
    compactPositionBeforeExpansion = panel?.frame.origin
    didMoveWhileExpanded = false
    isExpanded = true
    setPanelFrame(expandedFrame(from: panel?.frame ?? positionedFrame(size: Self.compactSize)), display: true)
  }

  func collapse() {
    guard isVisible, isExpanded else { return }
    cancelPendingActivation()
    model.leavePanel(id: expandedPresentationID)
    let compactOrigin = didMoveWhileExpanded
      ? compactFrame(for: panel?.frame ?? .zero).origin
      : compactPositionBeforeExpansion ?? panel?.frame.origin ?? .zero
    isExpanded = false
    let compact = NSRect(origin: compactOrigin, size: Self.compactSize)
    let visibleCompact = screenForCurrentPanel().map { Self.clamp(compact, into: $0.visibleFrame) } ?? compact
    setPanelFrame(visibleCompact, display: true)
    preferences.set(NSStringFromRect(visibleCompact), forKey: Self.positionKey)
    compactPositionBeforeExpansion = nil
    didMoveWhileExpanded = false
  }

  func hide() {
    guard isVisible else { return }
    cancelPendingActivation()
    model.stopControl(owner: captureOwner)
    model.leavePanel(id: presentationID)
    model.leavePanel(id: expandedPresentationID)
    waitingForPairingCheck = false
    waitingForConnectionResult = false
    isExpanded = false
    isVisible = false
    preferences.set(false, forKey: Self.visibilityKey)
    panel?.orderOut(nil)
    panel?.contentView = nil
  }

  func shutdown() {
    guard !isShuttingDown else { return }
    isShuttingDown = true
    cancelPendingActivation()
    model.stopControl(owner: captureOwner)
    model.leavePanel(id: presentationID)
    model.leavePanel(id: expandedPresentationID)
    isVisible = false
    isExpanded = false
    panel?.orderOut(nil)
    panel?.contentView = nil
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    screenObserver = nil
    interruptionObservers.forEach(NotificationCenter.default.removeObserver)
    interruptionObservers.removeAll()
  }

  func rememberPreviousKeyWindow() {
    guard let panel, !panel.isKeyWindow else { return }
    previousKeyWindow = NSApp.keyWindow
  }

  func toggleCapture(from inputView: KeyboardInputNSView) {
    if model.isControlling(owner: captureOwner) || model.isPending(owner: captureOwner) {
      cancelPendingActivation()
      model.stopControl(owner: captureOwner)
      inputView.window?.makeFirstResponder(nil)
      if let previousKeyWindow, previousKeyWindow !== panel, previousKeyWindow.isVisible {
        previousKeyWindow.makeKeyAndOrderFront(nil)
      }
      return
    }

    if model.targetPeer == nil || (model.pairedDevicesChecked && model.needsDeviceLink) {
      expand()
      return
    }

    cancelPendingActivation()
    rememberPreviousKeyWindow()
    panel?.makeKeyAndOrderFront(nil)
    inputView.window?.makeFirstResponder(inputView)
    waitingForPairingCheck = !model.pairedDevicesChecked
    model.toggleControl(owner: captureOwner)
    if model.isPending(owner: captureOwner) {
      waitingForConnectionResult = true
    } else if model.phase == .setupNeeded {
      expand()
    } else if model.phase == .failed {
      expand()
    }
  }

  func pairingCheckChanged() {
    guard waitingForPairingCheck, model.pairedDevicesChecked else { return }
    waitingForPairingCheck = false
    if !model.isPending(owner: captureOwner) && model.needsDeviceLink { expand() }
  }

  func connectionPhaseChanged() {
    guard waitingForConnectionResult, model.phase != .connecting else { return }
    waitingForConnectionResult = false
    if model.phase == .failed { expand() }
  }

  func showContextMenu(from view: NSView) {
    cancelPendingActivation()
    model.applicationWasInterrupted()
    let menu = NSMenu()
    let expandItem = NSMenuItem(title: "Show full controls", action: #selector(showFullControlsFromMenu), keyEquivalent: "")
    expandItem.target = self
    menu.addItem(expandItem)
    menu.addItem(.separator())
    let hideItem = NSMenuItem(title: "Hide", action: #selector(hideFromMenu), keyEquivalent: "")
    hideItem.target = self
    menu.addItem(hideItem)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY), in: view)
  }

  @objc private func showFullControlsFromMenu() { expand() }
  @objc private func hideFromMenu() { hide() }

  func cancelPendingActivation() {
    waitingForPairingCheck = false
    waitingForConnectionResult = false
  }

  func windowDidMove(_ notification: Notification) {
    guard !isAdjustingPanelFrame else { return }
    if isExpanded { didMoveWhileExpanded = true }
    persistPosition()
  }
  func windowDidResize(_ notification: Notification) {
    guard !isAdjustingPanelFrame else { return }
    clampToVisibleScreen()
  }
  func windowDidChangeScreen(_ notification: Notification) {
    guard !isAdjustingPanelFrame else { return }
    clampToVisibleScreen()
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }

  private func makePanelIfNeeded() -> FloatingKeyboardPanel {
    if let panel { return panel }
    let panel = FloatingKeyboardPanel(contentRect: NSRect(origin: .zero, size: Self.compactSize),
      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    self.panel = panel
    return panel
  }

  private func screenForCurrentPanel() -> NSScreen? {
    if let panel, let screen = panel.screen { return screen }
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first
  }

  private func positionedFrame(size: NSSize) -> NSRect {
    let screens = NSScreen.screens
    guard let screen = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? screens.first else {
      return NSRect(origin: NSPoint(x: 20, y: 20), size: size)
    }
    if let saved = preferences.string(forKey: Self.positionKey) {
      let savedFrame = NSRectFromString(saved)
      // Earlier versions saved the expanded panel's bottom-left instead of the button position.
      let compact = savedFrame.height > Self.compactSize.height
        ? NSRect(x: savedFrame.minX, y: savedFrame.maxY - Self.compactSize.height,
          width: Self.compactSize.width, height: Self.compactSize.height)
        : NSRect(origin: savedFrame.origin, size: Self.compactSize)
      let screenForSavedPosition = screens.first(where: { $0.visibleFrame.intersects(compact) }) ?? screen
      let clampedCompact = Self.clamp(compact, into: screenForSavedPosition.visibleFrame)
      preferences.set(NSStringFromRect(clampedCompact), forKey: Self.positionKey)
      return frame(size: size, anchoredAt: clampedCompact, in: screenForSavedPosition.visibleFrame)
    }
    let visible = screen.visibleFrame
    return NSRect(x: visible.maxX - size.width - 20, y: visible.minY + 20,
      width: size.width, height: size.height)
  }

  private func clampToVisibleScreen() {
    guard let panel, panel.isVisible else { return }
    guard let screen = screenForCurrentPanel() else { return }
    let visible = screen.visibleFrame
    let clamped = Self.clamp(panel.frame, into: visible)
    guard clamped != panel.frame else { return }
    setPanelFrame(clamped, display: true)
  }

  private func persistPosition() {
    guard isVisible, let panel else { return }
    let compact = compactFrame(for: panel.frame)
    preferences.set(NSStringFromRect(compact), forKey: Self.positionKey)
  }

  private func expandedFrame(from compact: NSRect) -> NSRect {
    guard let screen = screenForCurrentPanel() else { return NSRect(origin: compact.origin, size: expandedSize) }
    return Self.clamp(frame(size: expandedSize, anchoredAt: compact, in: screen.visibleFrame), into: screen.visibleFrame)
  }

  private func compactFrame(for panelFrame: NSRect) -> NSRect {
    NSRect(x: panelFrame.minX, y: panelFrame.maxY - Self.compactSize.height,
      width: Self.compactSize.width, height: Self.compactSize.height)
  }

  private func setPanelFrame(_ frame: NSRect, display: Bool) {
    guard let panel else { return }
    isAdjustingPanelFrame = true
    panel.setFrame(frame, display: display)
    isAdjustingPanelFrame = false
  }

  private func frame(size: NSSize, anchoredAt compact: NSRect, in visible: NSRect) -> NSRect {
    let origin = NSPoint(x: compact.minX, y: compact.maxY - size.height)
    return Self.clamp(NSRect(origin: origin, size: size), into: visible)
  }

  static func clamp(_ frame: NSRect, into visible: NSRect) -> NSRect {
    let width = min(frame.width, visible.width)
    let height = min(frame.height, visible.height)
    let x = min(max(frame.minX, visible.minX), visible.maxX - width)
    let y = min(max(frame.minY, visible.minY), visible.maxY - height)
    return NSRect(x: x, y: y, width: width, height: height)
  }
}

@MainActor
private struct FloatingKeyboardPanelView: View {
  let controller: FloatingKeyboardController
  @Bindable var model: MacKeyboardTrackpadModel
  let onOpenDevices: () -> Void
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Group {
      if controller.isExpanded {
        expandedControls
      } else {
        compactControl
      }
    }
    .frame(width: controller.isExpanded ? controller.expandedSize.width : 48,
      height: controller.isExpanded ? controller.expandedSize.height : 48)
    .onChange(of: model.pairedDevicesChecked) { _, _ in controller.pairingCheckChanged() }
    .onChange(of: model.phase) { _, _ in controller.connectionPhaseChanged() }
  }

  private var compactControl: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 15)
        .fill(AniCePalette.surface(scheme))
      FloatingKeyboardInputSurface(controller: controller, model: model)
        .padding(3)
      Image(systemName: controller.symbolName)
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(AniCePalette.primaryText(scheme))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
      if model.isControlling(owner: controller.captureOwner) {
        Circle().fill(AniCePalette.accent(scheme)).frame(width: 9, height: 9)
          .overlay(Circle().stroke(AniCePalette.surface(scheme), lineWidth: 1.5))
          .offset(x: 19, y: 19)
          .accessibilityHidden(true)
          .allowsHitTesting(false)
      }
    }
    .overlay(RoundedRectangle(cornerRadius: 15).stroke(AniCePalette.separator(scheme), lineWidth: 0.75))
    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(controller.accessibilityName)
    .accessibilityHint("Click to toggle typing to the phone. Right-click for full controls or to hide the button.")
    .help(controller.accessibilityName)
  }

  private var expandedControls: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        ZStack {
          Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AniCePalette.secondaryText(scheme))
            .allowsHitTesting(false)
          FloatingWindowDragHandle()
        }
        .frame(width: 22, height: 24)
        .help("Drag to move floating controls")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Move floating controls")
        Label("Keyboard & Trackpad", systemImage: "keyboard")
          .font(.system(size: 13, weight: .medium))
        Spacer()
        Label("Floating", systemImage: "macwindow")
          .font(.caption2.weight(.medium))
          .foregroundStyle(AniCePalette.accent(scheme))
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          .background(AniCePalette.accent(scheme).opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
          .accessibilityLabel("Floating control window")
        Button("Collapse", action: controller.collapse)
        Button("Hide", action: controller.hide)
      }
      .buttonStyle(AniCeButtonStyle(compact: true))
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(AniCePalette.surface(scheme))
      Divider()
      ScrollView {
        MacKeyboardTrackpadView(model: model, presentationID: controller.expandedPresentationID,
          floatingPresentation: true,
          onOpenDevices: onOpenDevices)
          .padding(14)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(AniCePalette.background(scheme))
    }
    .foregroundStyle(AniCePalette.primaryText(scheme))
    .background(AniCePalette.background(scheme))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AniCePalette.separator(scheme), lineWidth: 0.75))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
  }
}

@MainActor
private struct FloatingWindowDragHandle: NSViewRepresentable {
  func makeNSView(context: Context) -> FloatingWindowDragHandleView {
    FloatingWindowDragHandleView()
  }

  func updateNSView(_ view: FloatingWindowDragHandleView, context: Context) {}
}

@MainActor
private final class FloatingWindowDragHandleView: NSView {
  override var acceptsFirstResponder: Bool { false }

  override func mouseDown(with event: NSEvent) {
    window?.performDrag(with: event)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }
}

@MainActor
private struct FloatingKeyboardInputSurface: NSViewRepresentable {
  let controller: FloatingKeyboardController
  let model: MacKeyboardTrackpadModel

  func makeNSView(context: Context) -> KeyboardInputNSView {
    let view = KeyboardInputNSView()
    configure(view)
    return view
  }

  func updateNSView(_ view: KeyboardInputNSView, context: Context) { configure(view) }

  private func configure(_ view: KeyboardInputNSView) {
    view.model = model
    view.presentationID = controller.captureOwner.presentationID
    view.inputID = controller.captureOwner.inputID
    view.floatingToggleEnabled = true
    view.onFloatingMouseDown = { [weak controller] in controller?.rememberPreviousKeyWindow() }
    view.onFloatingClick = { [weak controller] in controller?.toggleCapture(from: view) }
    view.onFloatingRightClick = { [weak controller] in controller?.showContextMenu(from: view) }
    view.onFloatingFocusLost = { [weak controller] in controller?.cancelPendingActivation() }
  }
}
