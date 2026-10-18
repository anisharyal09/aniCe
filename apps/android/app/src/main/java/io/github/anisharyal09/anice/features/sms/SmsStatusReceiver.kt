// SPDX-License-Identifier: GPL-3.0-or-later
// Routes per-part sentIntent verdicts back to the active AndroidSmsSender send.
package io.github.anisharyal09.anice.features.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class SmsStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        AndroidSmsSender.report(intent.getIntExtra(EXTRA_CODE, -1), resultCode)
    }

    companion object {
        const val EXTRA_CODE = "io.github.anisharyal09.anice.sms.code"
    }
}
