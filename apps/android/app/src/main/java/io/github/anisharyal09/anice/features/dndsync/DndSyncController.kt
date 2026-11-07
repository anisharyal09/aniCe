// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.features.dndsync

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.SystemClock
import android.provider.Settings
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import io.github.anisharyal09.anice.infrastructure.connections.*
import kotlinx.coroutines.*
import java.util.UUID

class DndSyncController(context: Context) : FeatureHandler {
    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences("dnd_sync", Context.MODE_PRIVATE)
    private val native = app.getSystemService(NotificationManager::class.java)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private class Link(val channel: SecuredChannel) {
        var sending = false
        var receiving = false
        var capabilitySent = false
        var capabilityJob: Job? = null
        var eventJob: Job? = null
    }
    private val links = mutableMapOf<String, Link>()
    private val selected = mutableMapOf<String, ChannelDescriptor>()
    private val seen = mutableMapOf<String, LinkedHashSet<String>>()
    private val awaiting = mutableMapOf<String, Pair<ChannelDescriptor, Job>>()
    private val echo = DndEchoGuard()
    private var registered = false
    var sending by mutableStateOf(prefs.getBoolean("sending", false)); private set
    var granted by mutableStateOf(native.isNotificationPolicyAccessGranted); private set
    var status by mutableStateOf("Changes sync only while connected. No offline changes are replayed."); private set
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == NotificationManager.ACTION_NOTIFICATION_POLICY_ACCESS_GRANTED_CHANGED) refreshAccess()
            else current()?.let { if (echo.changed(it, SystemClock.elapsedRealtime()) && sending && granted) publish(it) }
        }
    }

    fun setSendingEnabled(value: Boolean) {
        sending = value
        prefs.edit().putBoolean("sending", value).apply()
        if (!value) {
            links.values.forEach { it.eventJob?.cancel() }
            awaiting.values.forEach { it.second.cancel() }; awaiting.clear()
        }
        links.values.forEach { it.capabilitySent = false; advertise(it) }
    }
    fun refreshAccess() {
        val next = native.isNotificationPolicyAccessGranted
        if (next != granted) {
            granted = next
            echo.baseline(current())
            links.values.forEach { it.capabilitySent = false; advertise(it) }
            if (!next) status = "DND access is needed to send or receive changes."
        }
    }
    fun requestAccess() {
        runCatching { app.startActivity(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            .onFailure { status = "Open Android Settings and allow aniCe Do Not Disturb access." }
    }
    private fun current(): Boolean? = when (native.currentInterruptionFilter) {
        NotificationManager.INTERRUPTION_FILTER_ALL -> false
        NotificationManager.INTERRUPTION_FILTER_PRIORITY, NotificationManager.INTERRUPTION_FILTER_ALARMS,
        NotificationManager.INTERRUPTION_FILTER_NONE -> true
        else -> null
    }
    override fun available(channel: SecuredChannel) {
        val link = Link(channel)
        links[channel.descriptor.transport] = link
        refreshAccess()
        if (!registered) {
            echo.baseline(current())
            ContextCompat.registerReceiver(app, receiver, IntentFilter().apply {
                addAction(NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED)
                addAction(NotificationManager.ACTION_NOTIFICATION_POLICY_ACCESS_GRANTED_CHANGED)
            }, ContextCompat.RECEIVER_NOT_EXPORTED)
            registered = true
        }
        advertise(link)
    }
    override fun retired(descriptor: ChannelDescriptor) {
        val link = links[descriptor.transport]?.takeIf { it.channel.descriptor == descriptor } ?: return
        link.capabilityJob?.cancel(); link.eventJob?.cancel()
        links.remove(descriptor.transport)
        if (selected[descriptor.peer.fingerprint] == descriptor) selected.remove(descriptor.peer.fingerprint)
        awaiting.filterValues { it.first == descriptor }.keys.toList().forEach { awaiting.remove(it)?.second?.cancel() }
        if (links.values.none { it.channel.descriptor.peer.fingerprint == descriptor.peer.fingerprint }) seen.remove(descriptor.peer.fingerprint)
        if (links.isEmpty() && registered) {
            app.unregisterReceiver(receiver); registered = false; echo.baseline(null)
            status = "Disconnected. DND changes are not queued."
        }
    }
    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        links[descriptor.transport]?.takeIf { it.channel.descriptor == descriptor }?.let(::advertise)
    }
    private fun live(link: Link) = links[link.channel.descriptor.transport] === link
    private fun advertise(link: Link) {
        if (!live(link) || link.capabilitySent || link.capabilityJob?.isActive == true) return
        val message = DndSyncMessage(1, sending = sending && granted, receiving = granted)
        link.capabilityJob = scope.launch {
            try {
                link.channel.sendData(message.encode())
                if (live(link)) link.capabilitySent = message == DndSyncMessage(1, sending = sending && granted, receiving = granted)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { status = "DND capability could not be sent." }
            finally {
                link.capabilityJob = null
                // Republish if configuration changed while the send was suspended.
                if (live(link) && !link.capabilitySent && message != DndSyncMessage(1, sending = sending && granted, receiving = granted)) advertise(link)
            }
        }
    }
    private fun publish(value: Boolean) {
        val targets = links.values.filter { it.receiving && it.capabilitySent }
            .groupBy { it.channel.descriptor.peer.fingerprint }.values.map { candidates ->
                val peer = candidates.first().channel.descriptor.peer.fingerprint
                (candidates.firstOrNull { it.channel.descriptor == selected[peer] }
                    ?: candidates.firstOrNull { it.channel.descriptor.transport == "lan" } ?: candidates.first())
                    .also { selected[peer] = it.channel.descriptor }
            }
        if (targets.isEmpty()) { status = "No connected Mac is ready to receive DND changes."; return }
        for (link in targets) {
            // Cancel an older pending change and send only the latest explicit state.
            link.eventJob?.cancel()
            awaiting.filterValues { it.first.peer.fingerprint == link.channel.descriptor.peer.fingerprint }.keys.toList()
                .forEach { awaiting.remove(it)?.second?.cancel() }
            val message = DndSyncMessage(2, id = UUID.randomUUID().toString(), enabled = value)
            link.eventJob = scope.launch {
                try {
                    if (!live(link) || !sending || !granted || !link.receiving) return@launch
                    val timer = scope.launch {
                        delay(8_000)
                        if (awaiting.remove(message.id) != null) {
                            link.eventJob?.cancel()
                            status = "Mac DND change is unconfirmed. Check the Mac."
                        }
                    }
                    awaiting[message.id] = link.channel.descriptor to timer
                    status = "Sending DND change to Mac…"
                    link.channel.sendData(message.encode())
                } catch (cancelled: CancellationException) {
                    awaiting.remove(message.id)?.second?.cancel(); throw cancelled
                } catch (_: Exception) {
                    awaiting.remove(message.id)?.second?.cancel()
                    status = "Mac DND submission is unconfirmed. No automatic retry."
                }
            }
        }
    }
    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        val link = links[descriptor.transport]?.takeIf { it.channel.descriptor == descriptor } ?: return DataHandling.DISCARDED
        val message = try { DndSyncMessage.decode(bytes) ?: return DataHandling.UNRECOGNIZED }
            catch (_: Exception) { return DataHandling.DISCARDED }
        when (message.kind) {
            1L -> { link.sending = message.sending; link.receiving = message.receiving }
            3L -> {
                if (awaiting[message.id]?.first != descriptor) return DataHandling.DISCARDED
                awaiting.remove(message.id)?.second?.cancel()
                status = when (message.result) {
                    0L -> "Mac On/Off Shortcut completed; DND state is reported by its automation."
                    1L -> "Set up the Mac DND On and Off Shortcuts in Settings."
                    4L -> "A newer DND change replaced this request."
                    else -> "Mac DND change is unconfirmed. Check the Mac."
                }
            }
            2L -> {
                if (!link.sending) return DataHandling.DISCARDED
                val ids = seen.getOrPut(descriptor.peer.fingerprint) { linkedSetOf() }
                if (!ids.add(message.id)) return DataHandling.DISCARDED
                if (ids.size > 128) ids.remove(ids.first())
                refreshAccess()
                var result = 1L
                if (granted) {
                    result = try {
                        echo.applying(message.enabled, SystemClock.elapsedRealtime())
                        native.setInterruptionFilter(if (message.enabled) NotificationManager.INTERRUPTION_FILTER_PRIORITY else NotificationManager.INTERRUPTION_FILTER_ALL)
                        status = if (message.enabled) "Mac requested phone DND on." else "aniCe DND rule turned off. Other phone rules may keep DND on."
                        0L
                    } catch (_: SecurityException) { refreshAccess(); 1L }
                    catch (_: Exception) { status = "Phone DND request failed. Check Android DND settings."; 2L }
                } else status = "Mac DND change was not applied: allow Android DND access."
                try { link.channel.sendData(DndSyncMessage(3, id = message.id, result = result).encode()) }
                catch (_: Exception) { /* A lost result must not cause a duplicate DND change. */ }
            }
        }
        return DataHandling.HANDLED
    }
}

@Composable
fun DndSyncSettings(model: DndSyncController) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, model) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) model.refreshAccess() }
        lifecycle.addObserver(observer); model.refreshAccess()
        onDispose { lifecycle.removeObserver(observer) }
    }
    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        io.github.anisharyal09.anice.ui.AutomaticConnectionToggle(
            checked = model.sending, enabled = true, onCheckedChange = model::setSendingEnabled,
            label = "Sync Do Not Disturb", description = "Send this phone’s DND changes to connected Macs. Enable on Mac too for both directions.")
        if (!model.granted) TextButton(onClick = model::requestAccess) { Text("Allow Do Not Disturb access") }
        Text("Incoming Mac changes work when DND access is allowed, even with this switch off. Android may keep DND on for another active mode or rule.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(model.status, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
