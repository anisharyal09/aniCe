// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies the compact switch keeps muted, distinguishable states in both app themes.
package io.github.anisharyal09.anice.ui

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import io.github.anisharyal09.anice.ui.theme.controlTrack
import org.junit.Assert.*
import org.junit.Test

class CapsuleSwitchColorsTest {
    @Test fun thumbsRemainNonWhiteAndMeetControlContrastInBothStates() {
        for (dark in listOf(false, true)) {
            for (checked in listOf(false, true)) {
                val colors = capsuleSwitchColors(scheme(dark), checked)
                assertNotEquals(Color.White, colors.thumb)
                assertEquals(1f, colors.thumb.alpha)
                assertEquals(1f, colors.track.alpha)
                val brighter = maxOf(colors.thumb.luminance(), colors.track.luminance())
                val darker = minOf(colors.thumb.luminance(), colors.track.luminance())
                assertTrue("Thumb/track contrast must reach 3:1", (brighter + 0.05f) / (darker + 0.05f) >= 3f)
            }
        }
    }

    @Test fun onUsesAFilledTrackWithoutThePreviousHeavyOutline() {
        for (dark in listOf(false, true)) {
            val palette = scheme(dark)
            val on = capsuleSwitchColors(palette, true)
            val off = capsuleSwitchColors(palette, false)
            assertNotEquals(on.track, off.track)
            assertNotEquals(palette.primaryContainer, on.track)
            assertEquals(0f, on.border.alpha)
            assertEquals(0.35f, off.border.alpha, 1f / 255)
            assertEquals(palette.onSurfaceVariant, off.thumb)
            if (dark) assertEquals(palette.primary, on.thumb)
            else assertEquals(palette.background, on.thumb)
        }
    }

    @Test fun offTrackUsesTheSharedControlTokenRatherThanSeparatorInk() {
        assertEquals(Color(0xFFE0E3DC), scheme(false).controlTrack)
        assertEquals(Color(0xFF3B413E), scheme(true).controlTrack)
        for (dark in listOf(false, true)) {
            val palette = scheme(dark)
            assertEquals(palette.controlTrack, capsuleSwitchColors(palette, false).track)
            assertNotEquals(palette.outlineVariant, capsuleSwitchColors(palette, false).track)
        }
    }

    private fun scheme(dark: Boolean): ColorScheme = if (dark) darkColorScheme(
        primary = Color(0xFFC4CCC5), primaryContainer = Color(0xFF303632),
        surface = Color(0xFF242828), onSurfaceVariant = Color(0xFFADB5AF), outlineVariant = Color(0xFF3B4140),
    ) else lightColorScheme(
        primary = Color(0xFF47534D), primaryContainer = Color(0xFFE5E8E2),
        surface = Color(0xFFFFFDF9), onSurfaceVariant = Color(0xFF626B65), outlineVariant = Color(0xFFDCDED8),
    )
}
