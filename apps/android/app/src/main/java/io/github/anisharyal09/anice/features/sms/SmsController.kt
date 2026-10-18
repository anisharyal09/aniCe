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
data class SmsDisplayMessage(val messageId: String, val address: String, val dateMillis: Long, val direction: Long, val unread: Boolean, val text: String, val pending: Boolean)

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
    private val now: () -> Long = android.os.SystemClock::elapsedRealtime,
    private val wait: suspend (Long) -> Unit = { delay(it) },
    private val permissions: (String) -> Boolean = { false },
) : FeatureHandler {
    private class Link(val channel: SecuredChannel) {
        var remoteCapability by mutableStateOf(false)
        /** Caps the Mac advertises on this link; a Bluetooth link gets smaller pages than a local-network one. */
        var remoteThreads = 50
        var remoteMessages = 50
        val queue = ArrayDeque<SmsWireMessage>()
        var sending = false
        var wake = false
        val capacity = mutableListOf<CompletableDeferred<Unit>>()
        val room = mutableListOf<CompletableDeferred<Unit>>()
    }
    private class Live(val event: SmsLiveEvent, val deadline: Long, private val onFirstAttempt: () -> Unit) {
        val streamId = UUID.randomUUID().toString()
        val attempted = mutableSetOf<ChannelDescriptor>()
        val acked = CompletableDeferred<Unit>()
        private val announced = AtomicBoolean(false)
        var job: Job? = null
        /** Next retry of a parked event; zero while nothing is due. */
        var retryAt = 0L
        fun attemptedOnce() { if (announced.compareAndSet(false, true)) onFirstAttempt() }
        /** When the parked event must be looked at again: its retry while it lives, else its deadline. */
        fun nextWake() = if (retryAt > 0) retryAt else deadline
    }
    private class Mark(val messageId: String, val address: String, val digest: ByteArray, val dateMillis: Long, val expiry: Long)
    private class Extra(val row: SmsDisplayMessage, val expiry: Long)
    private class Serving(val requestId: String, val descriptor: ChannelDescriptor, var job: Job? = null)
    private class Incoming(val requestId: String, val address: String, val totalBytes: Int, val count: Int, val digest: ByteArray, val deadline: Long) {
        val fragments = mutableListOf<ByteArray>()
        var committing = false
        var job: Job? = null
    }
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val links = mutableStateMapOf<String, Link>()
    private val servingThreads = mutableMapOf<String, Serving>()
    private val servingHistory = mutableMapOf<String, Serving>()
    private val incomingReplies = mutableMapOf<String, Incoming>()
    private val pendingLive = ArrayDeque<Live>()
    private val marks = ArrayDeque<Mark>()
    private val displayExtras = mutableListOf<Extra>()
    private var timer: Job? = null
    private var loadedRows: List<SmsHistoryMessage> = emptyList()
    private var loadedCursor: Pair<Long, String> = 0L to ""
    /** Ownership token: a conversation load only lands while its selection still stands. */
    private var conversationJob: Job? = null
    private var conversationGeneration = 0
    var permissionsState by mutableStateOf(SmsPermissionState(false, false, false)); private set
    var threads by mutableStateOf<List<SmsThreadRecord>?>(null); private set
    var selectedThreadId by mutableStateOf<String?>(null); private set
    var conversation by mutableStateOf<List<SmsDisplayMessage>>(emptyList()); private set
    var conversationMore by mutableStateOf(false); private set
    var loading by mutableStateOf(false); private set
    var status by mutableStateOf("Grant SMS permissions to relay messages"); private set
    var skippedRows by mutableStateOf(0); private set
    /** Relay counters for the panel: counts only, never addresses, bodies or message ids. */
    var relayedLive by mutableStateOf(0); private set
    var waitingLive by mutableStateOf(0); private set
    var failedLive by mutableStateOf(0); private set
    var onLanRequired: () -> Unit = {}

    fun connected(peer: DeviceIdentity) = links.values.any { key(it.channel.descriptor.peer) == key(peer) }
    fun reachable(peer: DeviceIdentity) = candidateLinks().any { key(it.channel.descriptor.peer) == key(peer) }
    fun refreshPermissions() {
        permissionsState = SmsPermissionState(permissions(PERMISSION_RECEIVE), permissions(PERMISSION_READ), permissions(PERMISSION_SEND))
    }
    private fun key(peer: DeviceIdentity) = peer.deviceId + ":" + peer.fingerprint
    private fun live(d: ChannelDescriptor) = links[d.transport]?.channel?.descriptor == d
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
        val waking = link.capacity.toList() + link.room.toList(); link.capacity.clear(); link.room.clear()
        waking.forEach { it.complete(Unit) }
        val k = key(descriptor.peer)
        if (links.values.none { key(it.channel.descriptor.peer) == k }) {
            servingThreads.remove(k)?.job?.cancel()
            servingHistory.remove(k)?.job?.cancel()
            incomingReplies.remove(k)?.job?.cancel()
        }
        schedule()
    }

    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        if (!live(descriptor)) return
        val link = links[descriptor.transport] ?: return
        val waking = link.capacity.toList(); link.capacity.clear()
        waking.forEach { it.complete(Unit) }
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
                link.remoteCapability = true
                link.remoteThreads = m.number(2).toInt().coerceIn(1, 50)
                link.remoteMessages = m.number(3).toInt().coerceIn(1, 50)
                flush(); return DataHandling.HANDLED
            }
            2L -> {
                if (!link.remoteCapability) return DataHandling.DISCARDED
                serveThreads(link, m.text(0))
                return DataHandling.HANDLED
            }
            5L -> {
                if (!link.remoteCapability) return DataHandling.DISCARDED
                serveHistory(link, m.text(0), m.text(1), m.number(2), m.text(3), m.number(4).toInt())
                return DataHandling.HANDLED
            }
            9L -> {
                val pending = pendingLive.firstOrNull { it.streamId == m.text(0) } ?: return DataHandling.DISCARDED
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

    private fun serveThreads(link: Link, requestId: String) {
        val k = key(link.channel.descriptor.peer)
        val current = servingThreads[k]
        if (current?.requestId == requestId && current.job?.isActive == true) return
        current?.job?.cancel()
        val job = scope.launch {
            val self = coroutineContext[Job]
            try {
                val deadline = now() + PAGE_DEADLINE
                var failed = false
                val page = try { store.threads(link.remoteThreads) } catch (e: CancellationException) { throw e } catch (_: Exception) { failed = true; null }
                if (page == null) { send(link, SmsWireMessage.of(4, text(requestId), number(if (failed) 5 else 1)), deadline); return@launch }
                skippedRows += page.skipped
                for (record in page.threads) {
                    val sent = send(link, SmsWireMessage.of(3, text(requestId), text(record.threadId), text(record.address), text(record.snippet), number(record.dateMillis), number(record.unreadCount)), deadline)
                    if (!sent) return@launch
                }
                send(link, SmsWireMessage.of(4, text(requestId), number(0)), deadline)
            } finally {
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
                val deadline = now() + PAGE_DEADLINE
                var failed = false
                val page = try { store.history(threadId, beforeMillis, beforeMessageId, minOf(limit, link.remoteMessages)) } catch (e: CancellationException) { throw e } catch (_: Exception) { failed = true; null }
                if (page == null) { send(link, SmsWireMessage.of(10, text(requestId), number(if (failed) 5 else 1), number(0), text("")), deadline); return@launch }
                skippedRows += page.skipped
                for (message in page.messages) {
                    val data = message.text.toByteArray(Charsets.UTF_8)
                    val digest = MessageDigest.getInstance("SHA-256").digest(data)
                    val count = (data.size + 3071) / 3072
                    val streamId = UUID.randomUUID().toString()
                    if (!send(link, SmsWireMessage.of(6, text(streamId), text(requestId), text(message.messageId), text(threadId), text(message.address), number(message.dateMillis), number(message.direction), flag(message.unread), number(data.size.toLong()), number(count.toLong()), data(digest)), deadline)) return@launch
                    for (index in 0 until count) {
                        val from = index * 3072
                        if (!send(link, SmsWireMessage.of(7, text(streamId), number(index.toLong()), data(data.copyOfRange(from, minOf(from + 3072, data.size)))), deadline)) return@launch
                    }
                    if (!send(link, SmsWireMessage.of(8, text(streamId)), deadline)) return@launch
                }
                send(link, SmsWireMessage.of(10, text(requestId), number(0), number(page.nextBeforeMillis), text(page.nextBeforeMessageId)), deadline)
            } finally {
                if (servingHistory[k]?.job == self) servingHistory.remove(k)
            }
        }
        servingHistory[k] = Serving(requestId, link.channel.descriptor, job)
    }

    private fun beginIncoming(link: Link, m: SmsWireMessage) {
        val k = key(link.channel.descriptor.peer)
        val requestId = m.text(0)
        val current = incomingReplies[k]
        if (current?.requestId == requestId) {
            if (current.address != m.text(2) || current.totalBytes != m.number(3).toInt() || current.count != m.number(4).toInt() || !current.digest.contentEquals(m.bytes(5))) {
                incomingReplies.remove(k)
                replyResult(link, requestId, 6, "", 0)
            }
            return
        }
        incomingReplies[k]?.job?.cancel()
        incomingReplies[k] = Incoming(requestId, m.text(2), m.number(3).toInt(), m.number(4).toInt(), m.bytes(5), now() + REPLY_DEADLINE)
        schedule()
    }

    private fun fragmentIncoming(link: Link, m: SmsWireMessage): Boolean {
        val k = key(link.channel.descriptor.peer)
        val current = incomingReplies[k]?.takeIf { it.requestId == m.text(0) } ?: return false
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
        val current = incomingReplies[k]?.takeIf { it.requestId == m.text(0) } ?: return false
        if (current.committing) return false
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
            if (incomingReplies[k] !== current) return@launch
            val outcome = try { sender.send(current.address, text) } catch (e: CancellationException) { throw e } catch (_: Exception) { SmsSendOutcome(5, "", 0) }
            // Only clear the slot when it still holds this request; a newer reply keeps its own tracking.
            if (incomingReplies[k] !== current) return@launch
            incomingReplies.remove(k)
            replyResult(link, current.requestId, outcome.result, outcome.messageId, outcome.dateMillis)
            if (outcome.result == 0L) {
                val row = SmsDisplayMessage(outcome.messageId.ifEmpty { "echo:" + UUID.randomUUID() }, current.address, outcome.dateMillis.takeIf { it > 0 } ?: System.currentTimeMillis(), 1, false, text, outcome.messageId.isEmpty())
                displayExtras += Extra(row, now() + EXTRAS_LIFETIME)
                refreshConversation()
                status = "Reply sent"
            } else if (outcome.result == 1L) {
                status = "SEND_SMS permission is required"
            } else {
                status = "Reply could not be sent"
            }
            schedule()
        }
        current.job = job
        return true
    }

    private fun replyResult(link: Link, requestId: String, result: Long, messageId: String, dateMillis: Long) {
        enqueue(link, SmsWireMessage.of(14, text(requestId), number(result), text(messageId), number(dateMillis)))
    }

    /** Hands parsed PDUs to the relay; [complete] fires with the first delivery attempt or after 8 seconds. */
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
            if (event.address.isEmpty() || text == null || bytes == null || bytes.isEmpty() || bytes.size > SmsWireMessage.MAX_BODY_BYTES) { skippedRows++; continue }
            val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            if (duplicate(event, digest)) continue
            marks += Mark(event.messageId, event.normalizedAddress, digest, event.dateMillis, now() + MARK_LIFETIME)
            if (pendingLive.size >= PENDING_LIVE_LIMIT) pendingLive.removeFirst().job?.cancel()
            val live = Live(event, now() + PENDING_LIVE_LIFETIME) { finish() }
            pendingLive.addLast(live)
            displayExtras += Extra(SmsDisplayMessage(event.messageId, event.address, event.dateMillis, 0, true, text, false), now() + PENDING_LIVE_LIFETIME)
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
        val snippet = text.take(160)
        val index = current.indexOfFirst { it.threadId == event.threadId || smsNormalizedAddress(it.address) == normalized }
        threads = if (index < 0) {
            current + SmsThreadRecord(event.threadId, event.address, snippet, event.dateMillis, 1)
        } else {
            current.toMutableList().also { list ->
                val row = list[index]
                list[index] = row.copy(snippet = snippet, dateMillis = maxOf(row.dateMillis, event.dateMillis), unreadCount = row.unreadCount + 1)
            }
        }
    }

    private fun duplicate(event: SmsLiveEvent, digest: ByteArray): Boolean {
        val time = now()
        marks.removeAll { it.expiry <= time }
        return marks.any { mark ->
            mark.messageId == event.messageId ||
                mark.address == event.normalizedAddress && mark.digest.contentEquals(digest) && kotlin.math.abs(mark.dateMillis - event.dateMillis) <= MERGE_TOLERANCE
        }
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
                if (live.acked.isCompleted || now() >= live.deadline) return@repeat
                val candidates = candidateLinks()
                if (candidates.isEmpty()) {
                    // No authenticated Mac advertises the relay, so the event stays parked for its retry window.
                    status = "Waiting for the Mac"
                    return@repeat
                }
                val link = candidates.firstOrNull { l -> live.attempted.none { it == l.channel.descriptor } } ?: return@repeat
                live.attempted.add(link.channel.descriptor)
                var transmitted = false
                try {
                    withTimeout(maxOf(1, live.deadline - now())) {
                        val bytes = live.event.body.toByteArray(Charsets.UTF_8)
                        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
                        val count = (bytes.size + 3071) / 3072
                        val begin = SmsWireMessage.of(6, text(live.streamId), text(""), text(live.event.messageId), text(live.event.threadId), text(live.event.address), number(live.event.dateMillis), number(0), flag(true), number(bytes.size.toLong()), number(count.toLong()), data(digest))
                        if (!send(link, begin, live.deadline)) throw CancellationException("SMS channel retired")
                        for (index in 0 until count) {
                            val from = index * 3072
                            if (!send(link, SmsWireMessage.of(7, text(live.streamId), number(index.toLong()), data(bytes.copyOfRange(from, minOf(from + 3072, bytes.size)))), live.deadline)) throw CancellationException("SMS channel retired")
                        }
                        if (!send(link, SmsWireMessage.of(8, text(live.streamId)), live.deadline)) throw CancellationException("SMS channel retired")
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
            val parked = !live.acked.isCompleted && now() < live.deadline
            if (parked) live.retryAt = now() + LIVE_RETRY_DELAY
            SmsTrace.log("live: ${if (live.acked.isCompleted) "delivered" else if (parked) "parked" else "lapsed"}")
            schedule()
        }
    }

    private fun enqueue(link: Link, message: SmsWireMessage) {
        if (!live(link.channel.descriptor) || link.queue.size >= QUEUE_LIMIT) return
        link.queue.addLast(message); pump(link)
    }

    private suspend fun send(link: Link, message: SmsWireMessage, deadline: Long): Boolean {
        while (live(link.channel.descriptor) && now() < deadline) {
            if (link.queue.size < QUEUE_LIMIT) { link.queue.addLast(message); pump(link); return true }
            val room = CompletableDeferred<Unit>(); link.room.add(room)
            try { withTimeout(maxOf(1, deadline - now())) { room.await() } }
            catch (_: TimeoutCancellationException) { return false }
            finally { link.room.remove(room) }
        }
        return false
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
                        try { link.channel.sendData(first.encode()) }
                        catch (_: SessionBackpressure) { break }
                        catch (e: CancellationException) { throw e }
                        catch (_: Exception) { link.queue.clear(); break }
                        if (link.queue.firstOrNull() === first) link.queue.removeFirst()
                        link.room.removeFirstOrNull()?.complete(Unit)
                    }
                } while (link.wake && live(link.channel.descriptor))
            } finally { link.sending = false }
        }
    }

    fun loadThreads() {
        scope.launch {
            loading = true
            try {
                val page = try { store.threads(PANEL_THREAD_LIMIT) } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
                if (page == null) status = "READ_SMS permission is required to load conversations"
                else {
                    skippedRows += page.skipped
                    threads = page.threads
                    status = if (page.threads.isEmpty()) "No conversations on this device" else "${page.threads.size} conversations"
                }
            } finally { loading = false }
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
        val generation = conversationGeneration
        conversationJob?.cancel()
        conversationJob = scope.launch {
            loading = true
            try {
                val page = try { store.history(threadId, cursor.first, cursor.second, DEFAULT_PAGE_SIZE) } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
                // Another thread was selected while this load ran: its rows and cursor must not land here.
                if (generation != conversationGeneration || selectedThreadId != threadId) return@launch
                if (page == null) status = "READ_SMS permission is required to load messages"
                else {
                    skippedRows += page.skipped
                    loadedRows = loadedRows + page.messages
                    loadedCursor = page.nextBeforeMillis to page.nextBeforeMessageId
                    conversationMore = page.more
                    refreshConversation()
                }
            } finally { if (generation == conversationGeneration) loading = false }
        }
    }

    fun send(address: String, text: String): SmsComposeOperation {
        val operation = SmsComposeOperation()
        val clean = smsSanitizeText(text)
        val bytes = clean?.toByteArray(Charsets.UTF_8)
        if (address.isEmpty() || clean.isNullOrEmpty() || bytes == null || bytes.size > SmsWireMessage.MAX_BODY_BYTES) {
            operation.completion.complete(SmsSendOutcome(6, "", 0)); status = "Message must be plain text up to 24 KiB"
            return operation
        }
        scope.launch {
            val outcome = try { sender.send(address, clean) } catch (_: Exception) { SmsSendOutcome(5, "", 0) }
            when (outcome.result) {
                0L -> {
                    displayExtras += Extra(SmsDisplayMessage(outcome.messageId.ifEmpty { "echo:" + UUID.randomUUID() }, address, outcome.dateMillis.takeIf { it > 0 } ?: System.currentTimeMillis(), 1, false, clean, outcome.messageId.isEmpty()), now() + EXTRAS_LIFETIME)
                    refreshConversation(); status = "Message sent"
                }
                1L -> status = "SEND_SMS permission is required"
                5L -> status = "Message could not be sent"
                else -> status = "Message rejected"
            }
            operation.completion.complete(outcome)
            schedule()
        }
        return operation
    }

    private fun refreshConversation() {
        val time = now()
        displayExtras.removeAll { it.expiry <= time }
        // With a thread open, only extras for that address render; another sender's row stays out of view.
        val selected = selectedThreadId
        val address = selected?.let { id -> threads?.firstOrNull { it.threadId == id }?.address } ?: loadedRows.firstOrNull()?.address
        // The provider record wins: a live copy or sent echo matching a provider row is hidden, never duplicated.
        val visible = displayExtras.map { it.row }
            .filter { selected == null || (address != null && smsNormalizedAddress(it.address) == smsNormalizedAddress(address)) }
            .filterNot { extra -> loadedRows.any { row -> sameContent(row.address, row.text, row.dateMillis, extra) } }
        conversation = (loadedRows.map { SmsDisplayMessage(it.messageId, it.address, it.dateMillis, it.direction, it.unread, it.text, false) } + visible).sortedWith { a, b ->
            val d = b.dateMillis.compareTo(a.dateMillis)
            if (d != 0) d else -smsCompareMessageIds(a.messageId, b.messageId)
        }
    }

    private fun sameContent(address: String, text: String, dateMillis: Long, extra: SmsDisplayMessage): Boolean {
        if (smsNormalizedAddress(address) != smsNormalizedAddress(extra.address)) return false
        if (kotlin.math.abs(dateMillis - extra.dateMillis) > MERGE_TOLERANCE) return false
        return MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).contentEquals(MessageDigest.getInstance("SHA-256").digest(extra.text.toByteArray(Charsets.UTF_8)))
    }

    fun expire() {
        val time = now()
        marks.removeAll { it.expiry <= time }
        displayExtras.removeAll { it.expiry <= time }
        val lapsed = pendingLive.count { !it.acked.isCompleted && it.deadline <= time }
        pendingLive.removeAll { it.acked.isCompleted || it.deadline <= time }
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
        val next = (marks.map { it.expiry } + displayExtras.map { it.expiry } + pendingLive.map { it.nextWake() } + incomingReplies.values.map { it.deadline }).minOrNull() ?: return
        timer = scope.launch { wait(maxOf(1, next - now())); expire() }
    }

    fun invalidate() {
        timer?.cancel(); timer = null
        servingThreads.values.forEach { it.job?.cancel() }; servingThreads.clear()
        servingHistory.values.forEach { it.job?.cancel() }; servingHistory.clear()
        pendingLive.forEach { it.job?.cancel() }; pendingLive.clear()
        incomingReplies.values.forEach { it.job?.cancel() }
        incomingReplies.clear(); marks.clear(); displayExtras.clear(); loadedRows = emptyList()
        relayedLive = 0; waitingLive = 0; failedLive = 0
        conversationJob?.cancel(); conversationGeneration++
        threads = null; selectedThreadId = null; conversation = emptyList(); conversationMore = false; loading = false
        links.values.toList().forEach { retired(it.channel.descriptor) }
    }

    companion object {
        const val PERMISSION_RECEIVE = "android.permission.RECEIVE_SMS"
        const val PERMISSION_READ = "android.permission.READ_SMS"
        const val PERMISSION_SEND = "android.permission.SEND_SMS"
        private const val QUEUE_LIMIT = 128
        private const val PAGE_DEADLINE = 30_000L
        private const val REPLY_DEADLINE = 30_000L
        private const val MARK_LIFETIME = 600_000L
        private const val PENDING_LIVE_LIMIT = 16
        private const val PENDING_LIVE_LIFETIME = 600_000L
        /** How long an unacknowledged live stream waits for its completion acknowledgement. */
        private const val LIVE_ACK_WAIT = 2_000L
        /** How soon a still-parked live event is offered again, until it is acknowledged or expires. */
        private const val LIVE_RETRY_DELAY = 5_000L
        private const val EXTRAS_LIFETIME = 600_000L
        /** First page shown when a conversation opens; the panel and the Mac offer older pages from its cursor. */
        private const val DEFAULT_PAGE_SIZE = 10
        /** The local panel lists its own conversations; the Mac's link cap governs what it is served. */
        private const val PANEL_THREAD_LIMIT = 50
        private const val MERGE_TOLERANCE = 5_000L
        private const val FAILURE_BOUND = 8_000L
    }
}
