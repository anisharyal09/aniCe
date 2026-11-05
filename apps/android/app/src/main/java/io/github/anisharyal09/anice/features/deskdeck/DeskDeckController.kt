// SPDX-License-Identifier: GPL-3.0-or-later
// Owns the foreground Desk Deck subscription and peer-scoped commands.
package io.github.anisharyal09.anice.features.deskdeck

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import kotlinx.coroutines.*
import java.util.UUID

data class DeskDeckSnapshot(
    val sequence: Long,
    val cpuPercent: Long,
    val memoryUsed: Long,
    val memoryTotal: Long,
    val thermalState: Long,
    val actions: Long,
    val outputSupported: Boolean,
    val outputTarget: String,
    val outputRevision: String,
    val outputLevel: Long,
    val microphoneSupported: Boolean,
    val microphoneTarget: String,
    val microphoneRevision: String,
    val microphoneMuted: Boolean,
    val brightnessSupported: Boolean,
    val brightnessTarget: String,
    val brightnessRevision: String,
    val brightnessLevel: Long,
)

class DeskDeckController : FeatureHandler {
    private data class Intent(val action: Long, val value: Long, val target: String, val revision: String)
    private class Link(val channel: SecuredChannel) {
        var capable = false
        var actions = 0L
        var subscription = ""
        var lastSequence = 0L
        var commandId = 0L
    }

    private val links = mutableMapOf<String, Link>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var visible = false
    private var activeTransport: String? = null
    private var pendingCommand: Long? = null
    private var activeIntent: Intent? = null
    private var latestSliderIntent: Intent? = null
    private var previewIntent: Intent? = null
    var peer by mutableStateOf<DeviceIdentity?>(null); private set
    var snapshot by mutableStateOf<DeskDeckSnapshot?>(null); private set
    var status by mutableStateOf("Connect a Mac to open Desk Deck."); private set
    var feedback by mutableStateOf(""); private set
    var busy by mutableStateOf(false); private set
    var outputPreview by mutableStateOf<Long?>(null); private set
    var brightnessPreview by mutableStateOf<Long?>(null); private set

    fun connected(target: DeviceIdentity): Boolean = links.values.any { it.channel.descriptor.peer == target }
    fun supports(target: DeviceIdentity): Boolean = links.values.any { it.channel.descriptor.peer == target && it.capable }

    fun start(target: DeviceIdentity) {
        if (visible && peer == target) {
            subscribeBestChannel()
            return
        }
        stopSubscription()
        visible = true
        peer = target
        snapshot = null
        busy = false
        pendingCommand = null
        activeIntent = null
        latestSliderIntent = null
        previewIntent = null
        outputPreview = null
        brightnessPreview = null
        feedback = ""
        status = if (connected(target)) "Checking Mac support…" else "Connect to this Mac to use Desk Deck."
        subscribeBestChannel()
        if (connected(target) && !supports(target)) {
            scope.launch {
                delay(2500)
                if (visible && peer == target && !supports(target)) status = "Update aniCe on your Mac to use Desk Deck."
            }
        }
    }

    fun stop() {
        visible = false
        stopSubscription()
        peer = null
        snapshot = null
        busy = false
        pendingCommand = null
        activeIntent = null
        latestSliderIntent = null
        previewIntent = null
        outputPreview = null
        brightnessPreview = null
        feedback = ""
        status = "Desk Deck paused."
    }

    fun command(action: Long, value: Long = -1, target: String = "", revision: String = ""): Boolean {
        val link = activeTransport?.let(links::get) ?: return false
        val current = snapshot ?: return false
        if (action !in 1L..7L || link.subscription.isEmpty() || current.sequence == 0L) return false
        if ((action == 1L || action == 3L || action == 4L || action == 5L) && value != -1L) return false
        if (action == 2L && (!current.microphoneSupported || current.microphoneTarget != target || current.microphoneRevision != revision)) return false
        if (action == 2L && value !in 0L..1L) return false
        if (action == 6L && (!current.outputSupported || current.outputTarget != target || current.outputRevision != revision || value !in 0L..100L)) return false
        if (action == 7L && (!current.brightnessSupported || current.brightnessTarget != target || current.brightnessRevision != revision || value !in 0L..100L)) return false
        if (busy) {
            if (action !in 6L..7L) return false
            // Coalesce thumb changes while a write is in flight so stale slider values do not queue.
            latestSliderIntent = Intent(action, value, target, revision)
            setPreview(action, value)
            feedback = ""
            return true
        }
        if ((action == 1L && (current.actions and 1L) == 0L) || (action == 3L && (current.actions and 2L) == 0L) ||
            (action == 4L && (current.actions and 4L) == 0L) || (action == 5L && (current.actions and 8L) == 0L)) return false
        val intent = Intent(action, value, target, revision)
        return sendIntent(link, intent)
    }

    private fun sendIntent(link: Link, intent: Intent): Boolean {
        if (link.subscription.isEmpty() || link.commandId >= 4294967295L) return false
        val id = ++link.commandId
        val message = DeskDeckMessage(kind = 4, subscription = link.subscription, commandId = id,
            action = intent.action, target = intent.target, revision = intent.revision, value = intent.value)
        busy = true
        pendingCommand = id
        activeIntent = intent
        if (intent.action in 6L..7L) {
            previewIntent = intent
            setPreview(intent.action, intent.value)
        }
        feedback = ""
        status = "Sending control…"
        scope.launch {
            try {
                link.channel.sendData(message.encode())
                delay(6000)
                if (pendingCommand == id) {
                    pendingCommand = null
                    busy = false
                    activeIntent = null
                    latestSliderIntent = null
                    previewIntent = null
                    outputPreview = null
                    brightnessPreview = null
                    feedback = "No confirmation from Mac."
                }
            } catch (_: Exception) {
                if (pendingCommand == id) {
                    pendingCommand = null
                    busy = false
                    activeIntent = null
                    latestSliderIntent = null
                    previewIntent = null
                    outputPreview = null
                    brightnessPreview = null
                    feedback = "Mac connection changed."
                }
            }
        }
        return true
    }

    override fun available(channel: SecuredChannel) {
        val descriptor = channel.descriptor
        links[descriptor.transport] = Link(channel)
        if (visible && peer == descriptor.peer) {
            status = "Checking Mac support…"
            subscribeBestChannel()
        }
    }

    override fun retired(descriptor: ChannelDescriptor) {
        val link = links[descriptor.transport] ?: return
        if (link.channel.descriptor != descriptor) return
        links.remove(descriptor.transport)
        if (activeTransport == descriptor.transport) {
            activeTransport = null
            snapshot = null
            busy = false
            pendingCommand = null
            activeIntent = null
            latestSliderIntent = null
            previewIntent = null
            outputPreview = null
            brightnessPreview = null
            status = "Mac connection changed."
            if (visible) subscribeBestChannel()
        }
    }

    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        val link = links[descriptor.transport] ?: return
        if (link.channel.descriptor == descriptor && visible && peer == descriptor.peer && link.subscription.isEmpty()) subscribeBestChannel()
    }

    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        val link = links[descriptor.transport]?.takeIf { it.channel.descriptor == descriptor } ?: return DataHandling.DISCARDED
        val message = try { DeskDeckMessage.decode(bytes) ?: return DataHandling.UNRECOGNIZED }
            catch (_: DeskDeckWireException) { return DataHandling.DISCARDED }
            catch (_: Exception) { return DataHandling.DISCARDED }
        if (message.kind == 1L) {
            link.capable = true
            link.actions = message.actions
            if (visible && peer == descriptor.peer) subscribeBestChannel()
            return DataHandling.HANDLED
        }
        if (!visible || peer != descriptor.peer || activeTransport != descriptor.transport || message.subscription != link.subscription) return DataHandling.DISCARDED
        if (message.kind == 3L) {
            if (message.sequence <= link.lastSequence) return DataHandling.DISCARDED
            link.lastSequence = message.sequence
            link.capable = true
            link.actions = message.actions
            snapshot = DeskDeckSnapshot(message.sequence, message.cpuPercent, message.memoryUsed, message.memoryTotal,
                message.thermalState, message.actions, message.outputSupported, message.outputTarget, message.outputRevision,
                message.outputLevel, message.microphoneSupported, message.microphoneTarget, message.microphoneRevision,
                message.microphoneMuted, message.brightnessSupported, message.brightnessTarget, message.brightnessRevision,
                message.brightnessLevel)
            reconcileSlider(6, message.outputSupported, message.outputTarget, message.outputRevision, message.outputLevel)
            reconcileSlider(7, message.brightnessSupported, message.brightnessTarget, message.brightnessRevision, message.brightnessLevel)
            if (!busy) status = "Live · ${descriptor.peer.deviceName}"
            return DataHandling.HANDLED
        }
        if (message.kind == 5L && pendingCommand == message.commandId) {
            val completed = activeIntent
            pendingCommand = null
            busy = false
            activeIntent = null
            status = "Live · ${descriptor.peer.deviceName}"
            feedback = when {
                message.result == 0L -> when (completed?.action) {
                    1L -> "Mac lock requested."
                    2L -> if (completed?.value == 1L) "Default microphone muted." else "Default microphone unmuted."
                    3L -> "Blender launched."
                    4L -> "Terminal launched."
                    5L -> "Area capture opened on Mac."
                    6L -> "Mac output volume updated."
                    7L -> "Mac display brightness updated."
                    else -> "Done"
                }
                message.result == 1L -> "Control changed. Refreshing…"
                message.result == 2L -> "Control is unsupported on this Mac."
                message.result == 3L -> "Mac permission is needed."
                message.result == 4L -> "Mac denied the action."
                message.result == 5L -> "Control is unavailable."
                message.result == 6L -> "Mac is busy."
                else -> "Mac action failed."
            }
            if (message.result == 0L) {
                val queued = latestSliderIntent
                latestSliderIntent = null
                if (queued != null) {
                    val state = snapshot
                    val matches = when (queued.action) {
                        6L -> state?.outputSupported == true && state.outputTarget == queued.target && state.outputRevision == queued.revision
                        7L -> state?.brightnessSupported == true && state.brightnessTarget == queued.target && state.brightnessRevision == queued.revision
                        else -> false
                    }
                    if (matches) {
                        val level = if (queued.action == 6L) state!!.outputLevel else state!!.brightnessLevel
                        if (level != queued.value) sendIntent(link, queued)
                        else { previewIntent = null; setPreview(queued.action, null) }
                    } else { previewIntent = null; setPreview(queued.action, null); feedback = "Control target changed." }
                } else {
                    previewIntent = null
                    completed?.action?.let { if (it in 6L..7L) setPreview(it, null) }
                }
            } else {
                latestSliderIntent = null
                previewIntent = null
                outputPreview = null
                brightnessPreview = null
            }
            return DataHandling.HANDLED
        }
        return DataHandling.DISCARDED
    }

    private fun subscribeBestChannel() {
        if (!visible) return
        val target = peer ?: return
        val best = links.values.filter { it.channel.descriptor.peer == target }
            .maxByOrNull { (if (it.capable) 2 else 0) + (if (it.channel.descriptor.transport == "lan") 1 else 0) }
        if (best == null) {
            activeTransport = null
            if (connected(target)) status = "Checking Mac support…" else status = "Connect to this Mac to use Desk Deck."
            return
        }
        if (activeTransport == best.channel.descriptor.transport && best.subscription.isNotEmpty()) return
        stopSubscription()
        val subscription = UUID.randomUUID().toString()
        best.subscription = subscription
        best.lastSequence = 0
        best.commandId = 0
        activeTransport = best.channel.descriptor.transport
        snapshot = null
        status = "Opening Desk Deck…"
        scope.launch {
            try { best.channel.sendData(DeskDeckMessage(kind = 2, subscription = subscription).encode()) }
            catch (_: Exception) {
                if (activeTransport == best.channel.descriptor.transport && best.subscription == subscription) {
                    best.subscription = ""
                    activeTransport = null
                    status = "Mac connection changed."
                }
            }
        }
    }

    private fun stopSubscription() {
        val transport = activeTransport
        val link = transport?.let(links::get)
        val subscription = link?.subscription.orEmpty()
        if (link != null && subscription.isNotEmpty()) {
            link.subscription = ""
            scope.launch { try { link.channel.sendData(DeskDeckMessage(kind = 6, subscription = subscription).encode()) } catch (_: Exception) { } }
        }
        activeTransport = null
    }

    private fun reconcileSlider(action: Long, supported: Boolean, target: String, revision: String, level: Long) {
        val queued = latestSliderIntent?.takeIf { it.action == action }
        val desired = queued ?: previewIntent?.takeIf { it.action == action }
        if (desired == null) { setPreview(action, null); return }
        if (!supported || desired.target != target || desired.revision != revision) {
            if (queued != null) latestSliderIntent = null
            if (previewIntent?.action == action) previewIntent = null
            setPreview(action, null)
            feedback = "Control target changed."
        } else if (desired.value == level) {
            if (queued != null) latestSliderIntent = null
            if (previewIntent == desired) previewIntent = null
            setPreview(action, null)
        } else setPreview(action, desired.value)
    }

    private fun setPreview(action: Long, value: Long?) {
        if (action == 6L) outputPreview = value
        if (action == 7L) brightnessPreview = value
    }
}
