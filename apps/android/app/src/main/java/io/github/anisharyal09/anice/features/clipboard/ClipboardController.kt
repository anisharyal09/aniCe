// SPDX-License-Identifier: GPL-3.0-or-later
// Serially owns bounded clipboard delivery, cross-transport deduplication and focused observation.
package io.github.anisharyal09.anice.features.clipboard

import androidx.compose.runtime.*
import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.UUID

class ClipboardController(
    private val native: NativeClipboard,
    val preferences: ClipboardPreferences = ClipboardPreferences(),
    dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
    private val now: () -> Long = android.os.SystemClock::elapsedRealtime,
    private val wait: suspend (Long) -> Unit = { delay(it) },
) : FeatureHandler {
    private class Link(val channel: SecuredChannel) {
        var epoch: String? by mutableStateOf(null)
        var announced by mutableStateOf(false)
        var remoteAutomatic = false
        var settingsRevision = 0L
        val queue = ArrayDeque<ClipboardMessage>()
        var sending = false
        var wake = false
        val capacity = mutableListOf<CompletableDeferred<Unit>>()
    }
    private class Incoming(val begin: ClipboardMessage, val baseline: String?, val deadline: Long) {
        val fragments = mutableListOf<ByteArray>()
        var committing = false
    }
    private data class Terminal(val begin: ClipboardMessage, val code: Long, val expiry: Long)
    private class History(var epoch: String) {
        var floor = 0L
        var incoming: Incoming? = null
        val terminal = linkedMapOf<String, Terminal>()
    }
    private class Outgoing(val peer: DeviceIdentity, val begin: ClipboardMessage, val data: ByteArray, val deadline: Long) {
        val attempted = mutableSetOf<ChannelDescriptor>()
        val result = CompletableDeferred<Long>()
        var channelLost = CompletableDeferred<Unit>()
        var job: Job? = null
    }
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val links = mutableStateMapOf<String, Link>()
    private val histories = mutableMapOf<String, History>()
    private val settingRevisions = mutableMapOf<String, Long>()
    private val epoch = UUID.randomUUID().toString()
    private var revision = 0L
    private var outgoing: Outgoing? = null
    private var pending: ClipboardSample? = null
    private var sampling = 0L
    private var preparingAutomatic = false
    private var timer: Job? = null
    private var observedToken: String? = null
    private var applying = false
    private var focused = false
    private var pendingFocusSample = false
    private val focusedWindows = mutableSetOf<Any>()
    var selected by mutableStateOf<DeviceIdentity?>(null); private set
    var busy by mutableStateOf(false); private set
    var automatic by mutableStateOf(false); private set
    var status by mutableStateOf("Ready to share text"); private set
    var preview by mutableStateOf<ClipboardSample?>(null); private set
    var onLanRequired: () -> Unit = {}
    fun connected(peer: DeviceIdentity) = links.values.any { key(it.channel.descriptor.peer) == key(peer) }
    fun supports(peer: DeviceIdentity) = candidates(peer).isNotEmpty()
    fun enabled(peer: DeviceIdentity) = preferences.enabled(peer)
    private fun key(peer: DeviceIdentity) = preferences.key(peer)
    private fun live(d: ChannelDescriptor) = links[d.transport]?.channel?.descriptor == d
    private fun candidates(peer: DeviceIdentity) = listOfNotNull(links["lan"], links["ble"]).filter { it.epoch != null && it.announced && key(it.channel.descriptor.peer) == key(peer) }
    fun select(peer: DeviceIdentity?) {
        if (selected?.let(::key) == peer?.let(::key)) return
        val firstSelectionFocus = selected == null && pendingFocusSample
        cancel(); selected = peer; automatic = peer?.let(preferences::enabled) ?: false
        pendingFocusSample = firstSelectionFocus
        preview = null; observedToken = null; updateObservation()
    }
    fun setAutomaticEnabled(value: Boolean) {
        val peer = selected ?: return
        preferences.set(peer, value); automatic = value
        pendingFocusSample = value && focused
        val k = key(peer); settingRevisions[k] = (settingRevisions[k] ?: 1) + 1
        links.values.filter { key(it.channel.descriptor.peer) == k }.forEach { settings(it) }
        if (!value) {
            if (preparingAutomatic || outgoing?.begin?.number(3) == 1L) cancel()
            pending = null
            histories[k]?.incoming?.takeIf { it.begin.number(3) == 1L }?.let { finishIncoming(k, it, 1, null) }
        }
        observedToken = null; updateObservation()
    }
    fun focus(value: Boolean, window: Any = this) {
        if (value) focusedWindows.add(window) else focusedWindows.remove(window)
        val active = focusedWindows.isNotEmpty()
        if (focused == active) return
        focused = active
        pendingFocusSample = active
        (native as? AndroidClipboard)?.focused = active
        if (!active) { preview = null; pending = null; if (preparingAutomatic) { sampling++; busy = false; preparingAutomatic = false } }
        updateObservation()
    }
    private fun updateObservation() {
        native.observe(focused && automatic && selected?.let(::supports) == true) { if (!applying) sampleAutomatic() }
        if (pendingFocusSample) sampleAutomatic()
    }
    private fun sampleAutomatic() {
        val peer = selected ?: return
        if (!focused || !automatic || !candidates(peer).any { it.remoteAutomatic }) return
        val sample = native.read()
        pendingFocusSample = false
        if (sample == null) return
        if (sample.token == observedToken) return
        observedToken = sample.token
        pending = null
        if (preparingAutomatic) { sampling++; busy = false; preparingAutomatic = false }
        if (sample.sensitive || sample.excluded) return
        submit(sample, true)
    }
    fun sendConfirmed(sample: ClipboardSample) { submit(sample, false) }
    fun clearPreview() { preview = null }
    fun inspect() { preview = native.read(); if (preview == null) status = "Focus aniCe and copy plain text, or paste text below" }
    fun send(confirmedSensitive: Boolean = false, pasted: String? = null) {
        val sample = if (pasted != null) ClipboardSample(pasted) else native.read()
        if (sample == null) { status = "Focus aniCe and copy plain text, or paste text below"; return }
        preview = sample
        if (sample.sensitive && !confirmedSensitive) { status = "Confirm sending sensitive text"; return }
        submit(sample, false)
    }
    private fun submit(sample: ClipboardSample, auto: Boolean) {
        val peer = selected ?: return
        if (candidates(peer).none { !auto || it.remoteAutomatic }) { status = "Connect first, or enable automatic sharing on both devices"; return }
        if (busy) { if (auto) pending = sample; return }
        if (auto && !focused) return
        if (sample.text.isEmpty() || sample.text.indexOf('\u0000') >= 0 || sample.text.length > 65536) { status = "Choose plain text up to 64 KiB"; return }
        busy = true; preparingAutomatic = auto; val generation = ++sampling
        scope.launch {
            val pair = withContext(Dispatchers.Default) {
                try {
                    val encoded = Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).encode(java.nio.CharBuffer.wrap(sample.text))
                    val bytes = ByteArray(encoded.remaining()).also(encoded::get)
                    bytes to MessageDigest.getInstance("SHA-256").digest(bytes)
                } catch (_: java.nio.charset.CharacterCodingException) { null }
            }
            if (generation != sampling || selected?.let(::key) != key(peer) || auto && !automatic) return@launch
            preparingAutomatic = false
            if (pair == null || pair.first.size !in 1..65536 || revision >= 4294967295L) { busy = false; status = "Choose plain text up to 64 KiB"; return@launch }
            val begin = ClipboardMessage.of(3, Cbor.Text(epoch), Cbor.Integer(++revision), Cbor.Text(UUID.randomUUID().toString()), Cbor.Integer(if (auto) 1 else 0), Cbor.Bool(sample.sensitive), Cbor.Integer(pair.first.size.toLong()), Cbor.Integer((pair.first.size + 3071L) / 3072), Cbor.Bytes(pair.second))
            val item = Outgoing(peer, begin, pair.first, now() + 30000)
            outgoing = item; status = "Sending to ${peer.deviceName}"; onLanRequired()
            item.job = scope.launch { deliver(item) }; schedule()
        }
    }
    override fun available(channel: SecuredChannel) {
        val d = channel.descriptor
        if (live(d)) return
        links[d.transport]?.let { retired(it.channel.descriptor) }
        val link = Link(channel); links[d.transport] = link
        enqueue(link, ClipboardMessage.of(1, Cbor.Text(epoch), Cbor.Integer(65536), Cbor.Integer(3072)))
        settings(link)
        if (selected == null) select(d.peer)
    }
    private fun settings(link: Link) {
        val peer = link.channel.descriptor.peer
        val rev = settingRevisions.getOrPut(key(peer)) { 1 }
        link.queue.removeAll { it.kind == 2L }
        enqueue(link, ClipboardMessage.of(2, Cbor.Integer(rev), Cbor.Bool(preferences.enabled(peer))))
    }
    override fun retired(descriptor: ChannelDescriptor) {
        if (!live(descriptor)) return
        val link = links.remove(descriptor.transport) ?: return
        val waking = link.capacity.toList(); link.capacity.clear(); waking.forEach { it.complete(Unit) }
        if (outgoing?.attempted?.contains(descriptor) == true) outgoing?.channelLost?.complete(Unit)
        val k = key(descriptor.peer)
        if (links.values.none { key(it.channel.descriptor.peer) == k }) {
            histories[k]?.incoming = null
            if (outgoing?.peer?.let(::key) == k) cancel()
            if (selected?.let(::key) == k) { pending = null; preview = null; sampling++; preparingAutomatic = false; busy = false }
        }
        updateObservation(); schedule()
    }
    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        if (!live(descriptor)) return
        val link = links[descriptor.transport] ?: return
        // Snapshot before resuming: a resumed send may immediately register its next capacity wait.
        val waking = link.capacity.toList(); link.capacity.clear(); waking.forEach { it.complete(Unit) }
        if (link.sending) link.wake = true else pump(link)
    }
    private suspend fun send(link: Link, message: ClipboardMessage, deadline: Long) {
        while (live(link.channel.descriptor) && now() < deadline) {
            try { link.channel.sendData(message.encode()); return }
            catch (_: SessionBackpressure) {
                val wake = CompletableDeferred<Unit>(); link.capacity.add(wake)
                try { withTimeout(maxOf(1, deadline - now())) { wake.await() } }
                finally { link.capacity.remove(wake) }
            }
        }
        throw CancellationException("Clipboard channel retired")
    }
    private suspend fun deliver(item: Outgoing) {
        try {
            repeat(2) {
                if (outgoing !== item || now() >= item.deadline) return@repeat
                val link = candidates(item.peer).firstOrNull { l -> item.attempted.none { it.transport == l.channel.descriptor.transport } && (item.begin.number(3) == 0L || l.remoteAutomatic) } ?: return@repeat
                item.channelLost = CompletableDeferred()
                item.attempted.add(link.channel.descriptor)
                try {
                    withTimeout(maxOf(1, item.deadline - now())) {
                        send(link, item.begin, item.deadline)
                        for (index in 0 until item.begin.number(6).toInt()) {
                            if (item.result.isCompleted || outgoing !== item) break
                            val start = index * 3072
                            send(link, ClipboardMessage.of(4, Cbor.Text(item.begin.text(2)), Cbor.Integer(index.toLong()), Cbor.Bytes(item.data.copyOfRange(start, minOf(start + 3072, item.data.size)))), item.deadline)
                        }
                        if (!item.result.isCompleted && outgoing === item) send(link, ClipboardMessage.id(5, item.begin.text(2)), item.deadline)
                        val timeout = async(start = CoroutineStart.UNDISPATCHED) { wait(minOf(2000, maxOf(1, item.deadline - now()))) }
                        try {
                            kotlinx.coroutines.selects.select<Unit> { item.result.onAwait { }; item.channelLost.onAwait { }; timeout.onAwait { } }
                        } finally { timeout.cancel() }
                    }
                } catch (e: CancellationException) { currentCoroutineContext().ensureActive() }
                  catch (_: Exception) { /* The same logical item can use its one alternate transport. */ }
                if (item.result.isCompleted) return
            }
        } finally {
            if (outgoing === item) {
                val code = if (item.result.isCompleted) item.result.await() else null
                status = when (code) { 0L -> "Clipboard delivered"; 1L -> "Automatic receiving is off on the other device"; 2L -> "Other device is busy"; 3L -> "Newer clipboard item already received"; 4L -> "Newer local copy kept"; 5L -> "Could not write the other clipboard"; 6L -> "Clipboard item rejected"; 7L -> "Clipboard send cancelled"; else -> "Delivery unconfirmed" }
                outgoing = null; busy = false; preview = null
                val next = pending; pending = null
                if (next != null && automatic && focused) submit(next, true)
                schedule()
            }
        }
    }
    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        val m = try { ClipboardMessage.decode(bytes) ?: return DataHandling.UNRECOGNIZED }
            catch (_: ClipboardWireException) { return DataHandling.DISCARDED }
            catch (_: SessionException) { return DataHandling.DISCARDED }
        expire()
        if (!live(descriptor)) return DataHandling.DISCARDED
        val link = links[descriptor.transport] ?: return DataHandling.DISCARDED
        val k = key(descriptor.peer)
        if (m.kind == 1L) {
            val old = histories[k]
            if (link.epoch != null && link.epoch != m.text(0)) return DataHandling.DISCARDED
            if (old != null && old.epoch != m.text(0)) {
                if (links.values.any { it !== link && key(it.channel.descriptor.peer) == k && it.epoch != null }) return DataHandling.DISCARDED
                old.epoch = m.text(0); old.floor = 0; old.incoming = null
            }
            link.epoch = m.text(0); if (old == null) histories[k] = History(m.text(0))
            updateObservation(); return DataHandling.HANDLED
        }
        if (link.epoch == null) return DataHandling.DISCARDED
        val h = histories[k] ?: return DataHandling.DISCARDED
        if (m.kind == 2L) {
            val newest = links.values.filter { key(it.channel.descriptor.peer) == k }.maxOf { it.settingsRevision }
            if (m.number(0) < newest || m.number(0) == newest && links.values.any { key(it.channel.descriptor.peer) == k && it.settingsRevision == newest && it.remoteAutomatic != m.flag(1) }) return DataHandling.DISCARDED
            links.values.filter { key(it.channel.descriptor.peer) == k }.forEach { it.settingsRevision = m.number(0); it.remoteAutomatic = m.flag(1) }
            updateObservation()
            return DataHandling.HANDLED
        }
        if (m.kind == 6L) {
            val o = outgoing ?: return DataHandling.DISCARDED
            if (key(o.peer) != k || o.begin.text(2) != m.text(0) || descriptor !in o.attempted) return DataHandling.DISCARDED
            o.result.complete(m.number(1)); return DataHandling.HANDLED
        }
        val id = m.text(if (m.kind == 3L) 2 else 0)
        h.terminal[id]?.let {
            if (m.kind == 3L && !it.begin.encode().contentEquals(m.encode())) { enqueue(link, ClipboardMessage.result(id, 6)); return DataHandling.DISCARDED }
            if (m.kind == 3L || m.kind == 5L) enqueue(link, ClipboardMessage.result(id, it.code))
            return DataHandling.HANDLED
        }
        if (m.kind == 3L) {
            if (h.incoming?.begin?.text(2) == id) {
                if (!h.incoming!!.begin.encode().contentEquals(m.encode())) { enqueue(link, ClipboardMessage.result(id, 6)); return DataHandling.DISCARDED }
                return DataHandling.HANDLED
            }
            val code = when { m.text(0) != h.epoch || m.number(1) <= h.floor -> 3L; m.number(3) == 1L && !preferences.enabled(descriptor.peer) -> 1L; h.incoming != null || h.terminal.size >= 32 -> 2L; else -> null }
            if (code != null) { enqueue(link, ClipboardMessage.result(id, code)); return DataHandling.HANDLED }
            h.floor = m.number(1); h.incoming = Incoming(m, native.token(), now() + 30000); schedule(); return DataHandling.HANDLED
        }
        val incoming = h.incoming?.takeIf { it.begin.text(2) == id } ?: return DataHandling.DISCARDED
        if (m.kind == 7L) { finishIncoming(k, incoming, 7, link); return DataHandling.HANDLED }
        if (incoming.committing) return DataHandling.DISCARDED
        if (m.kind == 4L) {
            val index = m.number(1).toInt(); val count = incoming.begin.number(6).toInt()
            val expected = if (index == count - 1) incoming.begin.number(5).toInt() - index * 3072 else 3072
            if (index >= count || m.bytes(2).size != expected || index > incoming.fragments.size || index < incoming.fragments.size && !incoming.fragments[index].contentEquals(m.bytes(2))) {
                finishIncoming(k, incoming, 6, link); return DataHandling.DISCARDED
            }
            if (index == incoming.fragments.size) incoming.fragments.add(m.bytes(2))
            return DataHandling.HANDLED
        }
        if (m.kind != 5L) return DataHandling.DISCARDED
        if (incoming.fragments.size != incoming.begin.number(6).toInt()) { finishIncoming(k, incoming, 6, link); return DataHandling.DISCARDED }
        incoming.committing = true
        val fragments = incoming.fragments.toList(); val digest = incoming.begin.bytes(7)
        val text = withContext(Dispatchers.Default) {
            val data = fragments.fold(java.io.ByteArrayOutputStream()) { out, fragment -> out.apply { write(fragment) } }.toByteArray()
            if (!MessageDigest.getInstance("SHA-256").digest(data).contentEquals(digest)) null
            else try { Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(data)).toString().takeIf { '\u0000' !in it } }
            catch (_: java.nio.charset.CharacterCodingException) { null }
        }
        if (histories[k]?.incoming !== incoming || now() >= incoming.deadline) { expire(); incoming.committing = false; return DataHandling.DISCARDED }
        val current = native.token()
        val code = when {
            text == null -> 6L
            incoming.begin.number(3) == 1L && !preferences.enabled(descriptor.peer) -> 1L
            incoming.baseline != null && current != null && current != incoming.baseline -> 4L
            else -> {
                applying = true
                try { if (native.write(text, incoming.begin.flag(4))) 0L else 5L }
                finally { applying = false }
            }
        }
        val responseLink = if (live(descriptor)) link else links.values.firstOrNull { key(it.channel.descriptor.peer) == k && it.epoch == h.epoch }
        finishIncoming(k, incoming, code, responseLink)
        return DataHandling.HANDLED
    }
    private fun finishIncoming(key: String, incoming: Incoming, code: Long, link: Link?) {
        val h = histories[key] ?: return
        if (h.incoming !== incoming) return
        h.incoming = null
        h.terminal[incoming.begin.text(2)] = Terminal(incoming.begin, code, now() + 60000)
        link?.let { enqueue(it, ClipboardMessage.result(incoming.begin.text(2), code)) }
        status = if (code == 0L) "Clipboard received" else "Incoming clipboard not applied"
        if (code == 0L) pending = null
        preview = null; schedule()
    }
    fun cancel() {
        sampling++; preparingAutomatic = false; pendingFocusSample = false; pending = null; preview = null
        val item = outgoing; outgoing = null; busy = false
        item?.job?.cancel()
        item?.attempted?.forEach { d -> links[d.transport]?.takeIf { live(d) }?.let { enqueue(it, ClipboardMessage.id(7, item.begin.text(2))) } }
        schedule()
    }
    fun invalidate() {
        cancel(); native.observe(false) {}; links.values.toList().forEach { retired(it.channel.descriptor) }; histories.clear(); preview = null; schedule()
    }
    fun prune(peers: List<DeviceIdentity>) {
        preferences.prune(peers)
        if (selected != null && peers.none { key(it) == key(selected!!) }) { select(null); automatic = false }
    }
    fun expire() {
        val time = now()
        histories.forEach { (k, h) ->
            h.terminal.entries.removeAll { it.value.expiry <= time }
            h.incoming?.takeIf { it.deadline <= time }?.let { finishIncoming(k, it, 7, null) }
        }
        histories.entries.removeAll { (k, h) -> h.terminal.isEmpty() && h.incoming == null && links.values.none { key(it.channel.descriptor.peer) == k } }
        if (outgoing?.deadline?.let { it <= time } == true) { cancel(); status = "Delivery unconfirmed" }
        schedule()
    }
    private fun schedule() {
        timer?.cancel(); timer = null
        val next = (histories.values.flatMap { h -> h.terminal.values.map { it.expiry } + listOfNotNull(h.incoming?.deadline) } + listOfNotNull(outgoing?.deadline)).minOrNull() ?: return
        timer = scope.launch { wait(maxOf(1, next - now())); expire() }
    }
    private fun enqueue(link: Link, message: ClipboardMessage) {
        if (!live(link.channel.descriptor) || link.queue.size >= 8) return
        link.queue.addLast(message); pump(link)
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
                        if (first.kind == 2L && !link.announced) { link.announced = true; updateObservation() }
                    }
                } while (link.wake && live(link.channel.descriptor))
            } finally { link.sending = false }
        }
    }
}
