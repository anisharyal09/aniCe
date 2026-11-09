// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies CallStyle answer and decline actions map to their exact PendingIntents.
package io.github.anisharyal09.anice.features.notifications

import android.app.Notification
import android.app.PendingIntent
import android.app.Person
import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.MainActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 31)
class NotificationCallStyleTest {
    @Test fun incomingCallActionsUseAnswerAndDeclinePendingIntentsInStableOrder() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val answer = PendingIntent.getActivity(
            context, 401, Intent(context, MainActivity::class.java).setAction("call-answer-test"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val decline = PendingIntent.getActivity(
            context, 402, Intent(context, MainActivity::class.java).setAction("call-decline-test"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(context, "notification-mirror-call-test")
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setStyle(Notification.CallStyle.forIncomingCall(
                Person.Builder().setName("Test caller").build(), decline, answer,
            ))
            .build()

        val extras = notification.extras
        assertTrue(isIncomingCallStyle(
            extras.getString(Notification.EXTRA_TEMPLATE), extras.getInt("android.callType"),
        ))
        val (targets, actions) = notificationActions(notification, incomingCall = true)
        assertEquals(2, actions.size)
        assertEquals(listOf(0L, 1L), actions.map { it.index })
        assertEquals(answer, targets[0]?.pendingIntent)
        assertEquals(decline, targets[1]?.pendingIntent)
        val answerLabel = notification.actions.first { it.actionIntent == answer }.title.toString()
        val declineLabel = notification.actions.first { it.actionIntent == decline }.title.toString()
        assertEquals(answerLabel, actions[0].title)
        assertEquals(declineLabel, actions[1].title)
    }
}
