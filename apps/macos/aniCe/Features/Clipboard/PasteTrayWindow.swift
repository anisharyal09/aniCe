// SPDX-License-Identifier: GPL-3.0-or-later
// Presents the floating Quick Paste Tray panel above the user's active application.
import AppKit
import SwiftUI

/// Non-activating panel that accepts keystrokes for search and selection without deactivating the user's host app.
@MainActor
final class PasteTrayPanel: NSPanel {
  var onEscape: () -> Void = {}

  // Non-activating panels must become key to accept native keyboard focus.
  override var canBecomeKey: Bool { true }
  // Never steal main status so the host document/editor retains active responder state underneath.
  override var canBecomeMain: Bool { false }

  // Standard AppKit responder hook for Escape cancellation.
  override func cancelOperation(_ sender: Any?) {
    onEscape()
  }
}

/// Coordinates singleton lifecycle, screen positioning, and automatic dismiss-on-blur for the quick paste tray.
@MainActor
final class PasteTrayController: NSObject, NSWindowDelegate {
  static let shared = PasteTrayController()

  private var panel: PasteTrayPanel?
  private var model: MacClipboardModel?
  private var outsideClickMonitor: Any?

  func setup(model: MacClipboardModel) {
    self.model = model
  }

  var isVisible: Bool {
    panel?.isVisible ?? false
  }

  func toggle() {
    if isVisible {
      hide()
    } else {
      show()
    }
  }

  func show() {
    guard let model else { return }

    CompanionHost.currentHost?.close()
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    let width = min(CGFloat(760), (screen?.visibleFrame.width ?? 792) - 32)
    if panel == nil {
      // Non-activating panel style mask prevents OS application deactivation while floating over other windows.
      let panel = PasteTrayPanel(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 292),
        styleMask: [.nonactivatingPanel, .borderless],
        backing: .buffered,
        defer: false
      )
      panel.level = .floating
      panel.isFloatingPanel = true
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel.isMovableByWindowBackground = true
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = true
      panel.delegate = self
      panel.onEscape = { [weak self] in
        self?.hide()
      }

      self.panel = panel
    }

    guard let panel else { return }
    panel.setContentSize(NSSize(width: width, height: 292))
    let hostingView = NSHostingView(rootView: PasteTrayView(
      model: model, width: width,
      onDismiss: { [weak self] in self?.hide() },
      onSelect: { [weak self] entry in
        if model.copyHistory(entry) { self?.hide() }
      },
      previewHeight: min(460, (screen?.visibleFrame.height ?? 516) - 56),
      onHeightChange: { [weak self] height in
        guard let panel = self?.panel else { return }
        let origin = panel.frame.origin
        panel.setContentSize(NSSize(width: width, height: height))
        panel.setFrameOrigin(origin)
      }
    ))
    panel.contentView = hostingView

    // Position centered horizontally at the bottom of the active display, respecting the Dock's visibleFrame.
    if let screen {
      let screenFrame = screen.visibleFrame
      let x = screenFrame.midX - (panel.frame.width / 2)
      let y = screenFrame.minY + 28
      panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    panel.orderFront(nil)
    panel.makeKey()
    if outsideClickMonitor == nil {
      outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
        Task { @MainActor in self?.hide() }
      }
    }
  }

  func hide() {
    if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
    panel?.orderOut(nil)
    panel?.contentView = nil
  }

  // Dismiss automatically whenever the user clicks outside into another window or application.
  func windowDidResignKey(_ notification: Notification) {
    hide()
  }
}
