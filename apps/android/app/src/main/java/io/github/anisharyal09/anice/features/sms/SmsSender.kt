// SPDX-License-Identifier: GPL-3.0-or-later
// Delivers replies through the platform SmsManager and reports per-part sentIntent results.
package io.github.anisharyal09.anice.features.sms

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.telephony.SmsManager
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ConcurrentHashMap
import java.util.UUID

private class SmsPartFailed : Exception()

class SmsSendOutcome(val result: Long, val messageId: String, val dateMillis: Long)

interface SmsSender {
    suspend fun send(address: String, body: String, timeoutMillis: Long = 30_000): SmsSendOutcome
}

class AndroidSmsSender(
    private val context: Context,
    private val hasSendPermission: () -> Boolean = { ContextCompat.checkSelfPermission(context, Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED },
    private val hasReadPermission: () -> Boolean = { ContextCompat.checkSelfPermission(context, Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED },
    private val clock: () -> Long = System::currentTimeMillis,
) : SmsSender {
    private val smsManager: SmsManager? get() = context.getSystemService(SmsManager::class.java)

    override suspend fun send(address: String, body: String, timeoutMillis: Long): SmsSendOutcome {
        if (address.isEmpty() || address.toByteArray(Charsets.UTF_8).size > 64) return SmsSendOutcome(6, "", 0)
        val clean = smsSanitizeText(body) ?: return SmsSendOutcome(6, "", 0)
        val bytes = clean.toByteArray(Charsets.UTF_8)
        if (bytes.isEmpty() || bytes.size > SmsWireMessage.MAX_BODY_BYTES) return SmsSendOutcome(6, "", 0)
        if (!hasSendPermission()) return SmsSendOutcome(1, "", 0)
        val manager = smsManager ?: return SmsSendOutcome(5, "", 0)
        val parts: List<String> = try {
            manager.divideMessage(clean)
        } catch (_: Exception) {
            return SmsSendOutcome(5, "", 0)
        }
        if (parts.isEmpty()) return SmsSendOutcome(6, "", 0)
        // One distinct PendingIntent per part; the broadcast receiver completes the matching waiter.
        val codes = parts.indices.map { UUID.randomUUID().toString() }
        val waiters = codes.map { it to CompletableDeferred<Int>() }
        waiters.forEach { (code, waiter) -> pending[code] = waiter }
        val sentIntents: List<PendingIntent> = try { codes.map { code ->
            PendingIntent.getBroadcast(
                context,
                0,
                Intent(context, SmsStatusReceiver::class.java)
                    .setData(android.net.Uri.fromParts("anice-sms-sent", code, null))
                    .putExtra(SmsStatusReceiver.EXTRA_CODE, code),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        } } catch (_: Exception) {
            waiters.forEach { (code, _) -> pending.remove(code) }
            return SmsSendOutcome(5, "", 0)
        }
        val startedAt = clock()
        val subscription = try { manager.subscriptionId } catch (_: Exception) { -1 }
        val queued = try {
            // The public five-argument overload is ArrayList-based on every API level; the API 30
            // List overloads carry system-only package/attribution arguments.
            @Suppress("DEPRECATION")
            manager.sendMultipartTextMessage(address, null, ArrayList(parts), ArrayList(sentIntents), null)
            true
        } catch (_: SecurityException) {
            false
        } catch (_: IllegalArgumentException) {
            false
        } catch (_: Exception) {
            false
        }
        if (!queued) {
            waiters.forEach { (code, _) -> pending.remove(code) }
            return SmsSendOutcome(if (!hasSendPermission()) 1 else 5, "", 0)
        }
        // sendMultipartTextMessage only queues IPC: wait for every part's radio verdict under one deadline.
        val reported = try {
            withTimeoutOrNull(timeoutMillis) {
                coroutineScope {
                    waiters.map { (_, waiter) -> async {
                        waiter.await().also { if (it != Activity.RESULT_OK) throw SmsPartFailed() }
                    } }.awaitAll()
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        } finally {
            waiters.forEach { (code, _) -> pending.remove(code) }
        }
        if (reported == null || reported.any { it != Activity.RESULT_OK }) return SmsSendOutcome(5, "", 0)
        val found = withContext(Dispatchers.IO) { lookupSent(address, clean, startedAt, subscription) }
        return if (found != null) SmsSendOutcome(0, found.first, found.second) else SmsSendOutcome(0, "", clock())
    }

    /** At most one best-effort provider lookup for the sent row; absent rows keep an empty provider ID. */
    private fun lookupSent(address: String, body: String, startedAt: Long, subscription: Int): Pair<String, Long>? {
        if (!hasReadPermission()) return null
        return try {
            val cursor = context.contentResolver.query(
                android.provider.Telephony.Sms.CONTENT_URI,
                arrayOf("_id", "date"),
                "address = ? AND body = ? AND type = 2 AND date >= ? AND sub_id = ?",
                arrayOf(address, body, startedAt.toString(), subscription.toString()),
                "date DESC LIMIT 1",
            ) ?: return null
            cursor.use { if (it.moveToFirst()) "sms:${it.getLong(0)}" to it.getLong(1) else null }
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        private val pending = ConcurrentHashMap<String, CompletableDeferred<Int>>()

        /** Called by [SmsStatusReceiver]; unknown or expired codes are ignored. */
        fun report(code: String?, result: Int) {
            if (code != null) pending.remove(code)?.complete(result)
        }
    }
}
