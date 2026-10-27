// SPDX-License-Identifier: GPL-3.0-or-later
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
