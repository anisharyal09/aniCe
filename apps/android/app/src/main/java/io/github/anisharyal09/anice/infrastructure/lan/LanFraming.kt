// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds TCP frame allocation and assembly deadlines across secured readiness.
package io.github.anisharyal09.anice.infrastructure.lan

import io.github.anisharyal09.anice.infrastructure.session.*

class LanFraming(private val profile: SessionProfile = SessionProfile.STANDARD,
    private val secured: () -> Boolean = { false }, private val now: () -> Long = { System.nanoTime() / 1_000_000 }) {
    private val header = ByteArray(5)
    private var used = 0
    private var body: ByteArray? = null
    private var offset = 0
    private var started = 0L
    private var progressed = 0L
    private var failed = false

    private fun reject(reason: SessionFailure): Nothing {
        failed = true
        body = null
        throw SessionException(reason)
    }

    val nextDeadline: Long? get() {
        if (failed || used == 0) return null
        // Only established encrypted records may outlive ten seconds; trickling still has an absolute bound.
        val lifetime = if (secured() && offset > 0 && body?.get(0) == 6.toByte()) 60000L else 10000L
        return minOf(started + lifetime, progressed + 10000)
    }
    // Stop socket reads at a frame boundary before the ingress queue can suspend the producer.
    val readLimit: Int get() = if (used < 5) 5 - used else requireNotNull(body).size - offset

    private fun check(time: Long) {
        if (failed) throw SessionException(SessionFailure.CANCELLED)
        if (nextDeadline?.let { time >= it } == true) reject(SessionFailure.EXPIRED)
    }

    fun tick() = check(now())

    fun beginBuffer(): Long = now().also { check(it) }

    var consumed = 0
        private set

    // One sample per read: every slice of that read is fed with that read's receivedAt. The caller
    // must keep the returned envelopes in order, but it may hand them off instead of delivering
    // inline, because an assembled envelope is an owned array this instance no longer references.
    fun feed(buffer: ByteArray, start: Int, length: Int, receivedAt: Long): ByteArray? {
        if (failed) throw SessionException(SessionFailure.CANCELLED)
        require(start >= 0 && length >= 0 && start <= buffer.size - length)
        consumed = 0
        while (consumed < length) {
            if (used == 0) started = receivedAt
            progressed = receivedAt
            if (used < 5) {
                val count = minOf(5 - used, length - consumed)
                System.arraycopy(buffer, start + consumed, header, used, count)
                used += count
                consumed += count
                if (header[0] != profile.wire.toByte()) reject(SessionFailure.UNSUPPORTED_PROFILE)
                if (used < 5) return null
                val size =
                    ((header[1].toInt() and 255) shl 24) or ((header[2].toInt() and 255) shl 16) or
                        ((header[3].toInt() and 255) shl 8) or (header[4].toInt() and 255)
                if (size !in 2..profile.maximumEnvelope) reject(SessionFailure.MALFORMED)
                body = ByteArray(size)
            }
            val bytes = requireNotNull(body)
            val count = minOf(bytes.size - offset, length - consumed)
            System.arraycopy(buffer, start + consumed, bytes, offset, count)
            consumed += count
            offset += count
            if (offset == bytes.size) {
                body = null
                used = 0
                offset = 0
                return bytes
            }
        }
        return null
    }

    fun end() {
        tick()
        if (used != 0) reject(SessionFailure.MALFORMED)
    }

    companion object {
        fun encode(envelope: ByteArray, profile: SessionProfile = SessionProfile.STANDARD): ByteArray {
            if (envelope.size !in 2..profile.maximumEnvelope) throw SessionException(SessionFailure.MALFORMED)
            return ByteArray(envelope.size + 5).also { frame(it, envelope, profile) }
        }

        /**
         * Frames into a caller-owned buffer of at least `maximumEnvelope + 5` bytes and returns the
         * framed length, so a transport that already owns scratch space allocates nothing per record.
         */
        internal fun encodeInto(out: ByteArray, envelope: ByteArray, profile: SessionProfile): Int {
            if (envelope.size !in 2..profile.maximumEnvelope || out.size < envelope.size + 5)
                throw SessionException(SessionFailure.MALFORMED)
            return frame(out, envelope, profile)
        }

        private fun frame(out: ByteArray, envelope: ByteArray, profile: SessionProfile): Int {
            out[0] = profile.wire.toByte()
            out[1] = (envelope.size ushr 24).toByte()
            out[2] = (envelope.size ushr 16).toByte()
            out[3] = (envelope.size ushr 8).toByte()
            out[4] = envelope.size.toByte()
            System.arraycopy(envelope, 0, out, 5, envelope.size)
            return envelope.size + 5
        }
    }
}

// Submission bounds are profile-local; GATT and standard LAN retain their existing limits.
internal class LanQueueBudget(private val profile: SessionProfile) {
    var messages = 0
        private set
    var bytes = 0
        private set
    fun canReserve(size: Int): Boolean {
        val limit = if (profile == SessionProfile.STANDARD) 8 else 4
        val capacity = if (profile == SessionProfile.STANDARD) 32768 else 4 * profile.maximumEnvelope
        return size in 1..profile.maximumEnvelope && messages < limit && bytes + size <= capacity
    }
    fun reserve(size: Int) {
        if (!canReserve(size)) throw SessionBackpressure()
        messages++; bytes += size
    }
    fun release(size: Int) {
        check(messages > 0 && size in 1..bytes)
        messages--; bytes -= size
    }
}
