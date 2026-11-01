// SPDX-License-Identifier: GPL-3.0-or-later
// Serves remote thread, history, SIM and search requests for the SMS relay.
package io.github.anisharyal09.anice.features.sms

import kotlinx.coroutines.*
import io.github.anisharyal09.anice.infrastructure.session.*
import java.security.MessageDigest
import java.util.UUID

internal fun SmsController.serveThreads(link: SmsController.Link, requestId: String, beforeMillis: Long, beforeThreadId: String) {
    val k = key(link.channel.descriptor.peer)
    val current = servingThreads[k]
    if (current?.requestId == requestId && current.job?.isActive == true) return
    current?.job?.cancel()
    val job = scope.launch {
        val self = coroutineContext[Job]
        try {
            val deadline = deadline(link)
            var failed = false
            val page = try { store.threads(link.remoteThreads, beforeMillis, beforeThreadId) }
                catch (e: CancellationException) { throw e }
                catch (_: SmsPagingUnsupported) {
                    send(link, SmsWireMessage.of(4, text(requestId), number(4), number(0), text("")), deadline)
                    return@launch
                }
                catch (_: Exception) { failed = true; null }
            if (page == null) { send(link, SmsWireMessage.of(4, text(requestId), number(if (failed) 5 else 1), number(0), text("")), deadline); return@launch }
            if (page.partial) { send(link, SmsWireMessage.of(4, text(requestId), number(5), number(0), text("")), deadline); return@launch }
            recordSkippedRows(page.skipped)
            for (record in page.threads) {
                val sent = send(link, SmsWireMessage.of(3, text(requestId), text(record.threadId), text(record.address), text(record.snippet), number(record.dateMillis), number(record.unreadCount)), deadline)
                if (!sent) return@launch
            }
            send(link, SmsWireMessage.of(4, text(requestId), number(0), number(page.nextBeforeMillis), text(page.nextBeforeThreadId)), deadline)
        } finally {
            cancelQueued(link, requestId)
            if (servingThreads[k]?.job == self) servingThreads.remove(k)
        }
    }
    servingThreads[k] = SmsController.Serving(requestId, link.channel.descriptor, job)
}

internal fun SmsController.serveHistory(link: SmsController.Link, requestId: String, threadId: String, beforeMillis: Long, beforeMessageId: String, limit: Int) {
    val k = key(link.channel.descriptor.peer)
    val current = servingHistory[k]
    if (current?.requestId == requestId && current.job?.isActive == true) return
    current?.job?.cancel()
    val job = scope.launch {
        val self = coroutineContext[Job]
        try {
            val deadline = deadline(link)
            suspend fun sendPage(message: SmsWireMessage, end: Long) = send(link, message, end, requestId)
            var failed = false
            val page = try { store.history(threadId, beforeMillis, beforeMessageId, minOf(limit, link.remoteMessages)) } catch (e: CancellationException) { throw e } catch (_: SmsPagingUnsupported) { sendPage(SmsWireMessage.of(10, text(requestId), number(4), number(0), text("")), deadline); return@launch } catch (_: Exception) { failed = true; null }
            if (page == null) { sendPage(SmsWireMessage.of(10, text(requestId), number(if (failed) 5 else 1), number(0), text("")), deadline); return@launch }
            if (page.partial) { sendPage(SmsWireMessage.of(10, text(requestId), number(5), number(0), text("")), deadline); return@launch }
            recordSkippedRows(page.skipped)
            for (message in page.messages) {
                val data = message.text.toByteArray(Charsets.UTF_8)
                val digest = MessageDigest.getInstance("SHA-256").digest(data)
                val count = (data.size + 3071) / 3072
                val streamId = UUID.randomUUID().toString()
                if (!sendPage(SmsWireMessage.of(6, text(streamId), text(requestId), text(message.messageId), text(threadId), text(message.address), number(message.dateMillis), number(message.direction), flag(message.unread), number(data.size.toLong()), number(count.toLong()), data(digest), number(message.subscriptionId.toLong())), deadline)) return@launch
                for (index in 0 until count) {
                    val from = index * 3072
                    if (!sendPage(SmsWireMessage.of(7, text(streamId), number(index.toLong()), data(data.copyOfRange(from, minOf(from + 3072, data.size)))), deadline)) return@launch
                }
                if (!sendPage(SmsWireMessage.of(8, text(streamId)), deadline)) return@launch
            }
            sendPage(SmsWireMessage.of(10, text(requestId), number(0), number(page.nextBeforeMillis), text(page.nextBeforeMessageId)), deadline)
        } finally {
            cancelQueued(link, requestId)
            if (servingHistory[k]?.job == self) servingHistory.remove(k)
        }
    }
    servingHistory[k] = SmsController.Serving(requestId, link.channel.descriptor, job)
}

/** One platform read answered with exactly one simDone; nothing is persisted and nothing is retried. */
internal fun SmsController.serveSim(link: SmsController.Link, requestId: String) {
    val listing = try { subscriptions?.list() ?: SmsSubscriptionListing(5, emptyList()) } catch (_: Exception) { SmsSubscriptionListing(5, emptyList()) }
    val entries = Cbor.Array(listing.entries.map { entry ->
        Cbor.Array(listOf(number(entry.subscriptionId.toLong()), number(entry.slotIndex.toLong()), text(entry.label), flag(entry.isDefault)))
    })
    enqueue(link, SmsWireMessage.of(16, text(requestId), number(listing.result), entries))
}

/** A search page streams hits as regular message records under the search requestId; a newer request cancels this one. */
internal fun SmsController.serveSearch(link: SmsController.Link, requestId: String, query: String, beforeMillis: Long, beforeMessageId: String, limit: Int) {
    val k = key(link.channel.descriptor.peer)
    val current = servingSearch[k]
    if (current?.requestId == requestId && current.job?.isActive == true) return
    current?.job?.cancel()
    val job = scope.launch {
        val self = coroutineContext[Job]
        try {
            val deadline = deadline(link)
            suspend fun sendPage(message: SmsWireMessage) = send(link, message, deadline, requestId)
            val clean = query.trim()
            if (clean.toByteArray(Charsets.UTF_8).size < 2) { sendPage(SmsWireMessage.of(18, text(requestId), number(6L), number(0), text(""))); return@launch }
            var failed = false
            val page = try { store.search(clean, beforeMillis, beforeMessageId, minOf(limit, link.remoteMessages)) } catch (e: CancellationException) { throw e } catch (_: SmsPagingUnsupported) { sendPage(SmsWireMessage.of(18, text(requestId), number(4L), number(0), text(""))); return@launch } catch (_: Exception) { failed = true; null }
            if (page == null) { sendPage(SmsWireMessage.of(18, text(requestId), number(if (failed) 5L else 1L), number(0), text(""))); return@launch }
            if (page.partial) { sendPage(SmsWireMessage.of(18, text(requestId), number(5L), number(0), text(""))); return@launch }
            recordSkippedRows(page.skipped)
            for (message in page.messages) {
                val data = message.text.toByteArray(Charsets.UTF_8)
                val digest = MessageDigest.getInstance("SHA-256").digest(data)
                val count = (data.size + 3071) / 3072
                val streamId = UUID.randomUUID().toString()
                val thread = message.threadId.ifEmpty { "addr:" + smsNormalizedAddress(message.address).ifEmpty { message.address } }
                if (!sendPage(SmsWireMessage.of(6, text(streamId), text(requestId), text(message.messageId), text(thread), text(message.address), number(message.dateMillis), number(message.direction), flag(message.unread), number(data.size.toLong()), number(count.toLong()), data(digest), number(message.subscriptionId.toLong())))) return@launch
                for (index in 0 until count) {
                    val from = index * 3072
                    if (!sendPage(SmsWireMessage.of(7, text(streamId), number(index.toLong()), data(data.copyOfRange(from, minOf(from + 3072, data.size)))))) return@launch
                }
                if (!sendPage(SmsWireMessage.of(8, text(streamId)))) return@launch
            }
            sendPage(SmsWireMessage.of(18, text(requestId), number(0), number(page.nextBeforeMillis), text(page.nextBeforeMessageId)))
        } finally {
            cancelQueued(link, requestId)
            if (servingSearch[k]?.job == self) servingSearch.remove(k)
        }
    }
    servingSearch[k] = SmsController.Serving(requestId, link.channel.descriptor, job)
}
