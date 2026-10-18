// SPDX-License-Identifier: GPL-3.0-or-later
// Checks the manifest SMS surface: guarded receiver, internal status receiver and declared permissions.
package io.github.anisharyal09.anice.features.sms

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Telephony
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SmsSurfaceTests {
    @Test fun receivedBroadcastRequiresSystemPermissionAndStatusReceiverStaysInternal() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val receiver = ComponentName(context, SmsReceiver::class.java)
        val info = context.packageManager.getReceiverInfo(receiver, 0)
        assertTrue(info.exported)
        assertEquals(Manifest.permission.BROADCAST_SMS, info.permission)
        val handlers = context.packageManager.queryBroadcastReceivers(
            Intent(Telephony.Sms.Intents.SMS_RECEIVED_ACTION).setPackage(context.packageName), 0)
        assertEquals(listOf(receiver.className), handlers.map { it.activityInfo.name })
        val status = context.packageManager.getReceiverInfo(ComponentName(context, SmsStatusReceiver::class.java), 0)
        assertFalse(status.exported)
    }

    @Test fun smsPermissionsAreDeclared() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val declared = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
            .requestedPermissions?.toSet().orEmpty()
        assertTrue(declared.containsAll(listOf(Manifest.permission.RECEIVE_SMS, Manifest.permission.READ_SMS, Manifest.permission.SEND_SMS)))
    }
}
