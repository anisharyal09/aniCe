// SPDX-License-Identifier: GPL-3.0-or-later
// Encodes transport-independent EDHOC and encrypted-record envelope discriminators.
package io.github.anisharyal09.anice.infrastructure.session

// The discriminator sits outside EDHOC; payload bytes enter transcript hashing unchanged.
object SessionEnvelope {
    fun encode(kind: Int, payload: ByteArray, profile: SessionProfile = SessionProfile.STANDARD): ByteArray {
        if (kind !in 1..6 || payload.isEmpty() || payload.size >= (if (kind == 6) profile.maximumEnvelope else 4096))
            throw SessionException(SessionFailure.MALFORMED)
        return byteArrayOf(kind.toByte()) + payload
    }

    fun decode(message: ByteArray, profile: SessionProfile = SessionProfile.STANDARD): Pair<Int, ByteArray> {
        if (message.size !in 2..profile.maximumEnvelope || message[0].toInt() !in 1..6)
            throw SessionException(SessionFailure.MALFORMED)
        if (message[0].toInt() != 6 && message.size > 4096) throw SessionException(SessionFailure.MALFORMED)
        return message[0].toInt() to message.copyOfRange(1, message.size)
    }
}
