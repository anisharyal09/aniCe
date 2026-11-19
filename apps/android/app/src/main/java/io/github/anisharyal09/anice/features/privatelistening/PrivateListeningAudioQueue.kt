// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds newest received PCM and coordinates silent priming separately from permission to write audible samples.
package io.github.anisharyal09.anice.features.privatelistening

internal data class ListeningAudioPacket(val sequence: Long, val offset: Long, val pcm: ByteArray)

internal class PrivateListeningAudioQueue(
    val maximumFrames: Int = 38400,
    val targetFrames: Int = 9600,
) {
    private val packets = ArrayDeque<ListeningAudioPacket>()
    private var queued = 0
    private var lastSequence = 0L
    private var generation = 0L
    private var gate = false
    private var closed = false
    private var discontinuity = true

    init {
        require(targetFrames in 960..maximumFrames && maximumFrames <= 48000)
    }

    @Synchronized fun offer(message: PrivateListeningMessage, nativeFrames: Int = 0): Boolean {
        require(message.kind == 3L && nativeFrames >= 0)
        message.validate()
        if (closed || message.number(1) <= lastSequence) return false
        lastSequence = message.number(1)
        val native = nativeFrames.coerceAtMost(maximumFrames)
        val packetFrames = PrivateListeningMessage.FRAMES_PER_PACKET.toInt()
        while (packets.isNotEmpty() && queued + packetFrames + native > maximumFrames) {
            packets.removeFirst()
            queued -= packetFrames
            discontinuity = true
        }
        if (queued + packetFrames + native > maximumFrames) {
            discontinuity = true
            return false
        }
        packets.addLast(ListeningAudioPacket(message.number(1), message.number(2), message.bytes(3).copyOf()))
        queued += packetFrames
        return true
    }

    @Synchronized fun beginPriming(): Long {
        gate = false
        generation += 1
        return generation
    }

    @Synchronized fun primed(token: Long): Boolean {
        if (closed || token != generation) return false
        // Priming is an authorization barrier, not a reason to discard healthy buffered audio.
        gate = true
        return true
    }

    @Synchronized fun currentPreparation(token: Long): Boolean = !closed && token == generation

    @Synchronized fun permitsWrite(token: Long): Boolean = !closed && gate && token == generation

    @Synchronized fun pause(discard: Boolean) {
        gate = false
        generation += 1
        if (discard) {
            packets.clear()
            queued = 0
        }
        discontinuity = true
    }

    @Synchronized fun trimToTarget() {
        while (packets.size > 1 && queued > targetFrames) {
            packets.removeFirst()
            queued -= PrivateListeningMessage.FRAMES_PER_PACKET.toInt()
            discontinuity = true
        }
    }

    @Synchronized fun take(): ListeningAudioPacket? {
        if (!gate || closed) return null
        val next = packets.removeFirstOrNull() ?: return null
        queued -= PrivateListeningMessage.FRAMES_PER_PACKET.toInt()
        return next
    }

    @Synchronized fun consumeDiscontinuity(): Boolean {
        val changed = discontinuity
        discontinuity = false
        return changed
    }

    @Synchronized fun close() {
        closed = true
        gate = false
        generation += 1
        packets.clear()
        queued = 0
        discontinuity = true
    }

    val queuedFrames: Int @Synchronized get() = queued
    val highestSequence: Long @Synchronized get() = lastSequence
    val writeGateOpen: Boolean @Synchronized get() = gate && !closed
    val revision: Long @Synchronized get() = generation
}
