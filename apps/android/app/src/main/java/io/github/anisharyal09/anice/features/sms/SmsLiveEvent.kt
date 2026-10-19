// SPDX-License-Identifier: GPL-3.0-or-later
// Builds sanitized relay events from Android-decoded message parts.
package io.github.anisharyal09.anice.features.sms

import java.security.MessageDigest

/** One unique incoming SMS after multipart combination and NUL sanitization. */
data class SmsLiveEvent(val address: String, val dateMillis: Long, val body: String) {
    val normalizedAddress: String get() = smsNormalizedAddress(address)
    // The canonical conversation key keeps alphanumeric sender IDs as their own thread.
    val threadId: String get() = "addr:" + normalizedAddress.ifEmpty { address }
    val messageId: String get() = smsLiveMessageId(address, dateMillis, body)
}

/** Deterministic live ID so duplicate SMS_RECEIVED deliveries collapse under the same messageId. */
fun smsLiveMessageId(address: String, dateMillis: Long, body: String): String =
    "live:" + MessageDigest.getInstance("SHA-256").digest((address + dateMillis.toString() + body).toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }.take(32)

/** Parts arrive in the framework's message order; incompatible metadata rejects the whole batch. */
data class SmsReceivedPart(val address: String?, val dateMillis: Long, val body: String?, val subscriptionId: Int = -1)

fun smsReceivedEvent(parts: List<SmsReceivedPart>): SmsLiveEvent? {
    val first = parts.firstOrNull() ?: return null
    val address = first.address?.let(::smsSanitizeText) ?: return null
    if (address.toByteArray(Charsets.UTF_8).size !in 1..64 || smsNormalizedAddress(address).isEmpty()) return null
    if (first.dateMillis !in 1..SmsWireMessage.MAX_DATE) return null
    if (parts.any { it.address != first.address || it.subscriptionId != first.subscriptionId || it.body == null || it.dateMillis !in 1..SmsWireMessage.MAX_DATE }) return null
    val body = smsSanitizeText(parts.joinToString("") { it.body!! }) ?: return null
    if (body.toByteArray(Charsets.UTF_8).size !in 1..SmsWireMessage.MAX_BODY_BYTES.toInt()) return null
    return SmsLiveEvent(address, first.dateMillis, body)
}
