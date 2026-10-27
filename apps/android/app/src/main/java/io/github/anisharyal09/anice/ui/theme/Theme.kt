// SPDX-License-Identifier: GPL-3.0-or-later
// Maps the shared aniCe palette and native shape roles into Android presentation.
package io.github.anisharyal09.anice.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Shapes
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material3.Typography
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import android.content.Context
import androidx.compose.ui.graphics.Color

// Static semantic roles preserve the project palette rather than inheriting Material defaults.
private val LightColors =
    lightColorScheme(
        primary = Color(0xFF47534D),
        onPrimary = Color(0xFFFFFDF9),
        primaryContainer = Color(0xFFE5E8E2),
        onPrimaryContainer = Color(0xFF282E2A),
        secondary = Color(0xFF47534D),
        onSecondary = Color(0xFFFFFDF9),
        secondaryContainer = Color(0xFFE5E8E2),
        onSecondaryContainer = Color(0xFF282E2A),
        tertiary = Color(0xFF466A50),
        onTertiary = Color.White,
        background = Color(0xFFF4F3EF),
        onBackground = Color(0xFF282E2A),
        surface = Color(0xFFFFFDF9),
        onSurface = Color(0xFF282E2A),
        surfaceVariant = Color(0xFFEAEAE4),
        onSurfaceVariant = Color(0xFF626B65),
        outline = Color(0xFFDCDED8),
        outlineVariant = Color(0xFFDCDED8),
        error = Color(0xFFA13D38),
        onError = Color.White,
        errorContainer = Color(0xFFEAEAE4),
        onErrorContainer = Color(0xFFA13D38),
        tertiaryContainer = Color(0xFFEAEAE4),
        onTertiaryContainer = Color(0xFF466A50),
        inverseSurface = Color(0xFF242828),
        inverseOnSurface = Color(0xFFEBEEEB),
        inversePrimary = Color(0xFFC4CCC5),
        surfaceContainer = Color(0xFFFFFDF9),
        surfaceContainerLow = Color(0xFFFFFDF9),
        surfaceContainerHigh = Color(0xFFEAEAE4),
        surfaceContainerHighest = Color(0xFFEAEAE4),
        surfaceContainerLowest = Color(0xFFFFFDF9),
        surfaceBright = Color(0xFFFFFDF9),
        surfaceDim = Color(0xFFEAEAE4),
        surfaceTint = Color(0xFF47534D),
    )
private val DarkColors =
    darkColorScheme(
        primary = Color(0xFFC4CCC5),
        onPrimary = Color(0xFF222A25),
        primaryContainer = Color(0xFF303632),
        onPrimaryContainer = Color(0xFFEBEEEB),
        secondary = Color(0xFFC4CCC5),
        onSecondary = Color(0xFF222A25),
        secondaryContainer = Color(0xFF303632),
        onSecondaryContainer = Color(0xFFEBEEEB),
        tertiary = Color(0xFFA1C6A9),
        onTertiary = Color(0xFF1B1E1E),
        background = Color(0xFF1B1E1E),
        onBackground = Color(0xFFEBEEEB),
        surface = Color(0xFF242828),
        onSurface = Color(0xFFEBEEEB),
        surfaceVariant = Color(0xFF222626),
        onSurfaceVariant = Color(0xFFADB5AF),
        outline = Color(0xFF3B4140),
        outlineVariant = Color(0xFF3B4140),
        error = Color(0xFFE8AAA4),
        onError = Color(0xFF1B1E1E),
        errorContainer = Color(0xFF222626),
        onErrorContainer = Color(0xFFE8AAA4),
        tertiaryContainer = Color(0xFF222626),
        onTertiaryContainer = Color(0xFFA1C6A9),
        inverseSurface = Color(0xFFFFFDF9),
        inverseOnSurface = Color(0xFF282E2A),
        inversePrimary = Color(0xFF47534D),
        surfaceContainer = Color(0xFF242828),
        surfaceContainerLow = Color(0xFF242828),
        surfaceContainerHigh = Color(0xFF222626),
        surfaceContainerHighest = Color(0xFF222626),
        surfaceContainerLowest = Color(0xFF1B1E1E),
        surfaceBright = Color(0xFF242828),
        surfaceDim = Color(0xFF1B1E1E),
        surfaceTint = Color(0xFFC4CCC5),
    )

enum class Appearance { System, Light, Dark;
    companion object {
        fun stored(value: String?): Appearance = entries.firstOrNull { it.name == value } ?: System
    }
}

@Composable
fun appearancePreference(): Appearance {
    val context = LocalContext.current
    val preferences = remember(context) { context.applicationContext.getSharedPreferences("appearance", Context.MODE_PRIVATE) }
    var appearance by remember { mutableStateOf(Appearance.stored(preferences.getString("mode", null))) }
    DisposableEffect(preferences) {
        val listener = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == "mode") appearance = Appearance.stored(preferences.getString("mode", null))
        }
        preferences.registerOnSharedPreferenceChangeListener(listener)
        onDispose { preferences.unregisterOnSharedPreferenceChangeListener(listener) }
    }
    return appearance
}

fun saveAppearance(context: Context, appearance: Appearance) {
    context.applicationContext.getSharedPreferences("appearance", Context.MODE_PRIVATE)
        .edit().putString("mode", appearance.name).apply()
}

@Composable
fun AniCeTheme(content: @Composable () -> Unit) {
    val dark = when (appearancePreference()) {
        Appearance.System -> isSystemInDarkTheme()
        Appearance.Light -> false
        Appearance.Dark -> true
    }
    val palette = if (dark) DarkColors else LightColors
    MaterialTheme(
        colorScheme = palette,
        typography = Typography().let { type -> type.copy(
            titleLarge = type.titleLarge.copy(fontSize = 20.sp, lineHeight = 26.sp),
            titleMedium = type.titleMedium.copy(fontSize = 16.sp, lineHeight = 22.sp),
            titleSmall = type.titleSmall.copy(fontSize = 14.sp, lineHeight = 20.sp),
            bodyLarge = type.bodyLarge.copy(fontSize = 14.sp, lineHeight = 20.sp),
            bodyMedium = type.bodyMedium.copy(fontSize = 13.sp, lineHeight = 19.sp),
            bodySmall = type.bodySmall.copy(fontSize = 12.sp, lineHeight = 17.sp)
        ) },
        shapes = Shapes(
            extraSmall = RoundedCornerShape(6.dp),
            small = RoundedCornerShape(8.dp),
            medium = RoundedCornerShape(10.dp),
            large = RoundedCornerShape(12.dp),
            extraLarge = RoundedCornerShape(14.dp),
        ),
        content = content,
    )
}

/** Semantic roles defined in docs/design/DESIGN.md. */
val ColorScheme.warning: Color
    @Composable
    get() = if (surface == DarkColors.surface) Color(0xFFDCB27C) else Color(0xFF825523)

val ColorScheme.subtleAccent: Color
    get() = primaryContainer


/** Selection retains the shared accent while ordinary controls use neutral ink. */
val ColorScheme.selectionAccent: Color
    @Composable
    get() = if (surface == DarkColors.surface) DarkColors.primary else LightColors.primary
