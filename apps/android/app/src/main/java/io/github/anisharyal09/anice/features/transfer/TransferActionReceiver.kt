// SPDX-License-Identifier: GPL-3.0-or-later
// Routes user cancellation intents from transfer notifications to the active transfer controller.
package io.github.anisharyal09.anice.features.transfer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.github.anisharyal09.anice.AniCeApplication

class TransferActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_CANCEL) return
        val app = context.applicationContext as? AniCeApplication ?: return
        app.transfer.cancelTransfer()
    }

    companion object {
        const val ACTION_CANCEL = "io.github.anisharyal09.anice.action.CANCEL_TRANSFER"
    }
}
