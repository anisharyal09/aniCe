// SPDX-License-Identifier: GPL-3.0-or-later
// Hands SMS_RECEIVED PDUs to the application relay within the broadcast completion bound.
package io.github.anisharyal09.anice.features.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import io.github.anisharyal09.anice.AniCeApplication

class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val application = context.applicationContext as? AniCeApplication ?: return
        val event = intent.extras?.get("pdus")
        val pdus = (event as? Array<*>)?.filterIsInstance<ByteArray>() ?: emptyList()
        if (pdus.isEmpty()) return
        val pending = goAsync()
        // The relay computes deterministic live IDs, parks queued events and retries once per transport.
        val events = SmsPduParser.parse(intent.getStringExtra("format"), pdus)
        SmsTrace.log("incoming: ${pdus.size} pdu(s), ${events.size} event(s)")
        application.sms.submitLive(events) { pending.finish() }
    }
}
