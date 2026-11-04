// SPDX-License-Identifier: GPL-3.0-or-later
// Routes transfer cancellation only to the operation that created the notification action.
package io.github.anisharyal09.anice.features.transfer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.github.anisharyal09.anice.AniCeApplication

class TransferActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext as? AniCeApplication ?: return
        when (intent.action) {
            ACTION_CANCEL -> {
                val operationId = intent.getStringExtra(EXTRA_OPERATION_ID) ?: return
                val interruptedOfferId = (app.transfer.interruptedOffer as? TransferState.IncomingOffer)
                    ?.batch?.id?.let { runCatching { java.util.UUID.fromString(it).toString() }.getOrNull() }
                val activeOperationMatches = app.transfer.isBusy && operationId == app.transfer.operationID.toString()
                if (activeOperationMatches || operationId == interruptedOfferId) {
                    app.transfer.cancelTransfer()
                }
            }
            ACTION_RESUME_BLE -> app.transfer.resumeOverBluetooth()
        }
    }

    companion object {
        const val ACTION_CANCEL = "io.github.anisharyal09.anice.action.CANCEL_TRANSFER"
        const val ACTION_RESUME_BLE = "io.github.anisharyal09.anice.action.RESUME_TRANSFER_OVER_BLUETOOTH"
        const val EXTRA_OPERATION_ID = "io.github.anisharyal09.anice.extra.TRANSFER_OPERATION_ID"
    }
}
