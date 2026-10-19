// SPDX-License-Identifier: GPL-3.0-or-later
// Hands SMS_RECEIVED messages to the application relay within the broadcast completion bound.
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
        val pending = goAsync()
        val handler = android.os.Handler(android.os.Looper.getMainLooper())
        val finished = java.util.concurrent.atomic.AtomicBoolean(false)
        val finish = Runnable { if (finished.compareAndSet(false, true)) pending.finish() }
        handler.postDelayed(finish, 8_000)
        try {
            val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent).orEmpty()
            val subscription = intent.getIntExtra(android.telephony.SubscriptionManager.EXTRA_SUBSCRIPTION_INDEX, -1)
            val parts = messages.map { message ->
                SmsReceivedPart(message?.originatingAddress, message?.timestampMillis ?: 0, message?.messageBody, subscription)
            }
            val events = listOfNotNull(smsReceivedEvent(parts))
            SmsTrace.log("incoming: ${parts.size} part(s), ${events.size} event(s)${if (events.isEmpty()) " rejected-metadata" else ""}")
            application.sms.submitLive(events) { handler.removeCallbacks(finish); finish.run() }
        } catch (_: Exception) {
            SmsTrace.log("incoming: native-decode-failed")
            handler.removeCallbacks(finish)
            finish.run()
        }
    }
}
