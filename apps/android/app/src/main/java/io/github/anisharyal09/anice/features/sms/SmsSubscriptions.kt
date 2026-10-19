// SPDX-License-Identifier: GPL-3.0-or-later
// Lists the phone's active SMS subscriptions for the optional per-reply SIM choice.
package io.github.anisharyal09.anice.features.sms

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SubscriptionInfo
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat

/** One active SMS subscription; the label is the user-visible SIM name truncated to 40 UTF-8 bytes. */
data class SmsSubscription(val subscriptionId: Int, val slotIndex: Int, val label: String, val isDefault: Boolean)

/** [result] is a relay result code: 0 with entries, 1 when READ_PHONE_STATE is missing, 5 on failure. */
data class SmsSubscriptionListing(val result: Long, val entries: List<SmsSubscription>)

interface SmsSubscriptionSource {
    fun list(): SmsSubscriptionListing

    /** Active modems need no permission; the panel offers a choice only when a multi-SIM phone can serve one. */
    fun modemCount(): Int
}

class AndroidSmsSubscriptionSource(
    private val context: Context,
    private val hasPhoneStatePermission: () -> Boolean = { ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED },
) : SmsSubscriptionSource {
    override fun list(): SmsSubscriptionListing {
        // The platform can answer a permission-less read with an empty list instead of throwing, so ask first and be unambiguous.
        if (!hasPhoneStatePermission()) return SmsSubscriptionListing(1, emptyList())
        return try {
            val manager = context.getSystemService(SubscriptionManager::class.java)
            if (manager == null) SmsSubscriptionListing(5, emptyList()) else {
                val defaultId = try { SubscriptionManager.getDefaultSmsSubscriptionId() } catch (_: Exception) { SubscriptionManager.INVALID_SUBSCRIPTION_ID }
                val entries = manager.activeSubscriptionInfoList.orEmpty().mapNotNull { info -> subscription(info, defaultId) }.take(8)
                SmsSubscriptionListing(0, entries)
            }
        } catch (_: SecurityException) {
            SmsSubscriptionListing(1, emptyList())
        } catch (_: Exception) {
            SmsSubscriptionListing(5, emptyList())
        }
    }

    private fun subscription(info: SubscriptionInfo, defaultId: Int): SmsSubscription? {
        if (info.subscriptionId < 0) return null
        val name = listOf(info.displayName, info.carrierName).firstNotNullOfOrNull { it?.toString()?.trim()?.takeIf { value -> value.isNotEmpty() } }
        return SmsSubscription(
            subscriptionId = info.subscriptionId,
            slotIndex = info.simSlotIndex.coerceIn(0, 15),
            label = smsTruncate(name ?: "SIM ${info.simSlotIndex + 1}", 40),
            isDefault = info.subscriptionId == defaultId,
        )
    }

    override fun modemCount(): Int = try {
        val manager = context.getSystemService(TelephonyManager::class.java) ?: return 0
        if (Build.VERSION.SDK_INT >= 30) manager.activeModemCount else @Suppress("DEPRECATION") manager.phoneCount
    } catch (_: Exception) {
        0
    }
}
