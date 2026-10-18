// SPDX-License-Identifier: GPL-3.0-or-later
// Offers the native Quick Settings placement prompt only after an explicit setup tap.
package io.github.anisharyal09.anice.features.clipboard

import android.app.StatusBarManager
import android.content.ComponentName
import android.graphics.drawable.Icon
import android.os.Build
import androidx.activity.compose.LocalActivity
import androidx.compose.material3.*
import androidx.compose.runtime.*
import io.github.anisharyal09.anice.R

@Composable
internal fun ClipboardTileSetup() {
    val activity = LocalActivity.current
    var feedback by remember { mutableStateOf<String?>(null) }
    if (Build.VERSION.SDK_INT >= 33 && activity != null) {
        TextButton(onClick = {
            // System placement is consent-driven; opening Clipboard never adds or repeatedly prompts for a tile.
            activity.getSystemService(StatusBarManager::class.java).requestAddTileService(
                ComponentName(activity, ClipboardTileService::class.java), "Send to Mac",
                Icon.createWithResource(activity, R.drawable.ic_clipboard_tile), activity.mainExecutor,
            ) { result ->
                feedback = if (result == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED || result == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED)
                    "Send to Mac is in Quick Settings" else "Open Quick Settings → Edit to add Send to Mac"
            }
        }) { Text("Add Send to Mac tile") }
    } else Text("Open Quick Settings → Edit and add Send to Mac.", style = MaterialTheme.typography.bodySmall)
    feedback?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
}
