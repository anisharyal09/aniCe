// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val LightColors = lightColorScheme(
    primary = Color(0xFF355B70), onPrimary = Color.White,
    primaryContainer = Color(0xFFDDE8ED), onPrimaryContainer = Color(0xFF262F35),
    secondary = Color(0xFF355B70), onSecondary = Color.White,
    secondaryContainer = Color(0xFFDDE8ED), onSecondaryContainer = Color(0xFF262F35),
    tertiary = Color(0xFF466A50), onTertiary = Color.White,
    background = Color(0xFFF4F3EF), onBackground = Color(0xFF262F35),
    surface = Color(0xFFFFFDF9), onSurface = Color(0xFF262F35),
    surfaceVariant = Color(0xFFEAEAE4), onSurfaceVariant = Color(0xFF626E76),
    outline = Color(0xFFDCE0DF), outlineVariant = Color(0xFFDCE0DF),
    error = Color(0xFFA13D38), onError = Color.White,
    surfaceContainer = Color(0xFFFFFDF9), surfaceContainerLow = Color(0xFFFFFDF9),
    surfaceContainerHigh = Color(0xFFEAEAE4), surfaceContainerHighest = Color(0xFFEAEAE4),
    surfaceContainerLowest = Color(0xFFFFFDF9), surfaceBright = Color(0xFFFFFDF9),
    surfaceDim = Color(0xFFEAEAE4), surfaceTint = Color(0xFF355B70),
)
private val DarkColors = darkColorScheme(
    primary = Color(0xFFA7C5D6), onPrimary = Color(0xFF152D3B),
    primaryContainer = Color(0xFF30434E), onPrimaryContainer = Color(0xFFEDF0F1),
    secondary = Color(0xFFA7C5D6), onSecondary = Color(0xFF152D3B),
    secondaryContainer = Color(0xFF30434E), onSecondaryContainer = Color(0xFFEDF0F1),
    tertiary = Color(0xFFA1C6A9), onTertiary = Color(0xFF191E22),
    background = Color(0xFF191E22), onBackground = Color(0xFFEDF0F1),
    surface = Color(0xFF242B31), onSurface = Color(0xFFEDF0F1),
    surfaceVariant = Color(0xFF20272D), onSurfaceVariant = Color(0xFFADB8BF),
    outline = Color(0xFF3C4850), outlineVariant = Color(0xFF3C4850),
    error = Color(0xFFE8AAA4), onError = Color(0xFF191E22),
    surfaceContainer = Color(0xFF242B31), surfaceContainerLow = Color(0xFF242B31),
    surfaceContainerHigh = Color(0xFF20272D), surfaceContainerHighest = Color(0xFF20272D),
    surfaceContainerLowest = Color(0xFF191E22), surfaceBright = Color(0xFF242B31),
    surfaceDim = Color(0xFF191E22), surfaceTint = Color(0xFFA7C5D6),
)

@Composable
fun AniCeTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) DarkColors else LightColors, content = content)
}
