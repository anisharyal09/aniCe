// SPDX-License-Identifier: GPL-3.0-or-later
// Opens explicit clipboard sharing from Quick Settings without reading clipboard content in a service.
package io.github.anisharyal09.anice.features.clipboard

import android.app.PendingIntent
import android.annotation.SuppressLint
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import io.github.anisharyal09.anice.R

class ClipboardTileService : TileService() {
    override fun onTileAdded() { super.onTileAdded(); showAction() }
    override fun onStartListening() {
        super.onStartListening()
        showAction()
    }
    private fun showAction() {
        // This is an action, not a connection or sharing-mode toggle; it stays tappable while disconnected.
        qsTile?.apply {
            // Refresh the resource for existing placements as well as newly added tiles.
            icon = Icon.createWithResource(this@ClipboardTileService, R.drawable.ic_clipboard_tile)
            state = Tile.STATE_INACTIVE; updateTile()
        }
    }
    override fun onClick() {
        super.onClick()
        if (isLocked) unlockAndRun { openSheet() } else openSheet()
    }
    @Suppress("DEPRECATION") // The PendingIntent overload was introduced in API 34.
    @SuppressLint("StartActivityAndCollapseDeprecated") // The Intent overload is used only on API 29–33.
    private fun openSheet() {
        val intent = SendToMacActivity.clipboardIntent(this)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        } else startActivityAndCollapse(intent)
    }
}
