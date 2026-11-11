// SPDX-License-Identifier: GPL-3.0-or-later
// Owns the foreground Desk Deck subscription and peer-scoped commands.
package io.github.anisharyal09.anice.features.deskdeck

import android.os.SystemClock
import android.content.SharedPreferences
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import kotlinx.coroutines.*
import org.json.JSONObject
import java.util.UUID

enum class DeskDeckConnectionState { DISCONNECTED, OPENING, LIVE, STALE, FAILED }

data class DeskDeckHistoryPoint(val elapsedMillis: Long, val cpuPercent: Int?, val memoryPercent: Int?)

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
    val memoryActive: Long = -1,
    val memoryWired: Long = -1,
    val memoryCompressed: Long = -1,
    val powerState: Long = 0,
    val powerPercent: Long = -1,
    val powerSource: Long = 0,
    val receivedAtMillis: Long = SystemClock.elapsedRealtime(),
    val protocolVersion: Long = 1,
    val memoryApp: Long = -1,
    val memoryCached: Long = -1,
    val memoryFree: Long = -1,
    val memorySwap: Long = -1,
    val outputRouteID: String = "",
    val receivedAtWallMillis: Long = System.currentTimeMillis(),
)

class DeskDeckController(
    dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
    private val clock: () -> Long = SystemClock::elapsedRealtime,
    private val wait: suspend (Long) -> Unit = { delay(it) },
    private val shortcutPreferences: SharedPreferences? = null,
    private val snapshotPreferences: SharedPreferences? = null,
) : FeatureHandler {
    private data class Intent(val action: Long, val value: Long, val target: String, val revision: String)
    private data class PendingCommand(
        val generation: Long,
        val descriptor: ChannelDescriptor,
        val subscription: String,
        val intent: Intent,
        val requestedAtMillis: Long,
    )

    private class Link(val channel: SecuredChannel) {
        var capable = false
        var protocolVersion = 1L
        var actions = 0L
        var subscription = ""
        var lastSequence = 0L
        var commandId = 0L
        var catalogRevision = ""
        var catalogPageCount = 0L
        val catalogPages = mutableMapOf<Long, List<DeskDeckShortcut>>()
        val requestedCatalogPages = mutableSetOf<Long>()
        val pendingCatalogRetries = mutableSetOf<Long>()
        var shortcuts = emptyList<DeskDeckShortcut>()
        var outputCatalogRevision = ""
        var outputCatalogPageCount = 0L
        val outputCatalogPages = mutableMapOf<Long, List<DeskDeckOutputRoute>>()
        val requestedOutputCatalogPages = mutableSetOf<Long>()
        val pendingOutputCatalogRetries = mutableSetOf<Long>()
        var outputRoutes = emptyList<DeskDeckOutputRoute>()
    }

    private val links = mutableMapOf<String, Link>()
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private var visible = false
    private var activeTransport: String? = null
    private var generation = 0L
    private var autoRetryUsed = false
    private var openingJob: Job? = null
    private var openingTimeoutJob: Job? = null
    private var freshnessJob: Job? = null
    private var renewalJob: Job? = null
    private val submissionJobs = mutableMapOf<Long, Job>()
    private val timeoutJobs = mutableMapOf<Long, Job>()
    private val pendingCommands = mutableMapOf<Long, PendingCommand>()
    private val latestSliderIntents = mutableMapOf<Long, Intent>()
    private val previewIntents = mutableMapOf<Long, Intent>()
    private var snapshotPeerFingerprint: String? = null
    private var lastSnapshotCacheWriteMillis: Long? = null
    private var deckOpenedAtMillis = 0L
    private var firstSampleLogged = false

    var peer by mutableStateOf<DeviceIdentity?>(null); private set
    var snapshot by mutableStateOf<DeskDeckSnapshot?>(null); private set
    private val connectionStateState = mutableStateOf(DeskDeckConnectionState.DISCONNECTED)
    var connectionState: DeskDeckConnectionState
        get() = connectionStateState.value
        private set(value) {
            if (connectionStateState.value != value) {
                timing("event=state_transition state=${value.name.lowercase()}")
                connectionStateState.value = value
            }
        }
    var status by mutableStateOf("Connect a Mac to open Desk Deck."); private set
    var feedback by mutableStateOf(""); private set
    private var actionFeedbackValues by mutableStateOf<Map<Long, String>>(emptyMap())
    private var shortcutFeedbackValues by mutableStateOf<Map<String, String>>(emptyMap())
    var busy by mutableStateOf(false); private set
    var outputPreview by mutableStateOf<Long?>(null); private set
    var brightnessPreview by mutableStateOf<Long?>(null); private set
    var history by mutableStateOf<List<DeskDeckHistoryPoint>>(emptyList()); private set
    var shortcuts by mutableStateOf<List<DeskDeckShortcut>>(emptyList()); private set
    var outputRoutes by mutableStateOf<List<DeskDeckOutputRoute>>(emptyList()); private set
    var outputCatalogLoaded by mutableStateOf(false); private set
    var outputCatalogLoading by mutableStateOf(false); private set
    var pinnedShortcutIDs by mutableStateOf<Set<String>>(emptySet()); private set

    init { restoreCachedSnapshot() }

    fun connected(target: DeviceIdentity): Boolean = links.values.any { it.channel.descriptor.peer == target }
    fun supports(target: DeviceIdentity): Boolean = links.values.any { it.channel.descriptor.peer == target && it.capable }
    fun usesLegacyShortcuts(target: DeviceIdentity): Boolean = links.values.any {
        it.channel.descriptor.peer == target && it.protocolVersion == 1L && it.capable
    }
    fun activeTransportLabel(): String = when (activeLink()?.channel?.descriptor?.transport) {
        "lan" -> "Local network"
        "ble" -> "Bluetooth"
        else -> "Unavailable"
    }
    fun isBusy(action: Long): Boolean = pendingCommands.values.any { it.intent.action == action }
    fun actionFeedback(action: Long): String = actionFeedbackValues[action].orEmpty()
    fun shortcutFeedback(id: String): String = shortcutFeedbackValues[id].orEmpty()
    fun isShortcutBusy(id: String): Boolean = pendingCommands.values.any { it.intent.action == 8L && it.intent.target == id }

    fun setShortcutPinned(fingerprint: String, id: String, pinned: Boolean) {
        val key = "pinned.$fingerprint"
        val saved = shortcutPreferences?.getString(key, null)
        val ids = (saved?.split(',')?.filter(String::isNotEmpty)?.toMutableSet()
            ?: shortcuts.take(4).mapTo(mutableSetOf()) { it.id })
        if (pinned) ids.add(id) else ids.remove(id)
        shortcutPreferences?.edit()?.putString(key, ids.joinToString(","))?.apply()
        activeLink()?.let { applyShortcutLayout(it, fingerprint) }
    }

    fun moveShortcut(fingerprint: String, id: String, direction: Int) {
        val ids = (orderedShortcutIDs(fingerprint).ifEmpty { shortcuts.map { it.id } }).toMutableList()
        val from = ids.indexOf(id)
        val to = from + direction.coerceIn(-1, 1)
        if (from < 0 || to !in ids.indices) return
        ids.add(to, ids.removeAt(from))
        shortcutPreferences?.edit()?.putString("order.$fingerprint", ids.joinToString(","))?.apply()
        activeLink()?.let { applyShortcutLayout(it, fingerprint) }
    }

    fun launchShortcut(id: String): Boolean {
        val link = activeLink() ?: return false
        return command(8, target = id, revision = link.catalogRevision)
    }
    fun selectOutputRoute(id: String): Boolean {
        val link = activeLink() ?: return false
        return command(10, target = id, revision = link.outputCatalogRevision)
    }
    fun refreshOutputRoutes(): Boolean {
        val link = activeLink() ?: return false
        if (link.protocolVersion < 5L || link.subscription.isEmpty()) return false
        link.outputCatalogRevision = ""
        link.outputCatalogPageCount = 0
        link.outputCatalogPages.clear()
        link.requestedOutputCatalogPages.clear()
        link.pendingOutputCatalogRetries.clear()
        link.outputRoutes = emptyList()
        outputRoutes = emptyList()
        outputCatalogLoaded = false
        outputCatalogLoading = true
        requestOutputCatalogPage(link, 0)
        return true
    }
    fun selectedOutputName(sample: DeskDeckSnapshot?): String =
        outputRoutes.firstOrNull { it.id == sample?.outputRouteID }?.name ?: "Unavailable"
    val readingsAreFresh: Boolean
        get() = connectionState == DeskDeckConnectionState.LIVE &&
            snapshot?.let { clock() - it.receivedAtMillis < STALE_AFTER_MILLIS } == true

    fun start(target: DeviceIdentity) {
        if (visible && peer == target) {
            if (activeLink() == null) subscribeBestChannel()
            return
        }
        stopSubscription(sendStop = true)
        visible = true
        deckOpenedAtMillis = clock()
        firstSampleLogged = false
        timing("event=deck_shell_open")
        val peerChanged = snapshotPeerFingerprint != target.fingerprint
        peer = target
        if (peerChanged) {
            snapshot = null
            history = emptyList()
            shortcuts = emptyList()
            outputRoutes = emptyList()
            outputCatalogLoaded = false
            outputCatalogLoading = false
            pinnedShortcutIDs = emptySet()
            snapshotPeerFingerprint = target.fingerprint
            actionFeedbackValues = emptyMap()
            shortcutFeedbackValues = emptyMap()
            clearCachedSnapshot()
        }
        feedback = ""
        autoRetryUsed = false
        if (snapshot != null) {
            connectionState = DeskDeckConnectionState.STALE
            status = "Reconnecting to Mac…"
        } else {
            connectionState = DeskDeckConnectionState.OPENING
            status = if (connected(target)) "Opening Desk Deck…" else "Connect to this Mac to use Desk Deck."
        }
        subscribeBestChannel()
    }

    fun retainTrustedPeers(fingerprints: Set<String>) {
        shortcutPreferences?.let { preferences ->
            val obsolete = preferences.all.keys.filter { key ->
                (key.startsWith("pinned.") || key.startsWith("order.")) && key.substringAfter('.') !in fingerprints
            }
            if (obsolete.isNotEmpty()) preferences.edit().also { editor -> obsolete.forEach(editor::remove) }.apply()
        }
        val cachedPeer = snapshotPeerFingerprint ?: return
        if (cachedPeer in fingerprints) return
        stopSubscription(sendStop = true)
        snapshotPeerFingerprint = null
        snapshot = null
        clearCachedSnapshot()
        history = emptyList()
        shortcuts = emptyList()
        outputRoutes = emptyList()
        outputCatalogLoaded = false
        outputCatalogLoading = false
        pinnedShortcutIDs = emptySet()
        actionFeedbackValues = emptyMap()
        shortcutFeedbackValues = emptyMap()
        feedback = ""
        peer = null
        connectionState = DeskDeckConnectionState.DISCONNECTED
        status = "Pair a Mac to use Desk Deck."
    }

    fun stop() {
        visible = false
        persistCachedSnapshot(force = true)
        if (snapshot != null) addHistoryGap()
        stopSubscription(sendStop = true)
        peer = null
        connectionState = if (snapshot == null) DeskDeckConnectionState.DISCONNECTED else DeskDeckConnectionState.STALE
        status = if (snapshot == null) "Desk Deck paused." else "Last reading · paused"
    }

    /** Starts a new read-only subscription. It never resends a control. */
    fun refresh() {
        val link = activeLink()
        if (!visible || link == null) {
            subscribeBestChannel()
            return
        }
        autoRetryUsed = false
        beginSubscription(link)
    }

    fun command(action: Long, value: Long = -1, target: String = "", revision: String = ""): Boolean {
        val link = activeLink() ?: return false
        val current = snapshot ?: return false
        if (!readingsAreFresh || link.subscription.isEmpty() || current.sequence == 0L) return false
        if (action !in 1L..10L || action == 7L || action == 8L && link.protocolVersion < 2L ||
            action == 9L && link.protocolVersion < 4L ||
            action == 10L && link.protocolVersion < 5L ||
            action in 3L..4L && link.protocolVersion != 1L) return false
        if ((action == 1L || action in 3L..5L || action == 9L || action == 10L) && value != -1L) return false
        if (action == 2L && (!current.microphoneSupported || current.microphoneTarget != target || current.microphoneRevision != revision)) return false
        if (action == 2L && value !in 0L..1L) return false
        if (action == 6L && (!current.outputSupported || current.outputTarget != target || current.outputRevision != revision || value !in 0L..100L)) return false
        if (action == 8L && (value != -1L || revision != link.catalogRevision || link.shortcuts.none { it.id == target })) return false
        if (action == 10L && (current.protocolVersion < 5L || current.actions and 32L == 0L ||
                revision != link.outputCatalogRevision || link.outputRoutes.none { it.id == target })) return false
        if ((action in setOf(1L, 3L, 4L, 5L) || action == 9L) &&
            (current.actions and actionBit(action)) == 0L) return false

        val intent = Intent(action, value, target, revision)
        if (pendingCommands.values.any { it.intent.action == action }) {
            when (action) {
                6L -> {
                    latestSliderIntents[action] = intent
                    outputPreview = value
                    setActionFeedback(action, "Updating…")
                    return true
                }
                8L -> if (pendingCommands.values.any { it.intent.target == target }) return false
                else -> return false
            }
        }
        return sendIntent(link, intent)
    }

    val shortcutCatalogLoaded: Boolean get() = activeLink()?.let {
        it.catalogPageCount > 0 && it.catalogPages.size.toLong() == it.catalogPageCount
    } == true

    private fun sendIntent(link: Link, intent: Intent): Boolean {
        val subscription = link.subscription
        val descriptor = link.channel.descriptor
        if (subscription.isEmpty() || link.commandId >= MAX_ID || !isCurrent(descriptor, subscription, generation)) return false
        val id = ++link.commandId
        val command = DeskDeckMessage(kind = 4, subscription = subscription, commandId = id,
            version = link.protocolVersion, action = intent.action, target = intent.target, revision = intent.revision, value = intent.value)
        val pending = PendingCommand(generation, descriptor, subscription, intent, clock())
        pendingCommands[id] = pending
        val submissionStarted = clock()
        busy = true
        if (intent.action == 6L) {
            previewIntents[intent.action] = intent
            outputPreview = intent.value
        }
        setActionFeedback(intent.action, "Sending…")
        if (intent.action == 8L) setShortcutFeedback(intent.target, "Launching…")
        feedback = ""
        val submission = scope.launch(start = CoroutineStart.LAZY) {
            try {
                link.channel.sendData(command.encode())
                timing("event=command_submitted action=${intent.action} duration_ms=${clock() - submissionStarted}")
                if (pendingCommands[id] != pending || !isCurrent(descriptor, subscription, pending.generation)) return@launch
            } catch (_: CancellationException) {
                return@launch
            } catch (_: Exception) {
                if (pendingCommands[id] == pending) finishCommand(id, pending, "Mac connection changed before the request was sent.")
            } finally {
                submissionJobs.remove(id)
            }
        }
        submissionJobs[id] = submission
        val timeout = scope.launch(start = CoroutineStart.LAZY) {
            wait(COMMAND_TIMEOUT_MILLIS)
            if (pendingCommands[id] == pending && isCurrent(descriptor, subscription, pending.generation)) {
                val message = if (submission.isActive) {
                    "Request timed out before submission was confirmed. Check the Mac before trying again."
                } else {
                    "Request unconfirmed. Check the Mac before trying again."
                }
                finishCommand(id, pending, message)
            }
        }
        timeoutJobs[id] = timeout
        timeout.start()
        submission.start()
        return true
    }

    override fun available(channel: SecuredChannel) {
        val descriptor = channel.descriptor
        links[descriptor.transport] = Link(channel)
        if (visible && peer == descriptor.peer && activeLink() == null) subscribeBestChannel()
    }

    override fun retired(descriptor: ChannelDescriptor) {
        val link = links[descriptor.transport] ?: return
        if (link.channel.descriptor != descriptor) return
        links.remove(descriptor.transport)
        if (activeTransport == descriptor.transport) {
            if (snapshot != null) addHistoryGap()
            stopSubscription(sendStop = false)
            connectionState = if (snapshot == null) DeskDeckConnectionState.FAILED else DeskDeckConnectionState.STALE
            status = "Mac connection changed."
            if (visible) subscribeBestChannel()
        }
    }

    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        val link = links[descriptor.transport] ?: return
        if (link.channel.descriptor == descriptor && visible && peer == descriptor.peer && activeLink() == null) {
            subscribeBestChannel()
        } else if (link.channel.descriptor == descriptor && visible && activeTransport == descriptor.transport &&
            link.protocolVersion >= 2L && link.subscription.isNotEmpty()) {
            link.pendingCatalogRetries.toList().forEach { page ->
                link.pendingCatalogRetries.remove(page)
                requestCatalogPage(link, page)
            }
            val pageCount = link.catalogPageCount.coerceAtLeast(1L)
            for (page in 0 until pageCount) {
                if (page !in link.catalogPages && page !in link.requestedCatalogPages) requestCatalogPage(link, page)
            }
            link.pendingOutputCatalogRetries.toList().forEach { page ->
                link.pendingOutputCatalogRetries.remove(page)
                requestOutputCatalogPage(link, page)
            }
            if (link.protocolVersion >= 5L) {
                val outputPageCount = link.outputCatalogPageCount.coerceAtLeast(1L)
                for (page in 0 until outputPageCount) {
                    if (page !in link.outputCatalogPages && page !in link.requestedOutputCatalogPages) requestOutputCatalogPage(link, page)
                }
            }
        }
    }

    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        val link = links[descriptor.transport]?.takeIf { it.channel.descriptor == descriptor } ?: return DataHandling.DISCARDED
        val message = try { DeskDeckMessage.decode(bytes) ?: return DataHandling.UNRECOGNIZED }
            catch (_: DeskDeckWireException) { return DataHandling.DISCARDED }
            catch (_: Exception) { return DataHandling.DISCARDED }
        if (message.kind == 1L) {
            val previousVersion = link.protocolVersion
            link.capable = true
            link.protocolVersion = maxOf(link.protocolVersion, message.version)
            if (message.version >= previousVersion) link.actions = message.actions
            if (visible && peer == descriptor.peer) {
                if (activeTransport == descriptor.transport && link.subscription.isEmpty()) beginSubscription(link)
                else if (activeTransport == descriptor.transport && link.subscription.isNotEmpty() && link.protocolVersion > previousVersion) beginSubscription(link)
                else if (activeLink() == null) subscribeBestChannel()
            }
            return DataHandling.HANDLED
        }
        if (!visible || peer != descriptor.peer || activeTransport != descriptor.transport || message.subscription != link.subscription || message.version != link.protocolVersion) return DataHandling.DISCARDED
        if (message.kind == 3L) {
            if (message.sequence <= link.lastSequence) return DataHandling.DISCARDED
            link.lastSequence = message.sequence
            link.capable = true
            link.actions = message.actions
            snapshot = DeskDeckSnapshot(message.sequence, message.cpuPercent, message.memoryUsed, message.memoryTotal,
                message.thermalState, message.actions, message.outputSupported, message.outputTarget, message.outputRevision,
                message.outputLevel, message.microphoneSupported, message.microphoneTarget, message.microphoneRevision,
                message.microphoneMuted, message.brightnessSupported, message.brightnessTarget, message.brightnessRevision,
                message.brightnessLevel, message.memoryActive, message.memoryWired, message.memoryCompressed,
                message.powerState, message.powerPercent, message.powerSource, clock(), message.version,
                message.memoryApp, message.memoryCached, message.memoryFree, message.memorySwap, message.outputRouteID,
                receivedAtWallMillis = System.currentTimeMillis())
            persistCachedSnapshot()
            history = (history + DeskDeckHistoryPoint(clock(), message.cpuPercent.takeIf { it >= 0 }?.toInt(),
                if (message.memoryTotal > 0 && message.memoryUsed >= 0) (message.memoryUsed * 100 / message.memoryTotal).toInt() else null)).takeLast(HISTORY_LIMIT)
            if (!firstSampleLogged) {
                firstSampleLogged = true
                timing("event=first_sample total_ms=${clock() - deckOpenedAtMillis}")
            }
            reconcileOutputSlider(message.outputSupported, message.outputTarget, message.outputRevision, message.outputLevel)
            connectionState = DeskDeckConnectionState.LIVE
            status = "Live · ${descriptor.peer.deviceName}"
            feedback = ""
            openingJob?.cancel(); openingJob = null
            openingTimeoutJob?.cancel(); openingTimeoutJob = null
            startFreshnessWatch(generation, descriptor, link.subscription)
            return DataHandling.HANDLED
        }
        if (message.kind == 9L && link.protocolVersion >= 2L) {
            if (!link.requestedCatalogPages.contains(message.page) || message.pageCount !in 1L..4L) return DataHandling.DISCARDED
            if (link.catalogRevision.isNotEmpty() && link.catalogRevision != message.catalogRevision) return DataHandling.DISCARDED
            link.catalogRevision = message.catalogRevision
            link.catalogPageCount = message.pageCount
            link.catalogPages[message.page] = message.shortcuts
            link.requestedCatalogPages.remove(message.page)
            link.pendingCatalogRetries.remove(message.page)
            val nextPage = (0L until link.catalogPageCount).firstOrNull { it !in link.catalogPages }
            if (nextPage != null) requestCatalogPage(link, nextPage)
            link.shortcuts = link.catalogPages.toSortedMap().values.flatten().take(32)
            if (activeTransport == descriptor.transport) applyShortcutLayout(link, descriptor.peer.fingerprint)
            return DataHandling.HANDLED
        }
        if (message.kind == 10L && link.protocolVersion >= 2L) {
            link.catalogRevision = message.catalogRevision
            link.catalogPageCount = 0
            link.catalogPages.clear()
            link.requestedCatalogPages.clear()
            link.pendingCatalogRetries.clear()
            link.shortcuts = emptyList()
            if (activeTransport == descriptor.transport) {
                shortcuts = emptyList()
                pinnedShortcutIDs = emptySet()
            }
            requestCatalogPage(link, 0)
            return DataHandling.HANDLED
        }
        if (message.kind == 12L && link.protocolVersion >= 5L) {
            if (!link.requestedOutputCatalogPages.contains(message.page) || message.pageCount !in 1L..4L) return DataHandling.DISCARDED
            if (link.outputCatalogRevision.isNotEmpty() && link.outputCatalogRevision != message.catalogRevision) return DataHandling.DISCARDED
            link.outputCatalogRevision = message.catalogRevision
            link.outputCatalogPageCount = message.pageCount
            link.outputCatalogPages[message.page] = message.outputRoutes
            link.requestedOutputCatalogPages.remove(message.page)
            link.pendingOutputCatalogRetries.remove(message.page)
            val nextPage = (0L until link.outputCatalogPageCount).firstOrNull { it !in link.outputCatalogPages }
            if (nextPage != null) requestOutputCatalogPage(link, nextPage)
            link.outputRoutes = link.outputCatalogPages.toSortedMap().values.flatten().take(32)
            val loaded = link.outputCatalogPages.size.toLong() == link.outputCatalogPageCount
            if (activeTransport == descriptor.transport) {
                outputRoutes = link.outputRoutes
                outputCatalogLoaded = loaded
                outputCatalogLoading = !loaded
            }
            return DataHandling.HANDLED
        }
        if (message.kind == 13L && link.protocolVersion >= 5L) {
            link.outputCatalogRevision = message.catalogRevision
            link.outputCatalogPageCount = 0
            link.outputCatalogPages.clear()
            link.requestedOutputCatalogPages.clear()
            link.pendingOutputCatalogRetries.clear()
            link.outputRoutes = emptyList()
            if (activeTransport == descriptor.transport) {
                outputRoutes = emptyList()
                outputCatalogLoaded = false
                outputCatalogLoading = true
            }
            requestOutputCatalogPage(link, 0)
            return DataHandling.HANDLED
        }
        if (message.kind == 5L) {
            val pending = pendingCommands[message.commandId] ?: return DataHandling.DISCARDED
            if (!isCurrent(descriptor, message.subscription, pending.generation) || pending.descriptor != descriptor || pending.subscription != message.subscription) return DataHandling.DISCARDED
            val result = when {
                message.result == 0L -> successText(pending.intent)
                message.result == 1L -> "Control target changed. Refresh the deck."
                message.result == 2L -> "Control is unsupported on this Mac."
                message.result == 3L -> "Mac permission is needed."
                message.result == 4L -> "Mac denied the action."
                message.result == 5L -> "Control is unavailable."
                message.result == 6L -> "Mac is busy."
                pending.intent.action == 9L -> "Do Not Disturb status is unconfirmed. Check Focus before trying again."
                else -> "Mac action failed."
            }
            finishCommand(message.commandId, pending, result, preserveQueuedSlider = message.result == 0L && pending.intent.action == 6L)
            if (pending.intent.action == 8L) setShortcutFeedback(pending.intent.target, result)
            timing("event=command_ack action=${pending.intent.action} result=${message.result} total_ms=${clock() - pending.requestedAtMillis}")
            if (message.result == 0L && pending.intent.action == 6L) flushQueuedSlider(link, pending.generation)
            return DataHandling.HANDLED
        }
        return DataHandling.DISCARDED
    }

    private fun subscribeBestChannel() {
        if (!visible) return
        val target = peer ?: return
        if (activeLink() != null) return
        val best = links.values.filter { it.channel.descriptor.peer == target }
            .maxByOrNull { if (it.channel.descriptor.transport == "lan") 2 else 1 }
        if (best == null) {
            activeTransport = null
            connectionState = if (snapshot == null) DeskDeckConnectionState.DISCONNECTED else DeskDeckConnectionState.STALE
            status = if (connected(target)) "Checking Mac support…" else "Connect to this Mac to use Desk Deck."
            return
        }
        activeTransport = best.channel.descriptor.transport
        if (best.capable) beginSubscription(best)
        else {
            connectionState = DeskDeckConnectionState.OPENING
            status = "Checking Mac support…"
            val expectedGeneration = generation
            openingJob?.cancel()
            openingJob = scope.launch {
                wait(CAPABILITY_TIMEOUT_MILLIS)
                if (visible && peer == target && activeTransport == best.channel.descriptor.transport && generation == expectedGeneration && !best.capable) {
                    connectionState = DeskDeckConnectionState.FAILED
                    status = "Update aniCe on your Mac to use Desk Deck."
                }
            }
        }
    }

    private fun beginSubscription(link: Link, recoveryAttempt: Boolean = false) {
        stopSubscription(sendStop = true)
        activeTransport = link.channel.descriptor.transport
        val subscription = UUID.randomUUID().toString()
        link.subscription = subscription
        link.lastSequence = 0
        link.commandId = 0
        generation += 1
        val ownedGeneration = generation
        clearPendingCommands()
        connectionState = DeskDeckConnectionState.OPENING
        status = when {
            recoveryAttempt -> "Still waiting for Mac telemetry. Reconnecting once…"
            snapshot == null -> "Opening Desk Deck…"
            else -> "Last reading · refreshing"
        }
        feedback = ""
        freshnessJob?.cancel(); freshnessJob = null
        val version = link.protocolVersion
        if (version >= 2L) {
            link.catalogRevision = ""
            link.shortcuts = emptyList()
            link.catalogPages.clear()
            link.requestedCatalogPages.clear()
            link.pendingCatalogRetries.clear()
            link.catalogPageCount = 0
            if (activeTransport == link.channel.descriptor.transport) {
                shortcuts = emptyList()
                pinnedShortcutIDs = emptySet()
            }
        }
        if (version >= 5L) {
            link.outputCatalogRevision = ""
            link.outputCatalogPageCount = 0
            link.outputCatalogPages.clear()
            link.requestedOutputCatalogPages.clear()
            link.pendingOutputCatalogRetries.clear()
            link.outputRoutes = emptyList()
            outputRoutes = emptyList()
            outputCatalogLoaded = false
            outputCatalogLoading = true
        } else {
            outputRoutes = emptyList()
            outputCatalogLoaded = false
            outputCatalogLoading = false
        }
        val request = DeskDeckMessage(kind = 2, version = version, subscription = subscription).encode()
        openingJob?.cancel()
        openingTimeoutJob?.cancel()
        // Arm before DATA submission, which can itself wait for channel capacity.
        val timeout = scope.launch(start = CoroutineStart.LAZY) {
            wait(OPENING_TIMEOUT_MILLIS)
            if (!isCurrent(link.channel.descriptor, subscription, ownedGeneration) || connectionState == DeskDeckConnectionState.LIVE) return@launch
            if (!autoRetryUsed) {
                autoRetryUsed = true
                beginSubscription(link, recoveryAttempt = true)
            } else {
                connectionState = DeskDeckConnectionState.FAILED
                status = "Mac isn’t responding. Refresh or check connection details."
            }
        }
        openingTimeoutJob = timeout
        val submission = scope.launch(start = CoroutineStart.LAZY) {
            val submissionStarted = clock()
            try {
                link.channel.sendData(request)
                if (!isCurrent(link.channel.descriptor, subscription, ownedGeneration)) return@launch
                timing("event=subscription_submitted duration_ms=${clock() - submissionStarted}")
                if (version >= 2L) {
                    requestCatalogPage(link, 0)
                    if (version >= 5L) requestOutputCatalogPage(link, 0)
                    renewalJob?.cancel()
                    renewalJob = scope.launch {
                        while (isCurrent(link.channel.descriptor, subscription, ownedGeneration)) {
                            wait(RENEWAL_INTERVAL_MILLIS)
                            if (!isCurrent(link.channel.descriptor, subscription, ownedGeneration)) break
                            try { link.channel.sendData(DeskDeckMessage(kind = 7, version = version, subscription = subscription).encode()) }
                            catch (_: Exception) { }
                        }
                    }
                }
            } catch (_: CancellationException) {
                return@launch
            } catch (_: Exception) {
                if (isCurrent(link.channel.descriptor, subscription, ownedGeneration)) {
                    openingTimeoutJob?.cancel()
                    openingTimeoutJob = null
                    connectionState = DeskDeckConnectionState.FAILED
                    status = "Could not open Desk Deck. Check the connection and retry."
                }
                return@launch
            }
        }
        openingJob = submission
        timeout.start()
        submission.start()
    }

    private fun startFreshnessWatch(ownedGeneration: Long, descriptor: ChannelDescriptor, subscription: String) {
        freshnessJob?.cancel()
        val sample = snapshot ?: return
        freshnessJob = scope.launch {
            while (isCurrent(descriptor, subscription, ownedGeneration) && snapshot === sample) {
                val age = clock() - sample.receivedAtMillis
                val deadline = when (connectionState) {
                    DeskDeckConnectionState.LIVE -> STALE_AFTER_MILLIS
                    DeskDeckConnectionState.STALE -> FAILED_AFTER_MILLIS
                    else -> return@launch
                }
                wait((deadline - age).coerceAtLeast(1L))
                if (!isCurrent(descriptor, subscription, ownedGeneration) || snapshot !== sample) return@launch
                val updatedAge = clock() - sample.receivedAtMillis
                if (updatedAge >= FAILED_AFTER_MILLIS) {
                    connectionState = DeskDeckConnectionState.FAILED
                    status = "Mac isn’t responding. Refresh or check connection details."
                    return@launch
                }
                if (updatedAge >= STALE_AFTER_MILLIS && connectionState == DeskDeckConnectionState.LIVE) {
                    connectionState = DeskDeckConnectionState.STALE
                    status = "No recent data."
                }
            }
        }
    }

    private fun finishCommand(id: Long, pending: PendingCommand, message: String, preserveQueuedSlider: Boolean = false) {
        if (pendingCommands[id] != pending) return
        timeoutJobs.remove(id)?.cancel()
        submissionJobs.remove(id)?.cancel()
        pendingCommands.remove(id)
        busy = pendingCommands.isNotEmpty()
        feedback = message
        setActionFeedback(pending.intent.action, message)
        if (pending.intent.action == 8L) setShortcutFeedback(pending.intent.target, message)
        if (pending.intent.action == 6L) {
            previewIntents.remove(6L)
            if (preserveQueuedSlider) outputPreview = latestSliderIntents[6L]?.value
            else { latestSliderIntents.remove(6L); outputPreview = null }
        }
    }

    private fun flushQueuedSlider(link: Link, expectedGeneration: Long) {
        val queued = latestSliderIntents.remove(6L) ?: return
        val current = snapshot ?: return
        if (!isCurrent(link.channel.descriptor, link.subscription, expectedGeneration) || !readingsAreFresh ||
            !current.outputSupported || current.outputTarget != queued.target || current.outputRevision != queued.revision) {
            outputPreview = null
            feedback = "Output target changed. Refresh the deck."
        } else if (current.outputLevel != queued.value) sendIntent(link, queued)
        else outputPreview = null
    }

    private fun reconcileOutputSlider(supported: Boolean, target: String, revision: String, level: Long) {
        val desired = latestSliderIntents[6L] ?: previewIntents[6L] ?: return
        if (!supported || desired.target != target || desired.revision != revision) {
            latestSliderIntents.remove(6L); previewIntents.remove(6L); outputPreview = null
            feedback = "Output target changed. Refresh the deck."
        } else if (desired.value == level && !isBusy(6L)) {
            latestSliderIntents.remove(6L); previewIntents.remove(6L); outputPreview = null
        } else outputPreview = desired.value
    }

    private fun stopSubscription(sendStop: Boolean) {
        // Invalidate first; cancelling a job cannot retract a send completion already in flight.
        generation += 1
        openingJob?.cancel(); openingJob = null
        openingTimeoutJob?.cancel(); openingTimeoutJob = null
        freshnessJob?.cancel(); freshnessJob = null
        renewalJob?.cancel(); renewalJob = null
        clearPendingCommands()
        val link = activeLink()
        val subscription = link?.subscription.orEmpty()
        if (link != null && subscription.isNotEmpty()) {
            link.subscription = ""
            if (sendStop) scope.launch { try { link.channel.sendData(DeskDeckMessage(kind = 6, version = link.protocolVersion, subscription = subscription).encode()) } catch (_: Exception) { } }
        }
        activeTransport = null
    }

    private fun clearPendingCommands() {
        submissionJobs.values.forEach(Job::cancel); submissionJobs.clear()
        timeoutJobs.values.forEach(Job::cancel); timeoutJobs.clear()
        pendingCommands.clear()
        latestSliderIntents.clear(); previewIntents.clear()
        busy = false; outputPreview = null; brightnessPreview = null
    }

    private fun addHistoryGap() {
        history = (history + DeskDeckHistoryPoint(clock(), null, null)).takeLast(HISTORY_LIMIT)
    }

    private fun restoreCachedSnapshot() {
        val encoded = snapshotPreferences?.getString(CACHED_SNAPSHOT_KEY, null) ?: return
        try {
            val value = JSONObject(encoded)
            val fingerprint = value.getString("peer")
            if (!fingerprint.matches(Regex("[0-9a-f]{64}"))) throw IllegalArgumentException("Invalid cached peer")
            val nowWallMillis = System.currentTimeMillis()
            val sampledAtWallMillis = value.getLong("received_wall_ms")
            val lastSampleWallMillis = if (sampledAtWallMillis <= nowWallMillis) sampledAtWallMillis
                else nowWallMillis - MINIMUM_CACHED_AGE_MILLIS
            val ageMillis = if (sampledAtWallMillis <= nowWallMillis) {
                (nowWallMillis - sampledAtWallMillis).coerceAtLeast(MINIMUM_CACHED_AGE_MILLIS)
            } else MINIMUM_CACHED_AGE_MILLIS
            snapshot = DeskDeckSnapshot(
                sequence = value.getLong("sequence"),
                cpuPercent = value.getLong("cpu"),
                memoryUsed = value.getLong("memory_used"),
                memoryTotal = value.getLong("memory_total"),
                thermalState = value.getLong("thermal"),
                actions = value.getLong("actions"),
                outputSupported = value.getBoolean("output_supported"),
                outputTarget = value.getString("output_target"),
                outputRevision = value.getString("output_revision"),
                outputLevel = value.getLong("output_level"),
                microphoneSupported = value.getBoolean("mic_supported"),
                microphoneTarget = value.getString("mic_target"),
                microphoneRevision = value.getString("mic_revision"),
                microphoneMuted = value.getBoolean("mic_muted"),
                brightnessSupported = value.getBoolean("brightness_supported"),
                brightnessTarget = value.getString("brightness_target"),
                brightnessRevision = value.getString("brightness_revision"),
                brightnessLevel = value.getLong("brightness_level"),
                memoryActive = value.getLong("memory_active"),
                memoryWired = value.getLong("memory_wired"),
                memoryCompressed = value.getLong("memory_compressed"),
                powerState = value.getLong("power_state"),
                powerPercent = value.getLong("power_percent"),
                powerSource = value.getLong("power_source"),
                receivedAtMillis = clock() - ageMillis,
                protocolVersion = value.optLong("protocol_version", 1),
                memoryApp = value.optLong("memory_app", -1),
                memoryCached = value.optLong("memory_cached", -1),
                memoryFree = value.optLong("memory_free", -1),
                memorySwap = value.optLong("memory_swap", -1),
                receivedAtWallMillis = lastSampleWallMillis,
            )
            snapshotPeerFingerprint = fingerprint
            lastSnapshotCacheWriteMillis = clock()
            connectionState = DeskDeckConnectionState.STALE
            status = "Reconnecting to Mac…"
        } catch (_: Exception) {
            clearCachedSnapshot()
        }
    }

    private fun persistCachedSnapshot(force: Boolean = false) {
        val preferences = snapshotPreferences ?: return
        val sample = snapshot ?: return
        val fingerprint = snapshotPeerFingerprint ?: return
        if (sample.receivedAtWallMillis <= 0L) return
        val now = clock()
        val lastWrite = lastSnapshotCacheWriteMillis
        if (!force && lastWrite != null && now >= lastWrite && now - lastWrite < SNAPSHOT_CACHE_INTERVAL_MILLIS) return
        val encoded = JSONObject()
            .put("peer", fingerprint)
            .put("received_wall_ms", sample.receivedAtWallMillis)
            .put("sequence", sample.sequence)
            .put("cpu", sample.cpuPercent)
            .put("memory_used", sample.memoryUsed)
            .put("memory_total", sample.memoryTotal)
            .put("thermal", sample.thermalState)
            .put("actions", sample.actions)
            .put("output_supported", sample.outputSupported)
            .put("output_target", sample.outputTarget)
            .put("output_revision", sample.outputRevision)
            .put("output_level", sample.outputLevel)
            .put("mic_supported", sample.microphoneSupported)
            .put("mic_target", sample.microphoneTarget)
            .put("mic_revision", sample.microphoneRevision)
            .put("mic_muted", sample.microphoneMuted)
            .put("brightness_supported", sample.brightnessSupported)
            .put("brightness_target", sample.brightnessTarget)
            .put("brightness_revision", sample.brightnessRevision)
            .put("brightness_level", sample.brightnessLevel)
            .put("memory_active", sample.memoryActive)
            .put("memory_wired", sample.memoryWired)
            .put("memory_compressed", sample.memoryCompressed)
            .put("protocol_version", sample.protocolVersion)
            .put("memory_app", sample.memoryApp)
            .put("memory_cached", sample.memoryCached)
            .put("memory_free", sample.memoryFree)
            .put("memory_swap", sample.memorySwap)
            .put("power_state", sample.powerState)
            .put("power_percent", sample.powerPercent)
            .put("power_source", sample.powerSource)
        preferences.edit().putString(CACHED_SNAPSHOT_KEY, encoded.toString()).apply()
        lastSnapshotCacheWriteMillis = now
    }

    private fun clearCachedSnapshot() {
        snapshotPreferences?.edit()?.remove(CACHED_SNAPSHOT_KEY)?.apply()
        lastSnapshotCacheWriteMillis = null
    }

    private fun timing(message: String) {
        runCatching { Log.i(TIMING_TAG, message) }
    }

    private fun activeLink(): Link? = activeTransport?.let(links::get)

    private fun isCurrent(descriptor: ChannelDescriptor, subscription: String, ownedGeneration: Long): Boolean =
        subscription.isNotEmpty() && visible && generation == ownedGeneration && activeTransport == descriptor.transport && peer == descriptor.peer &&
            links[descriptor.transport]?.channel?.descriptor == descriptor && links[descriptor.transport]?.subscription == subscription

    private fun requestCatalogPage(link: Link, page: Long) {
        val subscription = link.subscription
        if (link.protocolVersion < 2L || subscription.isEmpty() || page in link.requestedCatalogPages || page in link.catalogPages) return
        val descriptor = link.channel.descriptor
        val ownedGeneration = generation
        link.requestedCatalogPages += page
        scope.launch {
            if (!isCurrent(descriptor, subscription, ownedGeneration)) {
                if (link.subscription == subscription) link.requestedCatalogPages.remove(page)
                return@launch
            }
            try { link.channel.sendData(DeskDeckMessage(kind = 8, version = link.protocolVersion, subscription = subscription, page = page).encode()) }
            catch (_: Exception) {
                if (isCurrent(descriptor, subscription, ownedGeneration)) {
                    link.requestedCatalogPages.remove(page)
                    link.pendingCatalogRetries += page
                }
            }
        }
    }

    private fun requestOutputCatalogPage(link: Link, page: Long) {
        val subscription = link.subscription
        if (link.protocolVersion < 5L || subscription.isEmpty() || page !in 0L..3L ||
            page in link.requestedOutputCatalogPages || page in link.outputCatalogPages) return
        val descriptor = link.channel.descriptor
        val ownedGeneration = generation
        link.requestedOutputCatalogPages += page
        scope.launch {
            if (!isCurrent(descriptor, subscription, ownedGeneration)) {
                if (link.subscription == subscription) link.requestedOutputCatalogPages.remove(page)
                return@launch
            }
            try {
                link.channel.sendData(DeskDeckMessage(kind = 11, version = link.protocolVersion,
                    subscription = subscription, page = page).encode())
            } catch (_: Exception) {
                if (isCurrent(descriptor, subscription, ownedGeneration)) {
                    link.requestedOutputCatalogPages.remove(page)
                    link.pendingOutputCatalogRetries += page
                }
            }
        }
    }

    private fun applyShortcutLayout(link: Link, fingerprint: String) {
        val order = orderedShortcutIDs(fingerprint)
        val byId = link.shortcuts.associateBy { it.id }
        val ordered = order.mapNotNull(byId::get) + link.shortcuts.filter { it.id !in order }.sortedBy { it.name.lowercase() }
        val savedPins = shortcutPreferences?.getString("pinned.$fingerprint", null)
        val pinned = savedPins?.split(',')?.filter(String::isNotEmpty)?.toSet() ?: link.shortcuts.take(4).mapTo(mutableSetOf()) { it.id }
        shortcuts = ordered
        pinnedShortcutIDs = pinned.intersect(byId.keys)
    }

    private fun orderedShortcutIDs(fingerprint: String): List<String> =
        shortcutPreferences?.getString("order.$fingerprint", null)?.split(',')?.filter(String::isNotEmpty).orEmpty()

    private fun actionBit(action: Long): Long = when (action) {
        1L -> 1L
        3L -> 2L
        4L -> 4L
        5L -> 8L
        9L -> 16L
        else -> 0L
    }

    private fun setActionFeedback(action: Long, message: String) {
        actionFeedbackValues = actionFeedbackValues + (action to message)
    }

    private fun setShortcutFeedback(id: String, message: String) {
        shortcutFeedbackValues = shortcutFeedbackValues + (id to message)
    }

    private fun successText(intent: Intent): String = when (intent.action) {
        1L -> "Mac lock requested."
        2L -> if (intent.value == 1L) "Default microphone muted." else "Default microphone unmuted."
        3L -> "Blender launched."
        4L -> "Terminal launched."
        5L -> "Screenshot controls opened on Mac."
        6L -> "Mac output volume updated."
        10L -> "Mac default output changed."
        8L -> "App launch requested."
        9L -> "Mac Shortcut finished. Check Focus to confirm the change."
        else -> "Done"
    }

    private companion object {
        const val MAX_ID = 4_294_967_295L
        const val HISTORY_LIMIT = 60
        const val CAPABILITY_TIMEOUT_MILLIS = 2_500L
        const val OPENING_TIMEOUT_MILLIS = 5_000L
        const val COMMAND_TIMEOUT_MILLIS = 6_000L
        const val RENEWAL_INTERVAL_MILLIS = 5_000L
        const val STALE_AFTER_MILLIS = 3_000L
        const val FAILED_AFTER_MILLIS = 10_000L
        const val TIMING_TAG = "aniCe-deskdeck"
        const val CACHED_SNAPSHOT_KEY = "last_snapshot"
        const val SNAPSHOT_CACHE_INTERVAL_MILLIS = 5_000L
        const val MINIMUM_CACHED_AGE_MILLIS = 3_000L
    }
}
