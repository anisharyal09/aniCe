// SPDX-License-Identifier: GPL-3.0-or-later
// Bounds TCP frame allocation and assembly independently of session authentication.
package io.github.anisharyal09.anice.infrastructure.lan

import io.github.anisharyal09.anice.infrastructure.session.*
import java.nio.ByteBuffer

class LanFraming(private val now: () -> Long = { System.nanoTime() / 1_000_000 }) {
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

    fun tick() {
        if (failed) throw SessionException(SessionFailure.CANCELLED)
        if (used != 0 && now() - started >= 10000) reject(SessionFailure.EXPIRED)
    }

    fun feed(byte: Byte): ByteArray? {
        tick()
        if (used == 0) started = now()
        if (used < 5) {
            header[used++] = byte
            if (used == 1 && byte != 1.toByte()) reject(SessionFailure.UNSUPPORTED_PROFILE)
            if (used == 5) {
                val length = ByteBuffer.wrap(header, 1, 4).int
                if (length !in 2..4096) reject(SessionFailure.MALFORMED)
                body = ByteArray(length)
            }
            return null
        }
        val bytes = requireNotNull(body)
        bytes[offset++] = byte
        if (offset != bytes.size) return null
        body = null
        used = 0
        offset = 0
        return bytes
    }

    fun end() {
        tick()
        if (used != 0) reject(SessionFailure.MALFORMED)
    }

    companion object {
        fun encode(envelope: ByteArray): ByteArray {
            if (envelope.size !in 2..4096) throw SessionException(SessionFailure.MALFORMED)
            return ByteBuffer.allocate(5).put(1).putInt(envelope.size).array() + envelope
        }
    }
}
