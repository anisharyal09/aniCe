// SPDX-License-Identifier: GPL-3.0-or-later
// Owns the floating clipboard tray, its copy confirmation, and its dismissal lifecycle.
import AppKit
import SwiftUI

struct PasteTrayCopyToast: View {
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Label("Copied. Paste anywhere with ⌘V.", systemImage: "checkmark.circle.fill")
      .font(.callout)
      .padding(.horizontal, 14)
      .frame(width: 260, height: 42)
      .background(.regularMaterial, in: Capsule())
      .overlay(Capsule().stroke(AniCePalette.separator(scheme)))
      .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Copied to clipboard. Paste with Command V.")
  }
}

/// Non-activating panel that accepts keystrokes for search and selection without deactivating the user's host app.
@MainActor
final class PasteTrayPanel: NSPanel {
  // Non-activating panels must become key to accept native keyboard focus.
  override var canBecomeKey: Bool { true }
  // Never steal main status so the host document/editor retains active responder state underneath.
  override var canBecomeMain: Bool { false }
}

/// Coordinates singleton lifecycle, screen positioning, and automatic dismiss-on-blur for the quick paste tray.
@MainActor
final class PasteTrayController: NSObject, NSWindowDelegate {
  static let shared = PasteTrayController()

  private var panel: PasteTrayPanel?
  private var copyToast: NSPanel?
  private var copyToastTask: Task<Void, Never>?
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
    let width = max(280, min(CGFloat(690), (screen?.visibleFrame.width ?? 738) - 48))
    let collapsedHeight: CGFloat = width <= 650 ? 318 : 292
    if panel == nil {
      // Non-activating panel style mask prevents OS application deactivation while floating over other windows.
      let panel = PasteTrayPanel(
        contentRect: NSRect(x: 0, y: 0, width: width, height: collapsedHeight),
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

      self.panel = panel
    }

    guard let panel else { return }
    panel.setContentSize(NSSize(width: width, height: collapsedHeight))
    let hostingView = NSHostingView(rootView: PasteTrayView(
      model: model, width: width,
      onDismiss: { [weak self] in self?.hide() },
      onSelect: { entry in
        model.copyHistory(entry)
      },
      onCopied: { [weak self] in self?.showCopyFeedback(on: screen) },
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

  private func showCopyFeedback(on screen: NSScreen?) {
    copyToastTask?.cancel()
    let size = NSSize(width: 260, height: 42)
    if copyToast == nil {
      let toast = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
      toast.level = .floating
      toast.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      toast.isOpaque = false
      toast.backgroundColor = .clear
      toast.hasShadow = true
      toast.contentView = NSHostingView(rootView: PasteTrayCopyToast())
      copyToast = toast
    }
    guard let copyToast else { return }
    copyToast.setContentSize(size)
    if let frame = (screen ?? NSScreen.main)?.visibleFrame {
      copyToast.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
    }
    copyToast.orderFront(nil)
    copyToastTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1400))
      guard !Task.isCancelled else { return }
      self?.copyToast?.orderOut(nil)
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
