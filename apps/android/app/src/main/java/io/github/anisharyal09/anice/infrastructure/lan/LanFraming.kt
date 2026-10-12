// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds TCP frame allocation and assembly independently of session authentication.
package io.github.anisharyal09.anice.infrastructure.lan

import io.github.anisharyal09.anice.infrastructure.session.*
import java.nio.ByteBuffer

class LanFraming(private val profile: SessionProfile = SessionProfile.STANDARD, private val now: () -> Long = { System.nanoTime() / 1_000_000 }) {
    private val header = ByteArray(5)
    private var used = 0
    private var body: ByteArray? = null
    private var offset = 0
    private var started = 0L
    private var failed = false

    private fun reject(reason: SessionFailure): Nothing {
        failed = true
        body = null
        throw SessionException(reason)
    }

    val nextDeadline: Long? get() = (started + 10000).takeIf { !failed && used != 0 }

    private fun check(time: Long) {
        if (failed) throw SessionException(SessionFailure.CANCELLED)
        if (used != 0 && time - started >= 10000) reject(SessionFailure.EXPIRED)
    }

    fun tick() = check(now())

    fun beginBuffer(): Long = now().also { check(it) }

    var consumed = 0
        private set

    // The caller samples once per read and awaits delivery before feeding the remaining slice.
    fun feed(buffer: ByteArray, start: Int, length: Int, receivedAt: Long): ByteArray? {
        if (failed) throw SessionException(SessionFailure.CANCELLED)
        require(start >= 0 && length >= 0 && start <= buffer.size - length)
        consumed = 0
        while (consumed < length) {
            if (used == 0) started = receivedAt
            if (used < 5) {
                val count = minOf(5 - used, length - consumed)
                System.arraycopy(buffer, start + consumed, header, used, count)
                used += count
                consumed += count
                if (header[0] != profile.wire.toByte()) reject(SessionFailure.UNSUPPORTED_PROFILE)
                if (used < 5) return null
                val size = ByteBuffer.wrap(header, 1, 4).int
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
            return ByteBuffer.allocate(5).put(profile.wire.toByte()).putInt(envelope.size).array() + envelope
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
