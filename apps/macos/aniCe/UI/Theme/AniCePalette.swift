// SPDX-License-Identifier: GPL-3.0-or-later
// Defines semantic appearance colors and shared Mac control feedback.
import AppKit
import SwiftUI

enum NativeGlassStyle: String, CaseIterable {
  case standard = "Standard", vibrant = "Vibrant"
  static func stored(_ value: String) -> Self { Self(rawValue: value) ?? .standard }
  func navigationBackingOpacity(_ scheme: ColorScheme) -> Double {
    switch self {
    case .standard: scheme == .dark ? 0.45 : 0.35
    case .vibrant: scheme == .dark ? 0.08 : 0.06
    }
  }
}

enum NativeGlassPresentation: Equatable {
  case solid, material, glass

  static func resolve(enabled: Bool, reduceTransparency: Bool, supportsGlass: Bool) -> Self {
    guard enabled, !reduceTransparency else { return .solid }
    return supportsGlass ? .glass : .material
  }
}

extension View {
  func aniCeAppearance() -> some View {
    modifier(AniCeHostAppearance())
  }

  func aniCeSurface(cornerRadius: CGFloat = 0, secondary: Bool = false) -> some View {
    modifier(AniCeNativeSurface(cornerRadius: cornerRadius, secondary: secondary))
  }
}

private struct AniCeHostAppearance: ViewModifier {
  @AppStorage("window.appearance") private var appearance = WindowAppearance.system.rawValue
  @State private var systemAppearance = SystemAppearance()

  func body(content: Content) -> some View {
    content.preferredColorScheme(WindowAppearance.stored(appearance)
      .colorScheme(system: systemAppearance.colorScheme))
  }
}

private struct AniCeNativeSurface: ViewModifier {
  let cornerRadius: CGFloat
  let secondary: Bool
  @AppStorage("ui.nativeGlass") private var enabled = true
  @AppStorage("ui.nativeGlassStyle") private var savedStyle = NativeGlassStyle.standard.rawValue
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var scheme

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius)
    let surface = secondary ? AniCePalette.secondarySurface(scheme) : AniCePalette.surface(scheme)
    let presentation = NativeGlassPresentation.resolve(
      enabled: enabled, reduceTransparency: reduceTransparency, supportsGlass: supportsGlass)
    if presentation == .solid {
      content.background(surface, in: shape)
    } else if secondary {
      let style = NativeGlassStyle.stored(savedStyle)
      content.background {
        NativeNavigationMaterial()
          .overlay(surface.opacity(style.navigationBackingOpacity(scheme)).allowsHitTesting(false))
      }
    } else if #available(macOS 26.0, *) {
      if NativeGlassStyle.stored(savedStyle) == .vibrant {
        content.glassEffect(.regular.tint(AniCePalette.accent(scheme).opacity(scheme == .light ? 0.22 : 0.12)), in: shape)
      } else {
        content.glassEffect(.regular, in: shape)
      }
    } else {
      content.background(.regularMaterial, in: shape)
        .overlay {
          if NativeGlassStyle.stored(savedStyle) == .vibrant {
            shape.fill(AniCePalette.subtleAccent(scheme).opacity(0.15)).allowsHitTesting(false)
          }
        }
    }
  }

  private var supportsGlass: Bool {
    if #available(macOS 26.0, *) { return true }
    return false
  }
}

/// Large navigation surfaces use native window vibrancy, not a tinted floating glass card.
private struct NativeNavigationMaterial: NSViewRepresentable {
  @Environment(\.colorScheme) private var scheme

  func makeNSView(context: Context) -> NSVisualEffectView { NSVisualEffectView() }
  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.material = .sidebar
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
    view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
  }
}

struct NativeGlassPreferencesView: View {
  @AppStorage("ui.nativeGlass") private var enabled = true
  @AppStorage("ui.nativeGlassStyle") private var savedStyle = NativeGlassStyle.standard.rawValue
  @AppStorage("ui.fontScale") private var fontScale = 1.0
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    NativeGlassPreferencesRows(enabled: $enabled, savedStyle: $savedStyle,
      fontScale: fontScale, reduceTransparency: reduceTransparency)
  }
}

struct NativeGlassPreferencesRows: View {
  @Binding var enabled: Bool
  @Binding var savedStyle: String
  let fontScale: Double
  let reduceTransparency: Bool
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle("Native Glass", isOn: Binding(
        get: { enabled && !reduceTransparency },
        set: { if !reduceTransparency { enabled = $0 } }))
        .toggleStyle(.checkbox).aniCeControlFeedback()
        .disabled(reduceTransparency)
      if reduceTransparency {
        Text("Locked to Normal by macOS System Settings")
          .font(.system(size: 12 * fontScale)).foregroundStyle(AniCePalette.secondaryText(scheme))
          .fixedSize(horizontal: false, vertical: true)
      } else if enabled {
        Picker("Glass style", selection: Binding(
          get: { NativeGlassStyle.stored(savedStyle) }, set: { savedStyle = $0.rawValue })) {
          ForEach(NativeGlassStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityHint("Standard is softly backed. Vibrant lets more of the background show through.")
      }
    }.padding(.vertical, 8)
  }
}

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
  var prefix = ""
  var suffix = ""
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    (Text(prefix + "ani") + Text("Ce").foregroundStyle(AniCePalette.wordmarkAccent(scheme)) + Text(suffix))
      .font(.system(size: size, weight: weight))
      .accessibilityLabel(prefix + "aniCe" + suffix)
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
      .background(prominent ? AniCePalette.accent(scheme) : (quiet ? .clear : AniCePalette.secondarySurface(scheme)), in: RoundedRectangle(cornerRadius: 7))
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

/// Wraps measured shortcut faces in stable order without horizontal overflow.
struct ShortcutFlowLayout: Layout {
  var spacing: CGFloat = 8
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(width: proposal.width ?? 680, subviews: subviews).size
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = arrange(width: bounds.width, subviews: subviews)
    for (index, point) in result.points.enumerated() {
      subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
        proposal: ProposedViewSize(width: min(bounds.width, subviews[index].sizeThatFits(.unspecified).width), height: nil))
    }
  }
  private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
    var points: [CGPoint] = []
    var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(ProposedViewSize(width: min(max(0, width), view.sizeThatFits(.unspecified).width), height: nil))
      if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
      points.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return (CGSize(width: max(0, width), height: y + rowHeight), points)
  }
}

enum AniCeSupport {
  static let url = URL(string: "https://anisharyal09.com.np/support?from=anice")!
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
