// SPDX-License-Identifier: GPL-3.0-or-later
// Presents one attempt-bound numeric comparison in-window or in a non-activating native panel.
import AppKit
import Observation
import SwiftUI

struct MacComparisonCard: View {
  @Bindable var model: MacPairingModel
  var openApp: (() -> Void)?
  @Environment(\.colorScheme) private var scheme
  @AppStorage("ui.fontScale") private var fontScale = 1.0

  var body: some View {
    let attempt = model.comparisonAttempt
    VStack(alignment: .leading, spacing: 12) {
      if let openApp {
        Button(action: openApp) {
          VStack(alignment: .leading, spacing: 12) { headingAndDigits }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Open aniCe to review this pairing")
      } else { headingAndDigits }
      Text(model.phase == "comparison" ? "Confirm only if this code matches your phone." : model.status)
        .font(.system(size: 13 * fontScale))
        .foregroundStyle(AniCePalette.secondaryText(scheme))
        .fixedSize(horizontal: false, vertical: true)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) { actions(attempt) }
        VStack(alignment: .leading, spacing: 8) { actions(attempt) }
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(AniCePalette.primaryText(scheme))
    .background(AniCePalette.surface(scheme), in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(AniCePalette.separator(scheme), lineWidth: 1))
  }

  @ViewBuilder private var headingAndDigits: some View {
    HStack(spacing: 12) {
      Image(systemName: "smartphone")
        .font(.system(size: 24, weight: .regular))
        .foregroundStyle(AniCePalette.secondaryText(scheme))
        .frame(width: 28, height: 36)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text("Connect your phone").font(.system(size: 15 * fontScale, weight: .semibold))
        Text("aniCe · Nearby pairing").font(.system(size: 12 * fontScale))
          .foregroundStyle(AniCePalette.secondaryText(scheme))
      }
    }
    if let code = model.comparisonCode {
      Text(String(code.prefix(3)) + " " + String(code.suffix(3)))
        .font(.system(size: 28 * fontScale, weight: .semibold, design: .monospaced))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityLabel("Comparison code " + code.map(String.init).joined(separator: " "))
    }
  }

  @ViewBuilder private func actions(_ attempt: UUID) -> some View {
    Button("Confirm") {
      model.confirmComparison(attempt: attempt)
      openApp?()
    }
    .buttonStyle(AniCeButtonStyle(prominent: true))
    .disabled(model.phase != "comparison")
    Button("Dismiss") { model.dismissComparison(attempt: attempt) }
      .buttonStyle(AniCeButtonStyle())
      .keyboardShortcut(.cancelAction)
      .disabled(model.phase == "cancelling" || model.phase == "saving")
  }
}

@MainActor private final class ComparisonPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// Native visibility events move the same model between surfaces; no second pairing owner exists.
@MainActor final class MacComparisonPresenter {
  private let model: MacPairingModel
  private var panel: ComparisonPanel?
  private var observers: [NSObjectProtocol] = []
  private let openApp: () -> Void

  init(model: MacPairingModel, openApp: @escaping () -> Void) {
    self.model = model
    self.openApp = openApp
    let center = NotificationCenter.default
    for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
      NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
      NSApplication.didChangeScreenParametersNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in Task { @MainActor in self?.refresh() }
      })
    }
    model.comparisonChanged = { [weak self] in self?.refresh() }
  }

  func refresh() {
    guard model.comparisonCode != nil, model.nearbyEnabled,
      ["comparison", "waiting"].contains(model.phase) else { hide(); return }
    let inApp = NSApp.isActive && NSApp.windows.contains {
      ($0.identifier?.rawValue == "main" || $0.title == MacAppStorage.applicationName)
        && $0.isVisible && !$0.isMiniaturized
    }
    if inApp { hide(); return }
    let panel = makePanel()
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
      ?? NSScreen.main else { return }
    let width = min(360, screen.visibleFrame.width - 32)
    if let hosting = panel.contentView as? NSHostingView<AnyView> {
      hosting.rootView = AnyView(MacComparisonCard(model: model, openApp: openApp).frame(width: width))
    }
    let height = min(max(220, panel.contentView?.fittingSize.height ?? 260),
      screen.visibleFrame.height - 40)
    panel.setFrame(NSRect(x: screen.visibleFrame.midX - width / 2,
      y: screen.visibleFrame.maxY - height - 20, width: width, height: height), display: true)
    // orderFront does not take key focus from another app; user actions explicitly open aniCe.
    panel.orderFrontRegardless()
  }

  private func makePanel() -> ComparisonPanel {
    if let panel { return panel }
    let panel = ComparisonPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.setAccessibilityLabel("aniCe pairing comparison")
    panel.contentView = NSHostingView(rootView: AnyView(MacComparisonCard(model: model, openApp: openApp)))
    self.panel = panel
    return panel
  }
  func hide() { panel?.orderOut(nil) }
}
