// SPDX-License-Identifier: GPL-3.0-or-later
// Fences worker-side authenticated PCM against stream retirement, focus and retained-channel maintenance.
package io.github.anisharyal09.anice.features.privatelistening

import io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor
import io.github.anisharyal09.anice.infrastructure.connections.ChannelMaintenance

internal data class ListeningReceipt(
    val sequence: Long = 0,
    val firstAudioAt: Long? = null,
    val peerAt: Long = 0,
    val peerMaintenance: Long = 0,
)

internal class PrivateListeningAudioAdmission(
    val descriptor: ChannelDescriptor,
    private val stream: String,
    private val output: PrivateListeningOutput,
    private val maintenance: ChannelMaintenance?,
) {
    private var closed = false
    private var paused = false
    private var maintenanceTotal = maintenance?.elapsedMillis ?: 0
    @Volatile var receipt = ListeningReceipt()
        private set

    @Synchronized fun receive(message: PrivateListeningMessage, now: Long): Boolean {
        if (closed || message.kind != 3L || message.text(0) != stream ||
            message.number(1) <= receipt.sequence) return false
        val total = maintenance?.elapsedMillis ?: 0
        receipt = ListeningReceipt(message.number(1), receipt.firstAudioAt ?: now, now, total)
        // A coalesced completion still fences old queued audio until Main re-verifies routing.
        if (!paused && maintenance?.active != true && total == maintenanceTotal) output.offer(message)
        return true
    }

    @Synchronized fun pause() { paused = true }
    @Synchronized fun resume() {
        maintenanceTotal = maintenance?.elapsedMillis ?: 0
        paused = false
    }
    @Synchronized fun close() { closed = true }
}
