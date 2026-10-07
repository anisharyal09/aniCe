// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum AniCePalette {
    static func background(_ scheme: ColorScheme) -> Color {
        color(light: 0xF4F3EF, dark: 0x191E22, scheme: scheme)
    }
    static func surface(_ scheme: ColorScheme) -> Color {
        color(light: 0xFFFDF9, dark: 0x242B31, scheme: scheme)
    }
    static func accent(_ scheme: ColorScheme) -> Color {
        color(light: 0x355B70, dark: 0xA7C5D6, scheme: scheme)
    }
    static func onAccent(_ scheme: ColorScheme) -> Color {
        color(light: 0xFFFFFF, dark: 0x152D3B, scheme: scheme)
    }
    static func primaryText(_ scheme: ColorScheme) -> Color {
        color(light: 0x262F35, dark: 0xEDF0F1, scheme: scheme)
    }
    static func secondaryText(_ scheme: ColorScheme) -> Color {
        color(light: 0x626E76, dark: 0xADB8BF, scheme: scheme)
    }
    static func secondarySurface(_ scheme: ColorScheme) -> Color {
        color(light: 0xEAEAE4, dark: 0x20272D, scheme: scheme)
    }
    static func separator(_ scheme: ColorScheme) -> Color {
        color(light: 0xDCE0DF, dark: 0x3C4850, scheme: scheme)
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
