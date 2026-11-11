// SPDX-License-Identifier: GPL-3.0-or-later
// Defines semantic appearance colors and shared Mac control feedback.
import AppKit
import SwiftUI

enum AniCePalette {
  static func background(_ scheme: ColorScheme) -> Color {
    color(light: 0xF4F3EF, dark: 0x1B1E1E, scheme: scheme)
  }
  static func surface(_ scheme: ColorScheme) -> Color {
    color(light: 0xFFFDF9, dark: 0x242828, scheme: scheme)
  }
  static func accent(_ scheme: ColorScheme) -> Color {
    color(light: 0x47534D, dark: 0xC4CCC5, scheme: scheme)
  }
  static func onAccent(_ scheme: ColorScheme) -> Color {
    color(light: 0xFFFDF9, dark: 0x222A25, scheme: scheme)
  }
  static func primaryText(_ scheme: ColorScheme) -> Color {
    color(light: 0x282E2A, dark: 0xEBEEEB, scheme: scheme)
  }
  static func secondaryText(_ scheme: ColorScheme) -> Color {
    color(light: 0x626B65, dark: 0xADB5AF, scheme: scheme)
  }
  static func secondarySurface(_ scheme: ColorScheme) -> Color {
    color(light: 0xEAEAE4, dark: 0x222626, scheme: scheme)
  }
  static func separator(_ scheme: ColorScheme) -> Color {
    color(light: 0xDCDED8, dark: 0x3B4140, scheme: scheme)
  }
  static func subtleAccent(_ scheme: ColorScheme) -> Color {
    color(light: 0xE5E8E2, dark: 0x303632, scheme: scheme)
  }
  static func track(_ scheme: ColorScheme) -> Color {
    color(light: 0xE0E3DC, dark: 0x3B413E, scheme: scheme)
  }
  static func success(_ scheme: ColorScheme) -> Color {
    color(light: 0x466A50, dark: 0xA1C6A9, scheme: scheme)
  }
  static func warning(_ scheme: ColorScheme) -> Color {
    color(light: 0x825523, dark: 0xDCB27C, scheme: scheme)
  }
  static func error(_ scheme: ColorScheme) -> Color {
    color(light: 0xA13D38, dark: 0xE8AAA4, scheme: scheme)
  }
  static func wordmarkAccent(_ scheme: ColorScheme) -> Color {
    color(light: 0xD26458, dark: 0xE58B82, scheme: scheme)
  }

  private static func color(light: UInt32, dark: UInt32, scheme: ColorScheme) -> Color {
    let hex = scheme == .dark ? dark : light
    return Color(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: 1
    )
  }
}

struct AniCeWordmark: View {
  var size: CGFloat = 17
  var weight: Font.Weight = .semibold
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    (Text("ani") + Text("Ce").foregroundStyle(AniCePalette.wordmarkAccent(scheme)))
      .font(.system(size: size, weight: weight))
      .accessibilityLabel("aniCe")
  }
}

struct TitlebarWordmarkFormatter: NSViewRepresentable {
  let colorScheme: ColorScheme

  func makeNSView(context: Context) -> TitlebarObserverView {
    let view = TitlebarObserverView()
    view.colorScheme = colorScheme
    return view
  }

  func updateNSView(_ nsView: TitlebarObserverView, context: Context) {
    nsView.colorScheme = colorScheme
    nsView.colorize()
  }
}

final class TitlebarObserverView: NSView {
  var colorScheme: ColorScheme = .light

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self)
    if let window {
      NotificationCenter.default.addObserver(self, selector: #selector(handleWindowChange), name: NSWindow.didBecomeKeyNotification, object: window)
      NotificationCenter.default.addObserver(self, selector: #selector(handleWindowChange), name: NSWindow.didResignKeyNotification, object: window)
      NotificationCenter.default.addObserver(self, selector: #selector(handleWindowChange), name: NSWindow.didResizeNotification, object: window)
    }
    colorize()
  }

  @objc private func handleWindowChange() {
    colorize()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func colorize() {
    guard let window else { return }
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self, let window, let frameView = window.contentView?.superview else { return }
      self.formatTitleInView(frameView)
    }
  }

  private func formatTitleInView(_ view: NSView) {
    if let tf = view as? NSTextField, tf.stringValue == "aniCe" {
      let isDark = colorScheme == .dark
      let primary = isDark ? NSColor.white : NSColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x1A/255.0, alpha: 1.0)
      let coral = isDark ? NSColor(red: 0xE5/255.0, green: 0x8B/255.0, blue: 0x82/255.0, alpha: 1.0) : NSColor(red: 0xD2/255.0, green: 0x64/255.0, blue: 0x58/255.0, alpha: 1.0)
      let font = tf.font ?? NSFont.systemFont(ofSize: 13, weight: .semibold)
      let attr = NSMutableAttributedString(string: "ani", attributes: [.font: font, .foregroundColor: primary])
      attr.append(NSAttributedString(string: "Ce", attributes: [.font: font, .foregroundColor: coral]))
      tf.attributedStringValue = attr
    }
    for sub in view.subviews {
      formatTitleInView(sub)
    }
  }
}


// Keeps the reference's quiet or outlined face with native Button feedback and focus.
struct AniCeButtonStyle: ButtonStyle {
  var prominent = false
  var quiet = false
  var compact = false
  func makeBody(configuration: Configuration) -> some View {
    AniCeButtonFace(label: configuration.label, pressed: configuration.isPressed,
      prominent: prominent, quiet: quiet, compact: compact)
  }
}

private struct AniCeButtonFace<Label: View>: View {
  let label: Label
  let pressed: Bool
  let prominent: Bool
  let quiet: Bool
  let compact: Bool
  @AppStorage("ui.fontScale") private var fontScale = 1.0
  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var enabled
  @Environment(\.isFocused) private var focused

  var body: some View {
    label
      .font(.system(size: 13 * fontScale, weight: .medium))
      .foregroundStyle(prominent ? AniCePalette.onAccent(scheme) : AniCePalette.primaryText(scheme))
      .padding(.horizontal, quiet ? 0 : (compact ? 6 : 12)).padding(.vertical, compact ? 5 : 7)
      .frame(minWidth: compact ? 32 : nil, minHeight: (quiet || compact) ? 30 : 32)
      .background(prominent ? AniCePalette.accent(scheme) : (quiet ? .clear : AniCePalette.surface(scheme)), in: RoundedRectangle(cornerRadius: 7))
      .overlay {
        if !quiet || focused {
          RoundedRectangle(cornerRadius: 7).stroke(focused ? AniCePalette.accent(scheme) : AniCePalette.separator(scheme), lineWidth: focused ? 2 : 1)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 7))
      .aniCeControlFeedback(pressed: pressed, prominent: prominent, cornerRadius: 7)
      .opacity(enabled ? 1 : 0.45)
  }
}

struct AniCeHoverButtonStyle: ButtonStyle {
  var prominent = false
  var feedbackPadding: CGFloat = 0
  func makeBody(configuration: Configuration) -> some View {
    AniCeHoverButtonFace(label: configuration.label, pressed: configuration.isPressed, prominent: prominent, feedbackPadding: feedbackPadding)
  }
}

private struct AniCeHoverButtonFace<Label: View>: View {
  let label: Label
  let pressed: Bool
  let prominent: Bool
  let feedbackPadding: CGFloat
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    label.aniCeControlFeedback(pressed: pressed, prominent: prominent, feedbackPadding: feedbackPadding)
      .opacity(enabled ? 1 : 0.45)
  }
}

extension View {
  func aniCeControlFeedback(pressed: Bool = false, prominent: Bool = false, cornerRadius: CGFloat = 7, feedbackPadding: CGFloat = 0) -> some View {
    modifier(AniCeControlFeedback(pressed: pressed, prominent: prominent, cornerRadius: cornerRadius, feedbackPadding: feedbackPadding))
  }
}

private struct AniCeControlFeedback: ViewModifier {
  let pressed: Bool
  let prominent: Bool
  let cornerRadius: CGFloat
  let feedbackPadding: CGFloat
  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle().inset(by: -feedbackPadding))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius)
          .fill((prominent ? AniCePalette.onAccent(scheme) : AniCePalette.accent(scheme))
            .opacity(enabled ? (pressed ? 0.12 : (hovered ? 0.055 : 0)) : 0))
          // Feedback may extend around bare labels without intercepting their native control.
          .padding(-feedbackPadding).allowsHitTesting(false)
      }
      .onHover { hovered = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
  }
}
