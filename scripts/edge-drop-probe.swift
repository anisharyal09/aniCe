#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Probes public AppKit file-drag detection and native edge destinations without transferring files.
import AppKit

struct EdgeDragProbeState {
  enum Edge: String, CaseIterable { case right, left, top }
  var baseline: Int
  var enabled = true
  var edge: Edge = .right

  mutating func mouseDown(changeCount: Int) { baseline = changeCount }

  func qualifies(changeCount: Int, hasFileURLs: Bool, leftPressed: Bool, point: NSPoint, frame: NSRect) -> Bool {
    let withinHorizontalEdge = point.x >= frame.minX - 1 && point.x <= frame.maxX + 1
    let withinVerticalEdge = point.y >= frame.minY - 1 && point.y <= frame.maxY + 1
    guard enabled, leftPressed, hasFileURLs, changeCount != baseline,
      withinHorizontalEdge, withinVerticalEdge else { return false }
    switch edge {
    case .right: return point.x >= frame.maxX - 18
    case .left: return point.x <= frame.minX + 18
    case .top: return point.y >= frame.maxY - 18
    }
  }

  func shelfFrame(in frame: NSRect) -> NSRect {
    let width = min(260, frame.width), height = min(100, frame.height)
    switch edge {
    case .right: return NSRect(x: frame.maxX - width, y: frame.midY - height / 2, width: width, height: height)
    case .left: return NSRect(x: frame.minX, y: frame.midY - height / 2, width: width, height: height)
    case .top: return NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
    }
  }
}

func selfTest() {
  let frame = NSRect(x: -1200, y: 100, width: 1000, height: 800)
  var state = EdgeDragProbeState(baseline: 10)
  let point = NSPoint(x: frame.maxX - 2, y: frame.midY)
  func qualifies(_ count: Int, _ files: Bool, _ pressed: Bool) -> Bool {
    state.qualifies(changeCount: count, hasFileURLs: files, leftPressed: pressed, point: point, frame: frame)
  }
  precondition(!qualifies(10, true, true)) // Stale drag data cannot reveal the shelf.
  precondition(!qualifies(11, false, true))
  precondition(!qualifies(11, true, false))
  precondition(qualifies(11, true, true))
  state.mouseDown(changeCount: 11)
  precondition(!qualifies(11, true, true))
  state.enabled = false
  precondition(!qualifies(12, true, true))
  state.enabled = true
  for edge in EdgeDragProbeState.Edge.allCases {
    state.edge = edge
    let shelf = state.shelfFrame(in: frame)
    precondition(frame.contains(shelf))
    let activation: NSPoint
    switch edge {
    case .right: activation = point
    case .left: activation = NSPoint(x: frame.minX + 2, y: frame.midY)
    case .top: activation = NSPoint(x: frame.midX, y: frame.maxY - 2)
    }
    precondition(state.qualifies(changeCount: 12, hasFileURLs: true, leftPressed: true, point: activation, frame: frame))
    let exactBoundary: NSPoint = switch edge {
    case .right: NSPoint(x: frame.maxX, y: frame.midY)
    case .left: NSPoint(x: frame.minX, y: frame.midY)
    case .top: NSPoint(x: frame.midX, y: frame.maxY)
    }
    precondition(state.qualifies(changeCount: 12, hasFileURLs: true, leftPressed: true, point: exactBoundary, frame: frame))
    precondition(!state.qualifies(changeCount: 12, hasFileURLs: true, leftPressed: true,
      point: NSPoint(x: frame.maxX + 2, y: frame.midY), frame: frame))
  }
  print("Edge probe policy: stale data, non-file drags, disabled state, mouse release and all three edge geometries passed.")
}

@MainActor final class ProbeDropView: NSView {
  weak var owner: EdgeDropProbe?
  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
    owner?.recordDestinationEntered()
    return .copy
  }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
  override func draggingExited(_ sender: NSDraggingInfo?) { owner?.hideShelf(reason: "Drag exited or canceled") }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let files = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
    guard !files.isEmpty else { return false }
    owner?.hideShelf(reason: "Dropped \(files.count) file URL(s); no files read, copied or sent")
    return true
  }
}

@MainActor final class EdgeDropProbe: NSObject, NSApplicationDelegate {
  private var policy = EdgeDragProbeState(baseline: NSPasteboard(name: .drag).changeCount)
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var shelf: NSPanel?
  private var expiry: Timer?
  private var dragTracker: Timer?
  private var control: NSWindow?
  private let status = NSTextField(wrappingLabelWithString: "Drag Finder files toward an edge. No files will be transferred.")
  private var enabledButton: NSButton?
  private var lastReport = ""
  private var dragSawFreshData = false
  private var dragSawFileURLs = false
  private var dragReachedEdge = false
  private var dragShowedShelf = false
  private var dragEnteredDestination = false

  func report(_ message: String) {
    guard lastReport != message else { return }
    lastReport = message
    status.stringValue = message
    print(message)
    fflush(stdout)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let menu = NSMenu(), app = NSMenuItem(), submenu = NSMenu()
    submenu.addItem(withTitle: "Quit probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    app.submenu = submenu; menu.addItem(app); NSApplication.shared.mainMenu = menu
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 440, height: 190), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "aniCe Edge Drop feasibility probe"
    let label = NSTextField(wrappingLabelWithString: "Choose an edge, then drag files from Finder toward it. This probe counts dropped URLs only. It does not send or modify files.")
    let edgeButtons = EdgeDragProbeState.Edge.allCases.enumerated().map { index, edge in
      let button = NSButton(title: edge.rawValue.capitalized, target: self, action: #selector(selectEdge(_:)))
      button.tag = index
      return button
    }
    let toggle = NSButton(title: "Disable probe", target: self, action: #selector(toggleEnabled))
    enabledButton = toggle
    let row = NSStackView(views: edgeButtons + [toggle]); row.orientation = .horizontal
    let stack = NSStackView(views: [label, row, status]); stack.orientation = .vertical; stack.spacing = 14
    stack.translatesAutoresizingMaskIntoConstraints = false
    window.contentView?.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 18),
      stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -18),
      stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 18)
    ])
    control = window; window.makeKeyAndOrderFront(nil)
    enable()
  }

  @objc private func selectEdge(_ sender: NSButton) {
    hideShelf(reason: "Edge changed")
    policy.edge = EdgeDragProbeState.Edge.allCases[sender.tag]
    report("Selected \(policy.edge.rawValue) edge")
  }

  @objc private func toggleEnabled() {
    if policy.enabled { disable() } else { enable() }
    enabledButton?.title = policy.enabled ? "Disable probe" : "Enable probe"
  }

  private func enable() {
    policy.enabled = true
    policy.baseline = NSPasteboard(name: .drag).changeCount
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.observe(event) }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in self?.observe(event); return event }
    report("Enabled · \(policy.edge.rawValue) edge · global monitor installed: \(globalMonitor != nil)")
  }

  private func disable() {
    policy.enabled = false
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    globalMonitor = nil; localMonitor = nil
    dragTracker?.invalidate(); dragTracker = nil
    hideShelf(reason: "Disabled · monitors, shelf and drag timers removed")
  }

  private func observe(_ event: NSEvent) {
    let pasteboard = NSPasteboard(name: .drag)
    if event.type == .leftMouseDown {
      policy.mouseDown(changeCount: pasteboard.changeCount)
      beginDragTracking()
      return
    }
    if event.type == .leftMouseUp {
      dragTracker?.invalidate(); dragTracker = nil
      let answer = "Released · fresh data: \(dragSawFreshData ? "yes" : "no") · file URLs: \(dragSawFileURLs ? "yes" : "no") · reached edge: \(dragReachedEdge ? "yes" : "no") · shelf: \(dragShowedShelf ? "yes" : "no") · target entered: \(dragEnteredDestination ? "yes" : "no")"
      hideShelf(reason: answer, updateStatus: false)
      report(answer)
      return
    }
    if event.type == .leftMouseDragged { inspectDrag() }
  }

  private func beginDragTracking() {
    dragTracker?.invalidate()
    dragSawFreshData = false
    dragSawFileURLs = false
    dragReachedEdge = false
    dragShowedShelf = false
    dragEnteredDestination = false
    let deadline = ProcessInfo.processInfo.systemUptime + 30
    report("Mouse down · waiting for a fresh file drag")
    dragTracker = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
      MainActor.assumeIsolated {
        guard let self, self.policy.enabled,
              ProcessInfo.processInfo.systemUptime < deadline,
              NSEvent.pressedMouseButtons & 1 != 0 else {
          timer.invalidate()
          self?.dragTracker = nil
          self?.hideShelf(reason: "Mouse tracking ended")
          return
        }
        self.inspectDrag()
      }
    }
    RunLoop.main.add(dragTracker!, forMode: .common)
  }

  private func inspectDrag() {
    guard policy.enabled else { return }
    let pasteboard = NSPasteboard(name: .drag)
    let point = NSEvent.mouseLocation
    let screens = NSScreen.screens
    let screen = screens.first(where: { $0.frame.contains(point) }) ?? screens.min {
      distance(from: point, to: $0.frame) < distance(from: point, to: $1.frame)
    }
    guard let screen, distance(from: point, to: screen.frame) <= 1 else { return }
    let files = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    let freshData = pasteboard.changeCount != policy.baseline
    let activationFrame = policy.edge == .top ? screen.visibleFrame : screen.frame
    let atEdge = policy.qualifies(changeCount: pasteboard.changeCount, hasFileURLs: files,
                                  leftPressed: NSEvent.pressedMouseButtons & 1 != 0, point: point, frame: activationFrame)
    dragSawFreshData = dragSawFreshData || freshData
    dragSawFileURLs = dragSawFileURLs || files
    dragReachedEdge = dragReachedEdge || atEdge
    if !dragSawFreshData || !dragSawFileURLs || !dragReachedEdge {
      report("Drag sample · fresh data: \(dragSawFreshData ? "yes" : "no") · file URLs: \(dragSawFileURLs ? "yes" : "no") · reached edge: \(dragReachedEdge ? "yes" : "no")")
    }
    if atEdge {
      showShelf(in: screen.visibleFrame)
    } else if let shelf, !shelf.frame.insetBy(dx: -24, dy: -24).contains(point) {
      hideShelf(reason: "Left activation region", updateStatus: false)
    }
  }

  private func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
    let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
    let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
    return hypot(dx, dy)
  }

  private func showShelf(in frame: NSRect) {
    guard shelf == nil else { return }
    let panel = NSPanel(contentRect: policy.shelfFrame(in: frame), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let view = ProbeDropView(frame: NSRect(origin: .zero, size: panel.frame.size)); view.owner = self
    let label = NSTextField(labelWithString: "Drop here · probe only")
    label.frame = NSRect(x: 24, y: 40, width: 220, height: 22)
    view.addSubview(label)
    panel.contentView = view
    shelf = panel; panel.orderFrontRegardless()
    dragShowedShelf = true
    report("Shelf revealed · \(policy.edge.rawValue)")
    // Bounds an abandoned candidate without introducing any idle polling.
    expiry = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.hideShelf(reason: "Probe reveal expired") }
    }
  }

  func recordDestinationEntered() {
    dragEnteredDestination = true
    report("Native drop destination entered")
  }

  func hideShelf(reason: String, updateStatus: Bool = true) {
    expiry?.invalidate(); expiry = nil
    shelf?.orderOut(nil); shelf?.contentView = nil; shelf = nil
    if updateStatus { report(reason) }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationWillTerminate(_ notification: Notification) { disable() }
}

if CommandLine.arguments.contains("--self-test") {
  selfTest()
} else {
  MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = EdgeDropProbe()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
  }
}
