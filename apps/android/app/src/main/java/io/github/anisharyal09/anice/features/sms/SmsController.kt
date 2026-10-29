// SPDX-License-Identifier: GPL-3.0-or-later
// Owns capability gating, provider page serving, live parking and reply assembly for SMS relay.
package io.github.anisharyal09.anice.features.sms

import androidx.compose.runtime.*
import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*
import kotlinx.coroutines.selects.select
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

data class SmsPermissionState(val receive: Boolean, val read: Boolean, val send: Boolean)
data class SmsDisplayMessage(val messageId: String, val address: String, val dateMillis: Long, val direction: Long, val unread: Boolean, val text: String, val pending: Boolean, val subscriptionId: Int = 0)

/**
 * Relay trace: counts, kinds and transport names only, never addresses, bodies or message ids.
 * The application installs the sink in debuggable builds; enable it with
 * `adb shell setprop log.tag.AniCeSms DEBUG` before the app process starts.
 */
internal object SmsTrace {
    const val TAG = "AniCeSms"
    var sink: ((String) -> Unit)? = null
    fun log(event: String) {
        sink?.invoke(event)
    }
}

class SmsComposeOperation internal constructor() {
    internal val completion = CompletableDeferred<SmsSendOutcome>()
    suspend fun result(): SmsSendOutcome = completion.await()
}

class SmsController(
    private val store: SmsStore,
    private val sender: SmsSender,
    dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
    private val subscriptions: SmsSubscriptionSource? = null,
    private val now: () -> Long = android.os.SystemClock::elapsedRealtime,
    private val wallNow: () -> Long = System::currentTimeMillis,
    private val wait: suspend (Long) -> Unit = { delay(it) },
    private val permissions: (String) -> Boolean = { false },
) : FeatureHandler {
    private class Queued(val message: SmsWireMessage, val owner: String, val deadline: Long) {
        val completion = CompletableDeferred<Boolean>()
    }
    private class Completed(val requestId: String, val outcome: SmsSendOutcome, val expiry: Long)
    private class Link(val channel: SecuredChannel) {
        var remoteCapability by mutableStateOf(false)
        /** Caps the Mac advertises on this link; a Bluetooth link gets smaller pages than a local-network one. */
        var remoteThreads = 50
        var remoteMessages = 50
        val queue = ArrayDeque<Queued>()
        var sending = false
        var wake = false
        val room = mutableListOf<CompletableDeferred<Unit>>()
    }
    private class Live(val event: SmsLiveEvent, val deadline: Long, private val onFirstAttempt: () -> Unit) {
        val streamId = UUID.randomUUID().toString()
        val attempted = mutableSetOf<ChannelDescriptor>()
        val acked = CompletableDeferred<Unit>()
        var rejected = false
        private val announced = AtomicBoolean(false)
        var job: Job? = null
        /** Next retry of a parked event; zero while nothing is due. */
        var retryAt = 0L
        fun attemptedOnce() { if (announced.compareAndSet(false, true)) onFirstAttempt() }
        /** When the parked event must be looked at again: its retry while it lives, else its deadline. */
        fun nextWake() = if (retryAt > 0) retryAt else deadline
    }
    private class Mark(val messageId: String, val expiry: Long)
    private class Extra(val row: SmsDisplayMessage, val expiry: Long, val seq: Long, val sortMillis: Long)
    private class Serving(val requestId: String, val descriptor: ChannelDescriptor, var job: Job? = null)
    private class Incoming(val descriptor: ChannelDescriptor, val requestId: String, val address: String, val totalBytes: Int, val count: Int, val digest: ByteArray, val subscriptionId: Int, val deadline: Long, val seq: Long, val sortMillis: Long) {
        val fragments = mutableListOf<ByteArray>()
        var committing = false
        var job: Job? = null
    }
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val links = mutableStateMapOf<String, Link>()
    private val servingThreads = mutableMapOf<String, Serving>()
    private val servingHistory = mutableMapOf<String, Serving>()
    private val servingSearch = mutableMapOf<String, Serving>()
    private val incomingReplies = mutableMapOf<String, Incoming>()
    private val completedReplies = mutableMapOf<String, ArrayDeque<Completed>>()
    private val pendingLive = ArrayDeque<Live>()
    private val marks = ArrayDeque<Mark>()
    private val displayExtras = mutableListOf<Extra>()
    /** Local observation order survives carrier clock differences and late radio verdicts. */
    private var arrivalSeq = 0L
    private fun nextArrival() = ++arrivalSeq
    private var lastSortMillis = 0L
    private fun nextSortMillis(): Long {
        lastSortMillis = maxOf(lastSortMillis, wallNow())
        return lastSortMillis
    }
    private var timer: Job? = null
    private var loadedRows: List<SmsHistoryMessage> = emptyList()
    private var loadedCursor: Pair<Long, String> = 0L to ""
    private var threadsJob: Job? = null
    private var threadCursor: Pair<Long, String> = 0L to ""
    /** Ownership token: a thread page only lands while its reset generation still stands. */
    private var threadGeneration = 0
    private var conversationJob: Job? = null
    /** Ownership token: a conversation load only lands while its selection still stands. */
    private var conversationGeneration = 0
    var permissionsState by mutableStateOf(SmsPermissionState(false, false, false)); private set
    /** Every SMS capability is granted; Settings drops its Messages card once this is true. */
    val granted: Boolean get() = permissionsState.receive && permissionsState.read && permissionsState.send
    var threads by mutableStateOf<List<SmsThreadRecord>?>(null); private set
    var threadsMore by mutableStateOf(false); private set
    var selectedThreadId by mutableStateOf<String?>(null); private set
    var conversation by mutableStateOf<List<SmsDisplayMessage>>(emptyList()); private set
    var conversationMore by mutableStateOf(false); private set
    private val drafts = mutableStateMapOf<String, String>()
    private val draftSubscriptions = mutableStateMapOf<String, Int>()
    private val composeOperations = mutableStateMapOf<String, SmsComposeOperation>()
    private var composeGeneration = 0L
    var loading by mutableStateOf(false); private set
    var status by mutableStateOf(""); private set
    var skippedRows by mutableStateOf(0); private set
    /** Relay counters for the panel: counts only, never addresses, bodies or message ids. */
    var relayedLive by mutableStateOf(0); private set
    var waitingLive by mutableStateOf(0); private set
    var failedLive by mutableStateOf(0); private set
    var onLanRequired: () -> Unit = {}

    // Cold start without visiting the panel first: Settings must know the real grant before it composes.
    init { refreshPermissions() }

    fun connected(peer: DeviceIdentity) = links.values.any { key(it.channel.descriptor.peer) == key(peer) }
    fun reachable(peer: DeviceIdentity) = candidateLinks().any { key(it.channel.descriptor.peer) == key(peer) }
    fun refreshPermissions() {
        permissionsState = SmsPermissionState(permissions(PERMISSION_RECEIVE), permissions(PERMISSION_READ), permissions(PERMISSION_SEND))
    }
    private fun key(peer: DeviceIdentity) = peer.deviceId + ":" + peer.fingerprint
    private fun live(d: ChannelDescriptor) = links[d.transport]?.channel?.descriptor == d
    private fun deadline(link: Link) = now() + if (link.channel.descriptor.transport == "ble") 60_000L else 30_000L
    private fun candidateLinks() = listOfNotNull(links["lan"], links["ble"]).filter { it.remoteCapability }

    override fun available(channel: SecuredChannel) {
        val d = channel.descriptor
        if (live(d)) return
        links[d.transport]?.let { retired(it.channel.descriptor) }
        val link = Link(channel)
        links[d.transport] = link
        announce(link)
        refreshPermissions()
    }

    /** Advertises the relay capability and this link's limits; a peer may re-advertise when its own hello was lost. */
    private fun announce(link: Link) {
        enqueue(link, SmsWireMessage.of(1, number(24576), number(8), number(50), number(50)))
    }

    override fun retired(descriptor: ChannelDescriptor) {
        if (!live(descriptor)) return
        val link = links.remove(descriptor.transport) ?: return
        link.queue.forEach { it.completion.complete(false) }; link.queue.clear()
        val waking = link.room.toList(); link.room.clear()
        waking.forEach { it.complete(Unit) }
        val k = key(descriptor.peer)
        if (links.values.none { key(it.channel.descriptor.peer) == k }) {
            servingThreads.remove(k)?.job?.cancel()
            servingHistory.remove(k)?.job?.cancel()
            servingSearch.remove(k)?.job?.cancel()
            incomingReplies.remove(k)?.job?.cancel()
            completedReplies.remove(k)
        }
        incomingReplies[k]?.takeIf { it.descriptor == descriptor }?.let {
            incomingReplies.remove(k); it.job?.cancel()
        }
        schedule()
    }

    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        if (!live(descriptor)) return
        val link = links[descriptor.transport] ?: return
        if (link.sending) link.wake = true else pump(link)
    }

    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        val m = try { SmsWireMessage.decode(bytes) ?: return DataHandling.UNRECOGNIZED }
            catch (_: SmsWireException) { return DataHandling.DISCARDED }
            catch (_: SessionException) { return DataHandling.DISCARDED }
        expire()
        if (!live(descriptor)) { SmsTrace.log("in ${m.kind} ${descriptor.transport} stale"); return DataHandling.DISCARDED }
        val link = links[descriptor.transport] ?: return DataHandling.DISCARDED
        SmsTrace.log("in ${m.kind} ${descriptor.transport}${if (link.remoteCapability) "" else " unadvertised"}")
        when (m.kind) {
            1L -> {
                val first = !link.remoteCapability
                link.remoteCapability = true
                link.remoteThreads = m.number(2).toInt().coerceIn(1, 50)
                link.remoteMessages = m.number(3).toInt().coerceIn(1, 50)
                if (first) announce(link)
                flush(); return DataHandling.HANDLED
            }
            2L -> {
                if (!link.remoteCapability) return DataHandling.DISCARDED
                serveThreads(link, m.text(0), m.number(1), m.text(2))
                return DataHandling.HANDLED
            }
            5L -> {
                if (!link.remoteCapability) return DataHandling.DISCARDED
                serveHistory(link, m.text(0), m.text(1), m.number(2), m.text(3), m.number(4).toInt())
                return DataHandling.HANDLED
            }
            15L -> {
                if (!link.remoteCapability) return DataHandling.DISCARDED
                serveSim(link, m.text(0))
                return DataHandling.HANDLED
            }
            17L -> {
                if (!link.remoteCapability) return DataHandling.DISCARDED
                serveSearch(link, m.text(0), m.text(1), m.number(2), m.text(3), m.number(4).toInt())
                return DataHandling.HANDLED
            }
            9L -> {
                val pending = pendingLive.firstOrNull { it.streamId == m.text(0) } ?: return DataHandling.DISCARDED
                if (descriptor !in pending.attempted) return DataHandling.DISCARDED
                val result = m.number(1)
                if (result != 0L) {
                    if (result in listOf(1L, 4L, 6L)) {
                        pending.rejected = true
                        pending.job?.cancel()
                        pendingLive.remove(pending)
                        failedLive++
                    }
                    syncLiveCounters()
                    status = "Mac rejected the message"
                    return DataHandling.HANDLED
                }
                if (!pending.acked.isCompleted) relayedLive++
                pending.acked.complete(Unit)
                syncLiveCounters()
                status = "Message relayed"
                SmsTrace.log("live: acked on ${descriptor.transport}, $relayedLive relayed")
                return DataHandling.HANDLED
            }
            11L -> {
                if (!link.remoteCapability) return DataHandling.DISCARDED
                beginIncoming(link, m)
                return DataHandling.HANDLED
            }
            12L -> {
                if (!link.remoteCapability) return DataHandling.DISCARDED
                if (!fragmentIncoming(link, m)) return DataHandling.DISCARDED
                return DataHandling.HANDLED
            }
            13L -> {
                if (!link.remoteCapability) return DataHandling.DISCARDED
                if (!commitIncoming(link, m)) return DataHandling.DISCARDED
                return DataHandling.HANDLED
            }
            else -> return DataHandling.UNRECOGNIZED
        }
    }

    private fun serveThreads(link: Link, requestId: String, beforeMillis: Long, beforeThreadId: String) {
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
                skippedRows += page.skipped
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
        servingThreads[k] = Serving(requestId, link.channel.descriptor, job)
    }

    private fun serveHistory(link: Link, requestId: String, threadId: String, beforeMillis: Long, beforeMessageId: String, limit: Int) {
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
                skippedRows += page.skipped
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
        servingHistory[k] = Serving(requestId, link.channel.descriptor, job)
    }

    /** One platform read answered with exactly one simDone; nothing is persisted and nothing is retried. */
    private fun serveSim(link: Link, requestId: String) {
        val listing = try { subscriptions?.list() ?: SmsSubscriptionListing(5, emptyList()) } catch (_: Exception) { SmsSubscriptionListing(5, emptyList()) }
        val entries = Cbor.Array(listing.entries.map { entry ->
            Cbor.Array(listOf(number(entry.subscriptionId.toLong()), number(entry.slotIndex.toLong()), text(entry.label), flag(entry.isDefault)))
        })
        enqueue(link, SmsWireMessage.of(16, text(requestId), number(listing.result), entries))
    }

    /** A search page streams hits as regular message records under the search requestId; a newer request cancels this one. */
    private fun serveSearch(link: Link, requestId: String, query: String, beforeMillis: Long, beforeMessageId: String, limit: Int) {
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
                skippedRows += page.skipped
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
        servingSearch[k] = Serving(requestId, link.channel.descriptor, job)
    }

    private fun beginIncoming(link: Link, m: SmsWireMessage) {
        val k = key(link.channel.descriptor.peer)
        val requestId = m.text(0)
        completedReplies[k]?.firstOrNull { it.requestId == requestId }?.let {
            replyResult(link, requestId, it.outcome.result, it.outcome.messageId, it.outcome.dateMillis)
            return
        }
        val current = incomingReplies[k]
        if (current?.requestId == requestId) {
            if (current.address != m.text(2) || current.totalBytes != m.number(3).toInt() || current.count != m.number(4).toInt() || !current.digest.contentEquals(m.bytes(5))) {
                incomingReplies.remove(k)?.job?.cancel()
                replyResult(link, requestId, 6, "", 0)
            }
            return
        }
        if (current != null) { replyResult(link, requestId, 2, "", 0); return }
        incomingReplies[k] = Incoming(link.channel.descriptor, requestId, m.text(2), m.number(3).toInt(), m.number(4).toInt(), m.bytes(5), m.number(6).toInt(), deadline(link), nextArrival(), nextSortMillis())
        schedule()
    }

    private fun fragmentIncoming(link: Link, m: SmsWireMessage): Boolean {
        val k = key(link.channel.descriptor.peer)
        val current = incomingReplies[k]?.takeIf { it.requestId == m.text(0) && it.descriptor == link.channel.descriptor } ?: return false
        if (current.committing) return false
        val index = m.number(1).toInt()
        val expected = if (index == current.count - 1) current.totalBytes - index * 3072 else 3072
        if (index >= current.count || m.bytes(2).size != expected || index > current.fragments.size || index < current.fragments.size && !current.fragments[index].contentEquals(m.bytes(2))) {
            incomingReplies.remove(k)
            replyResult(link, m.text(0), 6, "", 0)
            return true
        }
        if (index == current.fragments.size) current.fragments.add(m.bytes(2))
        return true
    }

    private fun commitIncoming(link: Link, m: SmsWireMessage): Boolean {
        val k = key(link.channel.descriptor.peer)
        completedReplies[k]?.firstOrNull { it.requestId == m.text(0) }?.let {
            replyResult(link, it.requestId, it.outcome.result, it.outcome.messageId, it.outcome.dateMillis); return true
        }
        val current = incomingReplies[k]?.takeIf { it.requestId == m.text(0) && it.descriptor == link.channel.descriptor } ?: return false
        if (current.committing) return true
        if (current.fragments.size != current.count) {
            incomingReplies.remove(k)
            replyResult(link, m.text(0), 6, "", 0)
            return true
        }
        current.committing = true
        val job = scope.launch {
            val data = current.fragments.fold(java.io.ByteArrayOutputStream()) { out, fragment -> out.apply { write(fragment) } }.toByteArray()
            val text = withContext(Dispatchers.Default) {
                if (!MessageDigest.getInstance("SHA-256").digest(data).contentEquals(current.digest)) null
                else try {
                    Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(data)).toString().takeIf { '\u0000' !in it }
                } catch (_: java.nio.charset.CharacterCodingException) { null }
            }
            if (text == null) {
                if (incomingReplies[k] === current) {
                    incomingReplies.remove(k)
                    replyResult(link, current.requestId, 6, "", 0)
                }
                return@launch
            }
            // Retiring, expiry or a newer request may drop this one while validation runs: never send for a dead request.
            if (incomingReplies[k] !== current || !live(current.descriptor) || now() >= current.deadline) return@launch
            val outcome = try { sender.send(current.address, text, current.subscriptionId, maxOf(1, current.deadline - now())) } catch (e: CancellationException) { throw e } catch (_: Exception) { SmsSendOutcome(5, "", 0) }
            // Only clear the slot when it still holds this request; a newer reply keeps its own tracking.
            if (incomingReplies[k] !== current) return@launch
            incomingReplies.remove(k)
            replyResult(link, current.requestId, outcome.result, outcome.messageId, outcome.dateMillis)
            if (outcome.result == 0L) {
                val raw = outcome.dateMillis.takeIf { it > 0 } ?: System.currentTimeMillis()
                // Synthetic echoes use whole-second display time; ordering retains the submit observation.
                val stamp = if (outcome.messageId.isEmpty()) raw / 1000 * 1000 else raw
                val row = SmsDisplayMessage(outcome.messageId.ifEmpty { "echo:" + UUID.randomUUID() }, current.address, stamp, 1, false, text, outcome.messageId.isEmpty(), current.subscriptionId)
                displayExtras += Extra(row, now() + EXTRAS_LIFETIME, current.seq, current.sortMillis)
                upsertSentThread(current.address, text, stamp)
                refreshConversation()
                status = "Reply sent"
                if (outcome.messageId.isEmpty()) recheckPendingEcho()
            } else if (outcome.result == 1L) {
                status = "SEND_SMS permission is required"
            } else if (outcome.result == 4L) {
                status = "That SIM is not active on this phone"
            } else {
                status = "Not confirmed; it may have been sent"
            }
            schedule()
        }
        current.job = job
        return true
    }

    private fun replyResult(link: Link, requestId: String, result: Long, messageId: String, dateMillis: Long) {
        val completed = completedReplies.getOrPut(key(link.channel.descriptor.peer)) { ArrayDeque() }
        if (completed.none { it.requestId == requestId }) {
            if (completed.size >= 32) completed.removeFirst()
            completed.addLast(Completed(requestId, SmsSendOutcome(result, messageId, dateMillis), now() + MARK_LIFETIME))
        }
        enqueue(link, SmsWireMessage.of(14, text(requestId), number(result), text(messageId), number(dateMillis)))
    }

    /** Hands decoded messages to the relay; [complete] fires with the first delivery attempt or after 8 seconds. */
    fun submitLive(events: List<SmsLiveEvent>, complete: () -> Unit = {}) {
        expire()
        val finished = AtomicBoolean(false)
        fun finish() { if (finished.compareAndSet(false, true)) complete() }
        if (events.isEmpty()) { finish(); return }
        onLanRequired()
        scope.launch { wait(FAILURE_BOUND); finish() }
        var first = true
        var admitted = 0
        for (event in events) {
            val text = smsSanitizeText(event.body)
            val bytes = text?.toByteArray(Charsets.UTF_8)
            if (event.address.toByteArray(Charsets.UTF_8).size !in 1..64 || event.normalizedAddress.isEmpty() || event.threadId.toByteArray().size > 80 || event.dateMillis !in 0..SmsWireMessage.MAX_DATE || text == null || bytes == null || bytes.isEmpty() || bytes.size > SmsWireMessage.MAX_BODY_BYTES) { skippedRows++; continue }
            val cleanEvent = event.copy(body = text)
            if (duplicate(cleanEvent)) continue
            marks += Mark(cleanEvent.messageId, now() + MARK_LIFETIME)
            if (pendingLive.size >= PENDING_LIVE_LIMIT) { pendingLive.removeFirst().job?.cancel(); failedLive++ }
            val live = Live(cleanEvent, now() + PENDING_LIVE_LIFETIME) { finish() }
            pendingLive.addLast(live)
            displayExtras += Extra(SmsDisplayMessage(cleanEvent.messageId, event.address, event.dateMillis, 0, true, text, false, cleanEvent.subscriptionId), now() + PENDING_LIVE_LIFETIME, nextArrival(), nextSortMillis())
            status = "Incoming message"
            live.job = scope.launch { deliver(live) }
            upsertLiveThread(event, text)
            admitted++
            first = false
        }
        if (first) finish()
        SmsTrace.log("live: admitted=$admitted of ${events.size}, links=${links.size}, capable=${candidateLinks().size}, queued=${pendingLive.size}")
        syncLiveCounters()
        refreshConversation()
        schedule()
    }

    private fun syncLiveCounters() {
        waitingLive = pendingLive.count { !it.acked.isCompleted }
    }

    /** A live message lands in the panel's conversation list at once; the next provider load replaces the row. */
    private fun upsertLiveThread(event: SmsLiveEvent, text: String) {
        val current = threads ?: return
        val normalized = event.normalizedAddress
        val snippet = smsTruncate(text, 160)
        val index = current.indexOfFirst { it.threadId == event.threadId || smsNormalizedAddress(it.address) == normalized }
        threads = if (index < 0) {
            current + SmsThreadRecord(event.threadId, event.address, snippet, event.dateMillis, 1)
        } else {
            current.toMutableList().also { list ->
                val row = list[index]
                list[index] = row.copy(snippet = if (event.dateMillis >= row.dateMillis) snippet else row.snippet, dateMillis = maxOf(row.dateMillis, event.dateMillis), unreadCount = row.unreadCount + 1)
            }
        }.sortedWith { a, b ->
            val date = b.dateMillis.compareTo(a.dateMillis)
            if (date != 0) date else smsCompareMessageIds(b.threadId, a.threadId)
        }
    }

    /** A sent message updates the panel's list snippet at once, without touching its unread count. */
    private fun upsertSentThread(address: String, text: String, dateMillis: Long) {
        val current = threads ?: return
        val normalized = smsNormalizedAddress(address)
        val index = current.indexOfFirst { smsNormalizedAddress(it.address) == normalized }
        if (index < 0) return
        threads = current.toMutableList().also { list ->
            val row = list[index]
            val date = maxOf(row.dateMillis, dateMillis)
            list[index] = row.copy(snippet = if (dateMillis >= row.dateMillis) smsTruncate(text, 160) else row.snippet, dateMillis = date)
        }.sortedWith { a, b ->
            val date = b.dateMillis.compareTo(a.dateMillis)
            if (date != 0) date else smsCompareMessageIds(b.threadId, a.threadId)
        }
    }

    private fun duplicate(event: SmsLiveEvent): Boolean {
        val time = now()
        marks.removeAll { it.expiry <= time }
        return marks.any { mark -> mark.messageId == event.messageId }
    }

    private fun flush() {
        pendingLive.filterNot { it.acked.isCompleted }.forEach { live ->
            if (live.job?.isActive != true) live.job = scope.launch { deliver(live) }
        }
        schedule()
    }

    private suspend fun deliver(live: Live) {
        // Each round may use one attempt per live transport; a retry round starts over.
        live.attempted.clear()
        live.retryAt = 0
        try {
            repeat(2) {
                if (live.acked.isCompleted || live.rejected || now() >= live.deadline) return@repeat
                val candidates = candidateLinks()
                if (candidates.isEmpty()) {
                    // No authenticated Mac advertises the relay, so the event stays parked for its retry window.
                    status = "Waiting for the Mac"
                    return@repeat
                }
                val link = candidates.firstOrNull { l -> live.attempted.none { it == l.channel.descriptor } } ?: return@repeat
                live.attempted.add(link.channel.descriptor)
                var transmitted = false
                val attemptDeadline = minOf(live.deadline, deadline(link))
                try {
                    withTimeout(maxOf(1, attemptDeadline - now())) {
                        val bytes = live.event.body.toByteArray(Charsets.UTF_8)
                        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
                        val count = (bytes.size + 3071) / 3072
                        val begin = SmsWireMessage.of(6, text(live.streamId), text(""), text(live.event.messageId), text(live.event.threadId), text(live.event.address), number(live.event.dateMillis), number(0), flag(true), number(bytes.size.toLong()), number(count.toLong()), data(digest), number(live.event.subscriptionId.toLong()))
                        if (!send(link, begin, attemptDeadline)) throw CancellationException("SMS channel retired")
                        for (index in 0 until count) {
                            val from = index * 3072
                            if (!send(link, SmsWireMessage.of(7, text(live.streamId), number(index.toLong()), data(bytes.copyOfRange(from, minOf(from + 3072, bytes.size)))), attemptDeadline)) throw CancellationException("SMS channel retired")
                        }
                        if (!send(link, SmsWireMessage.of(8, text(live.streamId)), attemptDeadline)) throw CancellationException("SMS channel retired")
                        transmitted = true
                        SmsTrace.log("live: stream sent on ${link.channel.descriptor.transport}")
                    }
                } catch (e: CancellationException) { currentCoroutineContext().ensureActive() }
                  catch (_: Exception) { /* The same event may use its one alternate transport. */ }
                if (transmitted) {
                    live.attemptedOnce()
                    try {
                        coroutineScope {
                            val timeout = async(start = CoroutineStart.UNDISPATCHED) { wait(minOf(LIVE_ACK_WAIT, maxOf(1, live.deadline - now()))) }
                            try { select<Unit> { live.acked.onAwait { }; timeout.onAwait { } } } finally { timeout.cancel() }
                        }
                    } catch (e: CancellationException) { currentCoroutineContext().ensureActive() }
                }
                if (live.acked.isCompleted) return
            }
            // Nothing capable answered: a peer that never saw our hello is asked to announce itself again,
            // so a lost capability record parks the event for a retry rather than until a new channel.
            if (candidateLinks().isEmpty()) links.values.filterNot { it.remoteCapability }.forEach { announce(it) }
        } finally {
            // An unacknowledged event keeps trying inside its lifetime, so a lost fragment or completion
            // acknowledgement costs seconds rather than waiting for the next channel to be established.
            val parked = !live.acked.isCompleted && !live.rejected && now() < live.deadline
            if (parked) live.retryAt = now() + LIVE_RETRY_DELAY
            SmsTrace.log("live: ${if (live.acked.isCompleted) "delivered" else if (parked) "parked" else "lapsed"}")
            schedule()
        }
    }

    private fun cancelQueued(link: Link, owner: String) {
        link.queue.removeAll { queued ->
            if (queued.owner != owner) false else { queued.completion.complete(false); true }
        }
        link.room.toList().forEach { it.complete(Unit) }; link.room.clear()
    }

    private fun enqueue(link: Link, message: SmsWireMessage) {
        if (!live(link.channel.descriptor)) return
        if (link.queue.size >= QUEUE_LIMIT) { status = "SMS channel is busy"; return }
        val owner = if (message.kind == 1L) "" else message.text(0)
        link.queue.addLast(Queued(message, owner, deadline(link))); pump(link); schedule()
    }

    private suspend fun send(link: Link, message: SmsWireMessage, deadline: Long, owner: String = message.text(0)): Boolean {
        var queued: Queued? = null
        try {
            return withTimeout(maxOf(1, deadline - now())) {
                while (live(link.channel.descriptor) && now() < deadline) {
                    if (link.queue.size < QUEUE_LIMIT) {
                        val entry = Queued(message, owner, deadline)
                        queued = entry; link.queue.addLast(entry); pump(link); schedule()
                        return@withTimeout entry.completion.await()
                    }
                    val room = CompletableDeferred<Unit>(); link.room.add(room)
                    try { room.await() } finally { link.room.remove(room) }
                }
                false
            }
        } catch (_: TimeoutCancellationException) { return false }
        finally { queued?.let { link.queue.remove(it); it.completion.complete(false) } }
    }

    private fun pump(link: Link) {
        if (link.sending) return
        link.sending = true
        scope.launch {
            try {
                do {
                    link.wake = false
                    while (live(link.channel.descriptor) && link.queue.isNotEmpty()) {
                        val first = link.queue.first()
                        if (first.deadline <= now()) {
                            link.queue.removeFirst(); first.completion.complete(false); continue
                        }
                        try { withTimeout(maxOf(1, first.deadline - now())) { link.channel.sendData(first.message.encode()) } }
                        catch (_: SessionBackpressure) { break }
                        catch (e: CancellationException) {
                            if (e !is TimeoutCancellationException) throw e
                            status = "SMS submission was not confirmed"; retired(link.channel.descriptor); break
                        }
                        catch (_: Exception) {
                            status = "SMS channel unavailable"; retired(link.channel.descriptor); break
                        }
                        if (link.queue.firstOrNull() === first) link.queue.removeFirst()
                        first.completion.complete(true)
                        link.room.removeFirstOrNull()?.complete(Unit)
                    }
                } while (link.wake && live(link.channel.descriptor))
            } finally { link.sending = false }
        }
    }

    /** First page for the local panel; the view keeps asking for more while [threadsMore] stays true. */
    fun loadThreads() = loadThreadPage(reset = true)

    fun loadMoreThreads() {
        if (threadsMore && !loading) loadThreadPage(reset = false)
    }

    private fun loadThreadPage(reset: Boolean) {
        if (reset) {
            threadsJob?.cancel()
            threadGeneration++
            threadCursor = 0L to ""
            threadsMore = false
        } else if (threadsJob?.isActive == true) return
        val generation = threadGeneration
        val cursor = if (reset) 0L to "" else threadCursor
        threadsJob = scope.launch {
            loading = true
            try {
                var failed = false
                val page = try { store.threads(PANEL_THREAD_PAGE, cursor.first, cursor.second) }
                    catch (e: CancellationException) { throw e }
                    catch (_: SmsPagingUnsupported) { status = "Too many conversations share a timestamp to load this page"; return@launch }
                    catch (_: Exception) { failed = true; null }
                // A reset started while this page ran: its rows and cursor must not land here.
                if (generation != threadGeneration) return@launch
                if (page == null) {
                    status = if (failed) "Conversations are unavailable" else "READ_SMS permission is required to load conversations"
                } else if (page.partial) {
                    status = "Some conversation sources are unavailable. Try again."
                } else {
                    skippedRows += page.skipped
                    val combined = if (reset) page.threads else (threads.orEmpty() + page.threads).distinctBy { it.threadId }
                    threads = combined
                    threadCursor = page.nextBeforeMillis to page.nextBeforeThreadId
                    threadsMore = page.more
                    status = when {
                        combined.isEmpty() -> "No conversations on this device"
                        else -> "${combined.size} conversations"
                    }
                }
            } finally { if (generation == threadGeneration) loading = false }
        }
    }

    fun select(threadId: String?) {
        if (selectedThreadId == threadId) return
        selectedThreadId = threadId
        conversationGeneration++
        conversationJob?.cancel()
        loadedRows = emptyList(); loadedCursor = 0L to ""; conversationMore = false
        refreshConversation()
        if (threadId != null) loadConversation()
    }

    fun loadConversation() {
        val threadId = selectedThreadId ?: return
        val cursor = loadedCursor
        conversationJob?.cancel()
        conversationGeneration++
        val generation = conversationGeneration
        conversationJob = scope.launch {
            loading = true
            try {
                var failed = false
                val page = try { store.history(threadId, cursor.first, cursor.second, DEFAULT_PAGE_SIZE) }
                    catch (e: CancellationException) { throw e }
                    catch (_: SmsPagingUnsupported) { status = "This timestamp group is too large to page"; return@launch }
                    catch (_: Exception) { failed = true; null }
                // Another thread was selected while this load ran: its rows and cursor must not land here.
                if (generation != conversationGeneration || selectedThreadId != threadId) return@launch
                if (page == null) status = if (failed) "Messages are unavailable" else "READ_SMS permission is required to load messages"
                else {
                    skippedRows += page.skipped
                    loadedRows = (page.messages + loadedRows).distinctBy { it.messageId }
                    loadedCursor = page.nextBeforeMillis to page.nextBeforeMessageId
                    conversationMore = page.more
                    if (page.partial) status = "Some message sources are unavailable"
                    refreshConversation()
                }
            } finally { if (generation == conversationGeneration) loading = false }
        }
    }

    /**
     * A sent provider row can land just after the sentIntent resolves, leaving the local echo pending; one bounded
     * re-read of the newest page replaces it with the provider row instead of showing "Sending" for its lifetime.
     */
    private fun recheckPendingEcho() {
        scope.launch {
            wait(ECHO_RECHECK_DELAY)
            if (selectedThreadId != null) { loadedCursor = 0L to ""; loadConversation() }
        }
    }

    fun draft(key: String): String = drafts[key].orEmpty()

    fun sendingDraft(key: String): Boolean = key in composeOperations

    fun draftSubscription(key: String): Int = draftSubscriptions[key] ?: 0

    fun chooseDraftSubscription(key: String, subscriptionId: Int) {
        if (subscriptionId == 0) draftSubscriptions.remove(key) else draftSubscriptions[key] = subscriptionId
    }

    fun saveDraft(key: String, value: String) {
        if (value.isEmpty()) drafts.remove(key) else drafts[key] = value
    }

    fun retainDrafts(peerCredentials: Set<String>) {
        drafts.keys.removeAll { key -> !key.startsWith("local|") && peerCredentials.none { key.startsWith("$it|") } }
        draftSubscriptions.keys.removeAll { key -> !key.startsWith("local|") && peerCredentials.none { key.startsWith("$it|") } }
    }

    fun send(address: String, text: String, subscriptionId: Int = 0, draftKey: String? = null): SmsComposeOperation {
        if (draftKey != null) composeOperations[draftKey]?.let { return it }
        val operation = SmsComposeOperation()
        val clean = smsSanitizeText(text)
        val bytes = clean?.toByteArray(Charsets.UTF_8)
        if (address.isEmpty() || clean.isNullOrEmpty() || bytes == null || bytes.size > SmsWireMessage.MAX_BODY_BYTES) {
            operation.completion.complete(SmsSendOutcome(6, "", 0)); status = "Message must be plain text up to 24 KiB"
            return operation
        }
        // Capture order before the radio call: a reply received during confirmation must stay above this send.
        val echoSeq = nextArrival()
        val echoSortMillis = nextSortMillis()
        val generation = composeGeneration
        if (draftKey != null) composeOperations[draftKey] = operation
        scope.launch {
            val outcome = try { sender.send(address, clean, subscriptionId) } catch (_: Exception) { SmsSendOutcome(5, "", 0) }
            // A radio result after identity reset must not restore retired conversation state.
            if (generation != composeGeneration) {
                operation.completion.complete(outcome)
                return@launch
            }
            when (outcome.result) {
                0L -> {
                    val raw = outcome.dateMillis.takeIf { it > 0 } ?: System.currentTimeMillis()
                    val stamp = if (outcome.messageId.isEmpty()) raw / 1000 * 1000 else raw
                    displayExtras += Extra(SmsDisplayMessage(outcome.messageId.ifEmpty { "echo:" + UUID.randomUUID() }, address, stamp, 1, false, clean, outcome.messageId.isEmpty(), subscriptionId), now() + EXTRAS_LIFETIME, echoSeq, echoSortMillis)
                    upsertSentThread(address, clean, stamp)
                    if (draftKey != null && drafts[draftKey] == text) drafts.remove(draftKey)
                    refreshConversation(); status = "Message sent"
                    if (outcome.messageId.isEmpty()) recheckPendingEcho()
                }
                1L -> status = "SEND_SMS permission is required"
                4L -> status = "That SIM is not active on this phone"
                5L -> status = "Not confirmed; it may have been sent"
                else -> status = "Message rejected"
            }
            if (draftKey != null) composeOperations.remove(draftKey)
            operation.completion.complete(outcome)
            schedule()
        }
        return operation
    }

    /** The panel offers a SIM choice only on a multi-modem phone; the phone default needs no permission or listing. */
    fun modemCount(): Int = try { subscriptions?.modemCount() ?: 0 } catch (_: Exception) { 0 }

    fun listSubscriptions(): SmsSubscriptionListing = try { subscriptions?.list() ?: SmsSubscriptionListing(5, emptyList()) } catch (_: Exception) { SmsSubscriptionListing(5, emptyList()) }

    private fun refreshConversation() {
        val time = now()
        displayExtras.removeAll { it.expiry <= time }
        // With a thread open, only extras for that address render; another sender's row stays out of view.
        val selected = selectedThreadId
        val address = selected?.let { id -> threads?.firstOrNull { it.threadId == id }?.address } ?: loadedRows.firstOrNull()?.address
        // The provider record wins: a live copy or sent echo matching a provider row is hidden, never duplicated.
        val unmatched = loadedRows.toMutableList()
        // Arrival order decides a timestamp tie — a reply that landed after the send — never synthetic IDs.
        // A provider row inherits the arrival slot of the live copy or echo it replaced.
        val arrival = HashMap<String, Long>()
        val sortDates = HashMap<String, Long>()
        val visible = mutableListOf<SmsDisplayMessage>()
        for (extra in displayExtras) {
            if (selected != null && (address == null || smsNormalizedAddress(extra.row.address) != smsNormalizedAddress(address))) continue
            val index = unmatched.indexOfFirst { row -> row.direction == extra.row.direction && sameContent(row, extra.row) }
            if (index < 0) {
                visible += extra.row
                arrival[extra.row.messageId] = extra.seq
                sortDates[extra.row.messageId] = extra.sortMillis
            } else {
                val id = unmatched.removeAt(index).messageId
                arrival[id] = extra.seq
                sortDates[id] = extra.sortMillis
            }
        }
        conversation = (loadedRows.map { SmsDisplayMessage(it.messageId, it.address, it.dateMillis, it.direction, it.unread, it.text, false, it.subscriptionId) } + visible).sortedWith { a, b ->
            // Carrier timestamps can precede the send they answer. Observed rows and their provider
            // copies keep local submit/receive order; untouched history retains provider chronology.
            val d = ((sortDates[b.messageId] ?: b.dateMillis) / 1000).compareTo((sortDates[a.messageId] ?: a.dateMillis) / 1000)
            if (d != 0) d
            else {
                val ra = arrival[a.messageId] ?: -1L
                val rb = arrival[b.messageId] ?: -1L
                if (ra != rb) rb.compareTo(ra) else -smsCompareMessageIds(a.messageId, b.messageId)
            }
        }
    }

    private fun sameContent(row: SmsHistoryMessage, extra: SmsDisplayMessage): Boolean {
        if (smsNormalizedAddress(row.address) != smsNormalizedAddress(extra.address)) return false
        if (kotlin.math.abs(row.dateMillis - extra.dateMillis) > MERGE_TOLERANCE) return false
        // Two SIMs can deliver identical content at the same moment; only merge when the origins agree or one is unknown.
        if (row.subscriptionId != 0 && extra.subscriptionId != 0 && row.subscriptionId != extra.subscriptionId) return false
        return MessageDigest.getInstance("SHA-256").digest(row.text.toByteArray(Charsets.UTF_8)).contentEquals(MessageDigest.getInstance("SHA-256").digest(extra.text.toByteArray(Charsets.UTF_8)))
    }

    fun expire() {
        val time = now()
        for (link in links.values) {
            link.queue.removeAll { if (it.deadline <= time) { it.completion.complete(false); true } else false }
            link.room.toList().forEach { it.complete(Unit) }; link.room.clear()
        }
        marks.removeAll { it.expiry <= time }
        completedReplies.values.forEach { queue -> queue.removeAll { it.expiry <= time } }
        displayExtras.removeAll { it.expiry <= time }
        val lapsed = pendingLive.count { !it.acked.isCompleted && it.deadline <= time }
        pendingLive.removeAll { if (it.acked.isCompleted || it.deadline <= time) { it.job?.cancel(); true } else false }
        if (lapsed > 0) {
            failedLive += lapsed
            status = "A message could not reach the Mac"
        }
        // Parked events are retried until they are acknowledged or their lifetime ends.
        pendingLive.filter { !it.acked.isCompleted && it.retryAt > 0 && it.retryAt <= time && it.job?.isActive != true }.forEach { live ->
            live.job = scope.launch { deliver(live) }
        }
        syncLiveCounters()
        incomingReplies.entries.removeAll { (k, incoming) ->
            if (incoming.deadline > time) return@removeAll false
            incoming.job?.cancel()
            links.values.firstOrNull { key(it.channel.descriptor.peer) == k }?.let { replyResult(it, incoming.requestId, 5, "", 0) }
            true
        }
        // Extras pruned here still hold the rendered copy; refresh so an expired "Sending" row cannot stick.
        refreshConversation()
        schedule()
    }

    private fun schedule() {
        timer?.cancel(); timer = null
        val next = (marks.map { it.expiry } + displayExtras.map { it.expiry } + pendingLive.map { it.nextWake() } + incomingReplies.values.map { it.deadline } + links.values.flatMap { link -> link.queue.map { it.deadline } } + completedReplies.values.flatMap { rows -> rows.map { it.expiry } }).minOrNull() ?: return
        timer = scope.launch { wait(maxOf(1, next - now())); expire() }
    }

    fun invalidate() {
        composeGeneration++
        composeOperations.clear()
        timer?.cancel(); timer = null
        servingThreads.values.forEach { it.job?.cancel() }; servingThreads.clear()
        servingHistory.values.forEach { it.job?.cancel() }; servingHistory.clear()
        servingSearch.values.forEach { it.job?.cancel() }; servingSearch.clear()
        pendingLive.forEach { it.job?.cancel() }; pendingLive.clear()
        incomingReplies.values.forEach { it.job?.cancel() }
        incomingReplies.clear(); completedReplies.clear(); marks.clear(); displayExtras.clear(); loadedRows = emptyList()
        relayedLive = 0; waitingLive = 0; failedLive = 0; drafts.clear(); draftSubscriptions.clear()
        threadsJob?.cancel(); conversationJob?.cancel(); conversationGeneration++; threadGeneration++
        threadCursor = 0L to ""; threadsMore = false
        threads = null; selectedThreadId = null; conversation = emptyList(); conversationMore = false; loading = false
        links.values.toList().forEach { retired(it.channel.descriptor) }
    }

    companion object {
        const val PERMISSION_RECEIVE = "android.permission.RECEIVE_SMS"
        const val PERMISSION_READ = "android.permission.READ_SMS"
        const val PERMISSION_SEND = "android.permission.SEND_SMS"
        private const val QUEUE_LIMIT = 128
        private const val MARK_LIFETIME = 600_000L
        private const val PENDING_LIVE_LIMIT = 16
        private const val PENDING_LIVE_LIFETIME = 600_000L
        /** How long an unacknowledged live stream waits for its completion acknowledgement. */
        private const val LIVE_ACK_WAIT = 2_000L
        /** How soon a still-parked live event is offered again, until it is acknowledged or expires. */
        private const val LIVE_RETRY_DELAY = 5_000L
        private const val EXTRAS_LIFETIME = 600_000L
        /** How long after a send the newest page is re-read to replace a pending echo with its provider row. */
        private const val ECHO_RECHECK_DELAY = 2_000L
        /** First page shown when a conversation opens; the panel and the Mac offer older pages from its cursor. */
        private const val DEFAULT_PAGE_SIZE = 10
        /** The local panel's first page; the rest follows on scroll so the list paints immediately. */
        private const val PANEL_THREAD_PAGE = 15
        private const val MERGE_TOLERANCE = 5_000L
        private const val FAILURE_BOUND = 8_000L
    }
}
