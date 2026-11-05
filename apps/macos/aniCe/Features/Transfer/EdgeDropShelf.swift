// SPDX-License-Identifier: GPL-3.0-or-later
// Reveals a native, non-activating file target during an active Finder drag.

import AppKit
import Observation
import SwiftUI

enum EdgeDropEdge: String, CaseIterable, Identifiable {
  case right, left, top

  var id: Self { self }
  var title: String { rawValue.capitalized }
}

@Observable @MainActor final class EdgeDropPreferences {
  private let storage: UserDefaults?
  private let enabledKey = "fileTransfer.edgeDrop.enabled"
  private let edgeKey = "fileTransfer.edgeDrop.edge"

  private(set) var enabled: Bool
  private(set) var edge: EdgeDropEdge

  init(storage: UserDefaults? = nil) {
    self.storage = storage
    enabled = storage?.object(forKey: enabledKey) as? Bool ?? false
    edge = storage?.string(forKey: edgeKey).flatMap(EdgeDropEdge.init(rawValue:)) ?? .right
  }

  func setEnabled(_ value: Bool) {
    if value, storage?.object(forKey: edgeKey) == nil {
      storage?.set(EdgeDropEdge.right.rawValue, forKey: edgeKey)
    }
    enabled = value
    storage?.set(value, forKey: enabledKey)
  }

  func setEdge(_ value: EdgeDropEdge) {
    edge = value
    storage?.set(value.rawValue, forKey: edgeKey)
  }
}

enum EdgeDropGeometry {
  static let edgeBand: CGFloat = 48
  static let shelfSize = NSSize(width: 360, height: 152)

  static func qualifies(
    point: NSPoint, edge: EdgeDropEdge, screenFrame: NSRect, visibleFrame: NSRect,
    hasFreshFileDrag: Bool, leftMouseDown: Bool
  ) -> Bool {
    guard hasFreshFileDrag, leftMouseDown else { return false }
    let frame = edge == .top ? visibleFrame : screenFrame
    guard point.x >= frame.minX - 1, point.x <= frame.maxX + 1,
      point.y >= frame.minY - 1, point.y <= frame.maxY + 1 else { return false }
    return switch edge {
    case .right: point.x >= screenFrame.maxX - edgeBand
    case .left: point.x <= screenFrame.minX + edgeBand
    // visibleFrame places the top trigger below the menu bar and notch area.
    case .top: point.y >= visibleFrame.maxY - edgeBand
    }
  }

  static func shelfFrame(
    edge: EdgeDropEdge, point: NSPoint, screenFrame: NSRect, visibleFrame: NSRect
  ) -> NSRect {
    let width = min(shelfSize.width, visibleFrame.width)
    let height = min(shelfSize.height, visibleFrame.height)
    switch edge {
    case .right:
      return NSRect(x: screenFrame.maxX - width,
        y: clamp(point.y - height / 2, visibleFrame.minY, visibleFrame.maxY - height),
        width: width, height: height)
    case .left:
      return NSRect(x: screenFrame.minX,
        y: clamp(point.y - height / 2, visibleFrame.minY, visibleFrame.maxY - height),
        width: width, height: height)
    case .top:
      return NSRect(x: clamp(point.x - width / 2, visibleFrame.minX, visibleFrame.maxX - width),
        y: visibleFrame.maxY - height, width: width, height: height)
    }
  }

  static func offscreenFrame(from frame: NSRect, edge: EdgeDropEdge) -> NSRect {
    switch edge {
    case .right: frame.offsetBy(dx: frame.width, dy: 0)
    case .left: frame.offsetBy(dx: -frame.width, dy: 0)
    case .top: frame.offsetBy(dx: 0, dy: frame.height)
    }
  }

  private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
  }
}

@Observable @MainActor final class MacEdgeDropController {
  let model: MacTransferModel
  let preferences: EdgeDropPreferences
  var monitorError: String?
  private(set) var draggedFileCount = 0
  private(set) var hasFileURLs = false
  private(set) var hasPromisedFiles = false

  @ObservationIgnored private var started = false
  @ObservationIgnored private var sleeping = false
  @ObservationIgnored private var globalMonitor: Any?
  @ObservationIgnored private var localMonitor: Any?
  @ObservationIgnored private var dragTimer: Timer?
  @ObservationIgnored private var dismissTimer: Timer?
  @ObservationIgnored private var expiryTimer: Timer?
  @ObservationIgnored private var workspaceTokens: [NSObjectProtocol] = []
  @ObservationIgnored private var applicationTokens: [NSObjectProtocol] = []
  @ObservationIgnored private var pasteboardBaseline = NSPasteboard(name: .drag).changeCount
  @ObservationIgnored private var observedPasteboardCount: Int?
  @ObservationIgnored private var candidateIsFresh = false
  @ObservationIgnored private var selectionHasUnsupportedItems = false
  @ObservationIgnored private var shelf: NSPanel?
  @ObservationIgnored private var shelfFrame: NSRect?

  init(model: MacTransferModel, preferences: EdgeDropPreferences = EdgeDropPreferences()) {
    self.model = model
    self.preferences = preferences
  }

  func start() {
    guard !started else { return }
    started = true
    if preferences.enabled { activate() }
  }

  private func activate() {
    guard workspaceTokens.isEmpty, applicationTokens.isEmpty else { return }
    let workspace = NSWorkspace.shared.notificationCenter
    workspaceTokens.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification,
      object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.suspendForSleep() } })
    workspaceTokens.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
      object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.resumeAfterSleep() } })
    applicationTokens.append(NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.displayConfigurationChanged() } })
    installMonitors()
  }

  func shutdown() {
    started = false
    stopMonitoring()
    deactivate()
  }

  private func deactivate() {
    for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    for token in applicationTokens { NotificationCenter.default.removeObserver(token) }
    workspaceTokens.removeAll()
    applicationTokens.removeAll()
  }

  func setEnabled(_ enabled: Bool) {
    preferences.setEnabled(enabled)
    guard started else { return }
    if enabled { activate() } else { stopMonitoring(); deactivate() }
  }

  func setEdge(_ edge: EdgeDropEdge) {
    guard preferences.edge != edge else { return }
    preferences.setEdge(edge)
    dismissShelf()
    resetCandidate()
  }

  var canAcceptCurrentDrag: Bool {
    candidateIsFresh && hasFileURLs && !hasPromisedFiles && !selectionHasUnsupportedItems &&
      (1...128).contains(draggedFileCount) &&
      model.connectedAndroidRecipient != nil && !model.isBusy
  }

  var shelfTitle: String {
    if hasPromisedFiles { return "Save files before sending" }
    if selectionHasUnsupportedItems { return "Drop files only" }
    if !hasFileURLs { return "Drop a file to send" }
    if draggedFileCount > 128 { return "Choose 1–128 files" }
    if model.preparing { return "Preparing transfer…" }
    if model.isBusy { return "A transfer is already in progress" }
    guard model.connectedAndroidRecipient != nil else {
      return model.peerConnected ? "File transfer is unavailable" : "Connect an Android phone"
    }
    return "Send \(draggedFileCount) file\(draggedFileCount == 1 ? "" : "s") to"
  }

  var edgeHint: String { "\(preferences.edge.title.uppercased()) EDGE · DROP HERE" }

  var shelfDetail: String {
    if hasPromisedFiles { return "Promised files aren’t supported." }
    if selectionHasUnsupportedItems { return "Every item in the drop must be a local file." }
    if !hasFileURLs { return "Drag saved files from Finder." }
    if draggedFileCount > 128 { return "Send at most 128 files in one batch." }
    if model.preparing || model.isBusy { return model.activeChannel?.descriptor.peer.deviceName ?? "Wait for the current transfer to finish." }
    if let recipient = model.connectedAndroidRecipient { return recipient.deviceName }
    return model.activeChannel?.descriptor.peer.deviceName ?? "Connect a compatible phone to aniCe."
  }

  var shelfSymbol: String {
    if hasPromisedFiles || draggedFileCount > 128 { return "doc.badge.ellipsis" }
    if model.preparing { return "arrow.triangle.2.circlepath" }
    if model.isBusy { return "hourglass" }
    if model.connectedAndroidRecipient == nil { return "iphone.slash" }
    return "arrow.down.doc.fill"
  }

  var shelfColorScheme: ColorScheme { selectedColorScheme }

  func updateNativeDrag(_ pasteboard: NSPasteboard) -> NSDragOperation {
    refreshCandidate(from: pasteboard)
    return canAcceptCurrentDrag ? .copy : []
  }

  func enterNativeDrag(_ pasteboard: NSPasteboard) -> NSDragOperation {
    expiryTimer?.invalidate(); expiryTimer = nil
    return updateNativeDrag(pasteboard)
  }

  func finishDrop(_ urls: [URL]) -> Bool {
    let accepted = TransferDropSubmission.receive(urls: urls, model: model)
    dismissShelf()
    resetCandidate()
    return accepted
  }

  func draggingExitedShelf() {
    scheduleDismiss(after: 0.18)
  }

  private var selectedColorScheme: ColorScheme {
    let system = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? ColorScheme.dark : .light
    let setting = UserDefaults.standard.string(forKey: "window.appearance") ?? WindowAppearance.system.rawValue
    return WindowAppearance.stored(setting).colorScheme(system: system)
  }

  private func installMonitors() {
    guard started, preferences.enabled, !sleeping, globalMonitor == nil, localMonitor == nil else { return }
    pasteboardBaseline = NSPasteboard(name: .drag).changeCount
    // These monitors only observe active mouse drags; the local callback returns the original event.
    let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
      MainActor.assumeIsolated { self?.observe(event) }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
      MainActor.assumeIsolated { self?.observe(event) }
      return event
    }
    monitorError = globalMonitor == nil
      ? "Edge Drop couldn’t observe Finder drags on this Mac. In-app file drops still work."
      : nil
  }

  private func stopMonitoring() {
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    globalMonitor = nil
    localMonitor = nil
    dragTimer?.invalidate(); dragTimer = nil
    dismissShelf()
    resetCandidate()
    monitorError = nil
  }

  private func suspendForSleep() {
    sleeping = true
    stopMonitoring()
  }

  private func resumeAfterSleep() {
    sleeping = false
    if started, preferences.enabled { installMonitors() }
  }

  private func displayConfigurationChanged() {
    dragTimer?.invalidate(); dragTimer = nil
    dismissShelf()
    resetCandidate()
    pasteboardBaseline = NSPasteboard(name: .drag).changeCount
  }

  private func observe(_ event: NSEvent) {
    if event.type == .leftMouseDown {
      // A drag pasteboard can retain its previous contents; snapshot it before the new gesture.
      pasteboardBaseline = NSPasteboard(name: .drag).changeCount
      observedPasteboardCount = nil
      resetCandidate()
    } else if event.type == .leftMouseUp {
      dragTimer?.invalidate(); dragTimer = nil
      scheduleDismiss(after: 0.22)
    } else if event.type == .leftMouseDragged {
      // Poll only after AppKit reports a real held drag, never during ordinary idle or clicks.
      if dragTimer == nil { beginDragTracking() }
      inspectDrag()
    }
  }

  private func beginDragTracking() {
    dragTimer?.invalidate()
    let deadline = ProcessInfo.processInfo.systemUptime + 30
    let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        guard self.preferences.enabled,
          ProcessInfo.processInfo.systemUptime < deadline,
          NSEvent.pressedMouseButtons & 1 != 0 else {
          self.dragTimer?.invalidate()
          self.dragTimer = nil
          self.scheduleDismiss(after: 0.22)
          return
        }
        self.inspectDrag()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    dragTimer = timer
  }

  private func inspectDrag() {
    guard preferences.enabled, NSEvent.pressedMouseButtons & 1 != 0 else { return }
    let pasteboard = NSPasteboard(name: .drag)
    guard refreshCandidate(from: pasteboard), candidateIsFresh else {
      if let shelfFrame, !shelfFrame.insetBy(dx: -24, dy: -24).contains(NSEvent.mouseLocation) {
        dismissShelf()
      }
      return
    }
    // Read only file URL metadata from the drag pasteboard. File bytes are opened after the user drops.
    let point = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
    guard let screen,
      EdgeDropGeometry.qualifies(point: point, edge: preferences.edge, screenFrame: screen.frame,
        visibleFrame: screen.visibleFrame, hasFreshFileDrag: hasFileURLs || hasPromisedFiles,
        leftMouseDown: true) else {
      if let shelfFrame, !shelfFrame.insetBy(dx: -24, dy: -24).contains(point) { dismissShelf() }
      return
    }
    showShelf(on: screen, near: point)
  }

  @discardableResult private func refreshCandidate(from pasteboard: NSPasteboard) -> Bool {
    let count = pasteboard.changeCount
    if observedPasteboardCount == count { return candidateIsFresh }
    observedPasteboardCount = count
    candidateIsFresh = count != pasteboardBaseline
    guard candidateIsFresh else { resetCandidate(); return false }
    let types = pasteboard.types?.map(\.rawValue) ?? []
    hasPromisedFiles = TransferDropValidation.containsPromisedFile(types)
    hasFileURLs = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    draggedFileCount = hasFileURLs ? Self.fileURLs(from: pasteboard).count : 0
    selectionHasUnsupportedItems = hasFileURLs &&
      (pasteboard.pasteboardItems?.count ?? draggedFileCount) != draggedFileCount
    return hasFileURLs || hasPromisedFiles
  }

  private func showShelf(on screen: NSScreen, near point: NSPoint) {
    let target = EdgeDropGeometry.shelfFrame(edge: preferences.edge, point: point,
      screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
    dismissTimer?.invalidate(); dismissTimer = nil
    if let shelf {
      shelfFrame = target
      shelf.setFrame(target, display: true)
      scheduleExpiry()
      return
    }
    // A non-activating panel accepts the drag without taking keyboard focus from Finder or the current app.
    let panel = NSPanel(contentRect: target, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    let surface = EdgeDropSurface(controller: self, frame: NSRect(origin: .zero, size: target.size))
    panel.contentView = surface
    shelf = panel
    shelfFrame = target

    let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if reducedMotion {
      panel.setFrame(target, display: false)
      panel.alphaValue = 1
    } else {
      panel.setFrame(EdgeDropGeometry.offscreenFrame(from: target, edge: preferences.edge), display: false)
      panel.alphaValue = 0
    }
    panel.orderFrontRegardless()
    if !reducedMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().setFrame(target, display: true)
        panel.animator().alphaValue = 1
      }
    }
    scheduleExpiry()
  }

  private func scheduleExpiry() {
    expiryTimer?.invalidate()
    expiryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.dismissShelf() }
    }
  }

  private func scheduleDismiss(after interval: TimeInterval) {
    dismissTimer?.invalidate()
    dismissTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.dismissShelf() }
    }
  }

  private func dismissShelf() {
    expiryTimer?.invalidate(); expiryTimer = nil
    dismissTimer?.invalidate(); dismissTimer = nil
    shelf?.orderOut(nil)
    shelf?.close()
    shelf = nil
    shelfFrame = nil
  }

  private func resetCandidate() {
    candidateIsFresh = false
    draggedFileCount = 0
    hasFileURLs = false
    hasPromisedFiles = false
    selectionHasUnsupportedItems = false
  }

  fileprivate static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
    let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
    return objects.compactMap { ($0 as? NSURL).map { $0 as URL } }
  }
}

@MainActor private final class EdgeDropSurface: NSHostingView<AnyView> {
  weak var controller: MacEdgeDropController?

  init(controller: MacEdgeDropController, frame: NSRect) {
    self.controller = controller
    super.init(rootView: AnyView(EdgeDropShelfView(controller: controller)
      .preferredColorScheme(controller.shelfColorScheme)))
    self.frame = frame
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

  required init(rootView: AnyView) {
    super.init(rootView: rootView)
    registerForDraggedTypes([.fileURL])
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    controller?.enterNativeDrag(sender.draggingPasteboard) ?? []
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    controller?.updateNativeDrag(sender.draggingPasteboard) ?? []
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    controller?.draggingExitedShelf()
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    controller?.updateNativeDrag(sender.draggingPasteboard) == .copy
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let controller else { return false }
    let urls = MacEdgeDropController.fileURLs(from: sender.draggingPasteboard)
    return controller.finishDrop(urls)
  }
}

private struct EdgeDropShelfView: View {
  @Bindable var controller: MacEdgeDropController
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: controller.shelfSymbol)
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(controller.canAcceptCurrentDrag
          ? AniCePalette.accent(scheme) : AniCePalette.warning(scheme))
        .frame(width: 38)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        Text(controller.edgeHint)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(AniCePalette.accent(scheme))
          .lineLimit(1)
        Text(controller.shelfTitle)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(AniCePalette.primaryText(scheme))
          .lineLimit(2)
        Text(controller.shelfDetail)
          .font(.system(size: 13))
          .foregroundStyle(AniCePalette.secondaryText(scheme))
          .lineLimit(2)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 20)
    .frame(width: EdgeDropGeometry.shelfSize.width, height: EdgeDropGeometry.shelfSize.height)
    .background(AniCePalette.surface(scheme), in: RoundedRectangle(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16).stroke(AniCePalette.separator(scheme), lineWidth: 1)
    }
    .shadow(color: .black.opacity(scheme == .dark ? 0.24 : 0.12), radius: 16, y: 5)
    .accessibilityElement(children: .combine)
  }
}

struct EdgeDropSettingsView: View {
  let controller: MacEdgeDropController
  var showsPlacementPreview = false
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle("Edge Drop", isOn: Binding(
        get: { controller.preferences.enabled },
        set: { controller.setEnabled($0) }))
        .toggleStyle(.checkbox).aniCeControlFeedback(feedbackPadding: 3)
        .controlSize(.regular).frame(minHeight: 40, alignment: .leading)
      HStack {
        Text("Shelf edge")
        Spacer()
        Picker("Shelf edge", selection: Binding(
          get: { controller.preferences.edge },
          set: { controller.setEdge($0) })) {
          ForEach(EdgeDropEdge.allCases) { edge in Text(edge.title).tag(edge) }
        }
        .labelsHidden().pickerStyle(.menu).controlSize(.regular).frame(width: 112)
          .accessibilityLabel("Shelf edge")
      }
      .frame(minHeight: 40)
      Text(controller.preferences.enabled
        ? "Drag files to the selected edge and drop them on the shelf."
        : "Turn on to send files from Finder.")
        .font(.caption).foregroundStyle(AniCePalette.secondaryText(scheme))
        .fixedSize(horizontal: false, vertical: true)
      if let error = controller.monitorError {
        Text(error).font(.caption).foregroundStyle(AniCePalette.error(scheme))
      }
      if showsPlacementPreview {
        EdgeDropPlacementPreview(edge: controller.preferences.edge, enabled: controller.preferences.enabled)
          .padding(.top, 4)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct EdgeDropPlacementPreview: View {
  let edge: EdgeDropEdge
  let enabled: Bool
  @Environment(\.colorScheme) private var scheme

  private var markerAlignment: Alignment {
    switch edge {
    case .left: .leading
    case .right: .trailing
    case .top: .top
    }
  }

  var body: some View {
    HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 8)
        .stroke(AniCePalette.separator(scheme), lineWidth: 1)
        .overlay(alignment: .top) {
          Capsule()
            .fill(AniCePalette.separator(scheme))
            .frame(width: 38, height: 3)
            .padding(.top, 6)
        }
        .overlay(alignment: markerAlignment) {
          RoundedRectangle(cornerRadius: 3)
            .fill(enabled ? AniCePalette.accent(scheme) : AniCePalette.secondaryText(scheme))
            .frame(width: edge == .top ? 36 : 9, height: edge == .top ? 8 : 22)
            .padding(.leading, edge == .left ? 6 : 0)
            .padding(.trailing, edge == .right ? 6 : 0)
            .padding(.top, edge == .top ? 14 : 0)
        }
        .frame(width: 148, height: 72)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text("\(edge.title) edge")
          .font(.caption.weight(.medium))
          .foregroundStyle(AniCePalette.primaryText(scheme))
        Text(enabled ? "Shelf appears here." : "Turn on Edge Drop to use the shelf.")
          .font(.caption)
          .foregroundStyle(AniCePalette.secondaryText(scheme))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
