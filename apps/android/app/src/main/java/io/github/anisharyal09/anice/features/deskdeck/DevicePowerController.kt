// SPDX-License-Identifier: GPL-3.0-or-later
// Exchanges peer battery state over existing secured channels, observing local changes only while connected.
package io.github.anisharyal09.anice.features.deskdeck

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.SessionException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

data class DevicePowerReading(val state: Long, val percent: Int?, val source: Long) {
    val plugged: Boolean get() = source in 2L..5L
    val charging: Boolean get() = state == 3L
    val label: String get() = when (state) {
        0L -> "Unavailable"
        1L -> "No battery"
        2L -> "On battery"
        3L -> "Charging"
        4L -> "Fully charged"
        5L -> "Plugged in · not charging"
        else -> "Unavailable"
    }
    val macSummary: String get() {
        val stateText = if (state == 0L) "Mac power unavailable" else label
        return listOfNotNull(stateText, percent?.let { "$it%" }).joinToString(" · ")
    }
    val shortSummary: String get() {
        if (percent == null || percent < 0) {
            return when (state) {
                3L -> "Charging"
                4L -> "Full"
                5L -> "Plugged in"
                else -> ""
            }
        }
        return when (state) {
            3L -> "$percent% (Charging)"
            4L -> "$percent% (Full)"
            5L -> "$percent% (Plugged in)"
            else -> "$percent%"
        }
    }

    companion object {
        fun from(intent: Intent?): DevicePowerReading {
            if (intent == null) return DevicePowerReading(0, null, 0)
            return fromValues(
                present = intent.getBooleanExtra(BatteryManager.EXTRA_PRESENT, true),
                rawLevel = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1),
                scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1),
                status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_UNKNOWN),
                plugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0),
            )
        }

        internal fun fromValues(present: Boolean, rawLevel: Int, scale: Int, status: Int, plugged: Int): DevicePowerReading {
            if (!present) return DevicePowerReading(1, null, 0)
            val percent = if (rawLevel >= 0 && scale > 0) (rawLevel * 100 / scale).coerceIn(0, 100) else null
            val state = when {
                status == BatteryManager.BATTERY_STATUS_CHARGING -> 3L
                status == BatteryManager.BATTERY_STATUS_FULL -> 4L
                plugged == 0 -> 2L
                status == BatteryManager.BATTERY_STATUS_NOT_CHARGING -> 5L
                else -> 0L
            }
            val source = when (plugged) {
                0 -> 1L
                BatteryManager.BATTERY_PLUGGED_AC -> 2L
                BatteryManager.BATTERY_PLUGGED_USB -> 3L
                BatteryManager.BATTERY_PLUGGED_WIRELESS -> 4L
                BatteryManager.BATTERY_PLUGGED_DOCK -> 5L
                else -> 0L
            }
            return DevicePowerReading(state, if (state == 0L) null else percent, source)
        }
    }
}

class DevicePowerController(context: Context) : FeatureHandler {
    private class Link(val channel: SecuredChannel) {
        var capabilitySent = false
        var remoteCapable = false
        var sending = false
        var pendingReport: ByteArray? = null
    }

    private val app = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val links = mutableMapOf<String, Link>()
    private val macReadings = mutableStateMapOf<String, DevicePowerReading>()
    private var receiverRegistered = false
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) { update(DevicePowerReading.from(intent)) }
    }
    var reading by mutableStateOf(DevicePowerReading.from(stickyIntent())); private set

    fun refresh() { update(DevicePowerReading.from(stickyIntent())) }

    override fun available(channel: SecuredChannel) {
        val link = Link(channel)
        links[channel.descriptor.transport] = link
        registerReceiverIfNeeded()
        link.pendingReport = reportBytes()
        drain(channel.descriptor, link)
    }

    override fun retired(descriptor: ChannelDescriptor) {
        if (links[descriptor.transport]?.channel?.descriptor != descriptor) return
        links.remove(descriptor.transport)
        if (links.values.none { peerKey(it.channel.descriptor.peer) == peerKey(descriptor.peer) }) {
            macReadings.remove(peerKey(descriptor.peer))
        }
        if (links.isEmpty()) unregisterReceiver()
    }

    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        links[descriptor.transport]?.takeIf { it.channel.descriptor == descriptor }?.let { drain(descriptor, it) }
    }

    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        val link = links[descriptor.transport]?.takeIf { it.channel.descriptor == descriptor } ?: return DataHandling.DISCARDED
        val message = try { DevicePowerMessage.decode(bytes) ?: return DataHandling.UNRECOGNIZED }
            catch (_: DevicePowerWireException) { return DataHandling.DISCARDED }
            catch (_: SessionException) { return DataHandling.DISCARDED }
        if (descriptor.peer.platform != "macos") return DataHandling.DISCARDED
        if (message.kind == 1L) { link.remoteCapable = true; return DataHandling.HANDLED }
        if (!link.remoteCapable) return DataHandling.DISCARDED
        macReadings[peerKey(descriptor.peer)] = DevicePowerReading(message.state,
            message.percent.takeIf { it >= 0 }?.toInt(), message.source)
        return DataHandling.HANDLED
    }

    fun macSummary(peer: DeviceIdentity): String? {
        return macReadings[peerKey(peer)]?.macSummary
    }

    fun macShortSummary(peer: DeviceIdentity): String? {
        val short = macReadings[peerKey(peer)]?.shortSummary ?: return null
        return short.takeIf { it.isNotEmpty() }
    }

    private fun peerKey(peer: DeviceIdentity) = peer.deviceId + ":" + peer.fingerprint

    private fun update(next: DevicePowerReading) {
        if (reading == next) return
        reading = next
        links.values.toList().forEach { link ->
            link.pendingReport = reportBytes()
            drain(link.channel.descriptor, link)
        }
    }

    private fun reportBytes(): ByteArray = DevicePowerMessage(kind = 2, state = reading.state,
        percent = reading.percent?.toLong() ?: -1, source = reading.source).encode()

    private fun drain(descriptor: ChannelDescriptor, link: Link) {
        if (link.sending || links[descriptor.transport] !== link || link.channel.descriptor != descriptor) return
        link.sending = true
        scope.launch {
            try {
                while (links[descriptor.transport] === link && link.channel.descriptor == descriptor) {
                    val capability = !link.capabilitySent
                    val bytes = if (capability) DevicePowerMessage(kind = 1).encode() else link.pendingReport ?: break
                    if (!capability) link.pendingReport = null
                    try { link.channel.sendData(bytes) }
                    catch (_: Exception) {
                        if (!capability && link.pendingReport == null) link.pendingReport = bytes
                        break
                    }
                    if (capability) link.capabilitySent = true
                }
            } finally {
                link.sending = false
            }
        }
    }

    private fun stickyIntent(): Intent? = app.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))

    private fun registerReceiverIfNeeded() {
        if (receiverRegistered) return
        ContextCompat.registerReceiver(app, receiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
        receiverRegistered = true
    }

    private fun unregisterReceiver() {
        if (!receiverRegistered) return
        runCatching { app.unregisterReceiver(receiver) }
        receiverRegistered = false
    }
}
