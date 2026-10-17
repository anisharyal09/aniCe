// SPDX-License-Identifier: GPL-3.0-or-later
// Serially owns generation-bound Find Device requests, replay floors and native alert lifetimes.
package io.github.anisharyal09.anice.features.finddevice

import androidx.compose.runtime.*
import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*
import java.util.UUID

data class IncomingFindAlert(val identifier: String, val peerName: String)

interface FindDeviceNotifying {
    suspend fun post(identifier: String, peerName: String): FindResult
    fun clear(identifier: String)
}
class FindDeviceController(
    private val notifier: FindDeviceNotifying,
    dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
    private val now: () -> Long = android.os.SystemClock::elapsedRealtime,
    private val wait: suspend (Long) -> Unit = { delay(it) },
) : FeatureHandler {
    private class History {
        var processing: Long? = null
        var counter = 0L
        var highWater = 0L
        val results = linkedMapOf<Long, FindDeviceMessage>()
    }
    private class Link(val channel: SecuredChannel, val history: History) {
        var capable by mutableStateOf(false)
        val queue = ArrayDeque<Pair<FindDeviceMessage, Long>>()
        var sending = false
        var wake = false
    }
    private data class Pending(val descriptor: ChannelDescriptor, val message: FindDeviceMessage, val deadline: Long)
    private data class Alert(val descriptor: ChannelDescriptor, val identifier: String, val deadline: Long)
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val links = mutableStateMapOf<String, Link>()
    private var pending by mutableStateOf<Pending?>(null)
    private val alerts = mutableMapOf<String, Alert>()
    private var timer: Job? = null
    var incomingAlert by mutableStateOf<IncomingFindAlert?>(null); private set
    var feedbackKey by mutableStateOf("find_idle"); private set
    var feedbackPeer by mutableStateOf<DeviceIdentity?>(null); private set
    val connected get() = links.isNotEmpty()
    val compatible get() = links.values.any { it.capable }
    val busy get() = pending != null
    private fun peerKey(d: ChannelDescriptor) = d.peer.deviceId + ":" + d.peer.fingerprint
    private fun live(d: ChannelDescriptor) = links[d.transport]?.channel?.descriptor == d
    private fun selected(peer: DeviceIdentity) = sequenceOf("lan", "ble").mapNotNull { links[it] }.firstOrNull {
        it.capable && it.channel.descriptor.peer.deviceId == peer.deviceId && it.channel.descriptor.peer.fingerprint == peer.fingerprint
    }
    fun canFind(peer: DeviceIdentity) = !busy && selected(peer) != null
    override fun available(channel: SecuredChannel) {
        val d = channel.descriptor
        if (live(d)) return
        links[d.transport]?.let { retired(it.channel.descriptor) }
        // Coexisting transports share replay floors so channel changes cannot revive dismissed requests.
        val history = links.values.firstOrNull { peerKey(it.channel.descriptor) == peerKey(d) }?.history ?: History()
        val link = Link(channel, history); links[d.transport] = link
        enqueue(FindDeviceMessage(1), link)
    }
    override fun retired(descriptor: ChannelDescriptor) {
        if (!live(descriptor)) return
        links.remove(descriptor.transport)
        if (pending?.descriptor == descriptor) { pending = null; feedbackKey = "find_disconnected" }
        alerts.values.toList().filter { it.descriptor == descriptor }.forEach { dismiss(it.identifier) }
        schedule()
    }
    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        if (!live(descriptor)) return
        val link = links[descriptor.transport] ?: return
        if (link.sending) link.wake = true else pump(link)
    }
    fun find(peer: DeviceIdentity) {
        expire()
        val link = selected(peer) ?: return
        if (busy || link.history.counter >= 4294967295L || link.queue.size >= 8) return
        val message = FindDeviceMessage(2, UUID.randomUUID().toString(), ++link.history.counter)
        pending = Pending(link.channel.descriptor, message, now() + 10000)
        feedbackPeer = peer; feedbackKey = "find_waiting"; enqueue(message, link)
    }
    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        val message = try { FindDeviceMessage.decode(bytes) ?: return DataHandling.UNRECOGNIZED }
            catch (_: FindWireException) { return DataHandling.DISCARDED }
            catch (_: SessionException) { return DataHandling.DISCARDED }
        expire()
        if (!live(descriptor)) return DataHandling.DISCARDED
        val link = links[descriptor.transport] ?: return DataHandling.DISCARDED
        if (message.kind == 1L) { link.capable = true; return DataHandling.HANDLED }
        if (!link.capable) return DataHandling.DISCARDED
        if (message.kind == 3L) {
            val p = pending ?: return DataHandling.DISCARDED
            if (p.descriptor != descriptor || p.message.id != message.id || p.message.sequence != message.sequence) return DataHandling.DISCARDED
            pending = null
            feedbackKey = listOf("find_submitted", "find_blocked", "find_stale", "find_busy", "find_failed")[message.result.toInt()]
            schedule(); return DataHandling.HANDLED
        }
        if (link.history.processing == message.sequence) return DataHandling.HANDLED
        link.history.results[message.sequence]?.let {
            enqueue(if (it.id == message.id) it else reply(message, FindResult.STALE), link); return DataHandling.HANDLED
        }
        if (message.sequence <= link.history.highWater) { enqueue(reply(message, FindResult.STALE), link); return DataHandling.DISCARDED }
        link.history.highWater = message.sequence
        if (link.history.results.values.any { it.id == message.id }) { enqueue(reply(message, FindResult.STALE), link); return DataHandling.DISCARDED }
        if (link.queue.size >= 8) return DataHandling.DISCARDED
        // Reserve before suspension so duplicate in-flight requests never create another alert.
        remember(reply(message, FindResult.STALE), link)
        val key = peerKey(descriptor)
        if (alerts[key] != null || link.history.processing != null) { val response = reply(message, FindResult.BUSY); remember(response, link); enqueue(response, link); return DataHandling.HANDLED }
        val identifier = "find-device-" + UUID.randomUUID()
        alerts[key] = Alert(descriptor, identifier, now() + 60000)
        incomingAlert = IncomingFindAlert(identifier, descriptor.peer.deviceName); schedule()
        link.history.processing = message.sequence
        val result = try { notifier.post(identifier, descriptor.peer.deviceName) } finally { link.history.processing = null }
        expire()
        if (!live(descriptor) || alerts[key]?.identifier != identifier) {
            notifier.clear(identifier); return DataHandling.DISCARDED
        }
        if (result != FindResult.SUBMITTED) dismiss(identifier)
        val response = reply(message, result)
        remember(response, link); enqueue(response, link)
        return DataHandling.HANDLED
    }
    fun availableFor(peer: DeviceIdentity): Boolean = selected(peer) != null
    private fun reply(m: FindDeviceMessage, result: FindResult) = FindDeviceMessage(3, m.id, m.sequence, result.ordinal.toLong())
    private fun remember(result: FindDeviceMessage, link: Link) {
        link.history.results[result.sequence] = result
        if (link.history.results.size > 32) link.history.results.remove(link.history.results.keys.first())
    }
    fun dismiss(identifier: String) {
        val key = alerts.entries.firstOrNull { it.value.identifier == identifier }?.key ?: return
        alerts.remove(key)
        incomingAlert = alerts.values.lastOrNull()?.let { IncomingFindAlert(it.identifier, it.descriptor.peer.deviceName) }
        notifier.clear(identifier); schedule()
    }
    fun expire() {
        val time = now()
        pending?.takeIf { it.deadline <= time }?.let { p ->
            pending = null; feedbackKey = "find_timeout"
            links.values.forEach { it.queue.removeAll { item -> item.first == p.message } }
        }
        alerts.values.toList().filter { it.deadline <= time }.forEach { dismiss(it.identifier) }
        links.values.forEach { it.queue.removeAll { item -> item.second <= time } }
        schedule()
    }
    private fun schedule() {
        timer?.cancel(); timer = null
        val next = (alerts.values.asSequence().map { it.deadline } + sequenceOf(pending?.deadline).filterNotNull() + links.values.asSequence().flatMap { it.queue.asSequence().map { item -> item.second } }).minOrNull() ?: return
        timer = scope.launch { wait(maxOf(1, next - now())); expire() }
    }
    private fun enqueue(message: FindDeviceMessage, link: Link) {
        if (!live(link.channel.descriptor) || link.queue.size >= 8) return
        if (link.queue.none { it.first == message }) link.queue.addLast(message to (now() + 10000))
        schedule(); pump(link)
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
                        if (first.second <= now()) { link.queue.removeFirst(); continue }
                        try {
                            link.channel.sendData(first.first.encode())
                            if (!live(link.channel.descriptor)) return@launch
                            if (link.queue.firstOrNull()?.first == first.first) link.queue.removeFirst()
                        } catch (_: SessionBackpressure) { break }
                        catch (e: CancellationException) { throw e }
                        catch (_: Exception) {
                            if (pending?.descriptor == link.channel.descriptor) { pending = null; feedbackKey = "find_failed" }
                            link.queue.clear(); return@launch
                        }
                    }
                } while (link.wake && live(link.channel.descriptor))
            } finally { link.sending = false; schedule() }
        }
    }
}
