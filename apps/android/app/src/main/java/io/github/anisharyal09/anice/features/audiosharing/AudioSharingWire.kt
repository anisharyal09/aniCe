// SPDX-License-Identifier: GPL-3.0-or-later
// Validates bounded audio-sharing envelopes and checked PCM timelines inside authenticated LAN DATA.
package io.github.anisharyal09.anice.features.audiosharing

import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionCbor

class AudioSharingWireException : Exception("Invalid audio sharing message")

data class AudioSharingMessage(val kind: Long, val fields: List<Cbor>) {
    fun text(index: Int) = (fields[index] as Cbor.Text).value
    fun number(index: Int) = (fields[index] as Cbor.Integer).value
    fun flag(index: Int) = (fields[index] as Cbor.Bool).value
    fun bytes(index: Int) = (fields[index] as Cbor.Bytes).value

    fun encode(): ByteArray {
        validate()
        return SessionCbor.encode(
            Cbor.Array(listOf(Cbor.Text(TAG), Cbor.Integer(1), Cbor.Integer(kind), Cbor.Array(fields))),
            maximumBytes = MAX_MESSAGE_BYTES,
        )
    }

    fun validate() {
        fun requireWire(valid: Boolean) {
            if (!valid) throw AudioSharingWireException()
        }
        fun integer(index: Int, minimum: Long, maximum: Long) =
            (fields.getOrNull(index) as? Cbor.Integer)?.value?.let { it in minimum..maximum } == true
        fun uuid(index: Int) =
            (fields.getOrNull(index) as? Cbor.Text)?.value?.let { UUID_V4.matches(it) } == true
        fun format(index: Int) =
            integer(index, SAMPLE_RATE, SAMPLE_RATE) && integer(index + 1, CHANNELS, CHANNELS) &&
                integer(index + 2, BIT_DEPTH, BIT_DEPTH) &&
                integer(index + 3, FRAMES_PER_PACKET, FRAMES_PER_PACKET)

        when (kind) {
            0L -> requireWire(fields.size == 5 && format(0) && fields[4] is Cbor.Bool)
            1L -> requireWire(fields.size == 5 && uuid(0) && format(1))
            2L -> requireWire(fields.size == 2 && uuid(0) && integer(1, 0, 9))
            3L -> {
                requireWire(fields.size == 4 && uuid(0) && integer(1, 1, MAX_SEQUENCE) &&
                    integer(2, 0, Long.MAX_VALUE))
                requireWire(number(2) == (number(1) - 1) * FRAMES_PER_PACKET)
                requireWire((fields[3] as? Cbor.Bytes)?.value?.size == PCM_BYTES)
            }
            4L -> requireWire(fields.size == 2 && uuid(0) && integer(1, 0, 7))
            5L -> {
                requireWire(fields.size == 7 && uuid(0) && integer(1, 0, 1) && integer(2, 0, 5) &&
                    integer(3, 0, MAX_SEQUENCE) && integer(4, 0, Long.MAX_VALUE) &&
                    integer(5, 0, MAX_QUEUED_FRAMES) && integer(6, 0, 4294967295))
                requireWire(number(1) != 0L || number(6) == 0L)
            }
            else -> throw AudioSharingWireException()
        }
    }

    companion object {
        const val TAG = "aniCe private listening"
        const val MAX_MESSAGE_BYTES = 4000
        const val SAMPLE_RATE = 48000L
        const val CHANNELS = 2L
        const val BIT_DEPTH = 16L
        const val FRAMES_PER_PACKET = 960L
        const val PCM_BYTES = 3840
        const val MAX_SEQUENCE = Long.MAX_VALUE / FRAMES_PER_PACKET
        const val MAX_QUEUED_FRAMES = 48000L
        private val UUID_V4 =
            Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
        private val audioPrefix = SessionCbor.encode(Cbor.Array(listOf(
            Cbor.Text(TAG), Cbor.Integer(1), Cbor.Integer(3), Cbor.Array(emptyList())))).dropLast(1).toByteArray()

        // Classification only; full canonical shape/timeline validation still precedes admission.
        internal fun hasAudioPrefix(bytes: ByteArray): Boolean =
            bytes.size >= audioPrefix.size && audioPrefix.indices.all { bytes[it] == audioPrefix[it] }

        fun decode(bytes: ByteArray): AudioSharingMessage? {
            // Larger unrelated LAN DATA stays with its handler without materializing its byte strings.
            val small = bytes.size <= MAX_MESSAGE_BYTES
            val row = (SessionCbor.decode(bytes,
                maximumBytes = if (small) MAX_MESSAGE_BYTES else 524416,
                materializeBytes = small) as? Cbor.Array)?.value ?: return null
            if (row.firstOrNull() != Cbor.Text(TAG)) return null
            if (!small || row.size != 4 || row[1] != Cbor.Integer(1)) throw AudioSharingWireException()
            return AudioSharingMessage(
                (row[2] as? Cbor.Integer)?.value ?: throw AudioSharingWireException(),
                (row[3] as? Cbor.Array)?.value ?: throw AudioSharingWireException(),
            ).also { it.validate() }
        }

        fun capability(enabled: Boolean) =
            AudioSharingMessage(0, listOf(Cbor.Integer(SAMPLE_RATE), Cbor.Integer(CHANNELS),
                Cbor.Integer(BIT_DEPTH), Cbor.Integer(FRAMES_PER_PACKET), Cbor.Bool(enabled)))

        fun start(streamId: String) =
            AudioSharingMessage(1, listOf(Cbor.Text(streamId), Cbor.Integer(SAMPLE_RATE),
                Cbor.Integer(CHANNELS), Cbor.Integer(BIT_DEPTH), Cbor.Integer(FRAMES_PER_PACKET)))

        fun audio(streamId: String, sequence: Long, pcm: ByteArray): AudioSharingMessage {
            if (sequence !in 1..MAX_SEQUENCE) throw AudioSharingWireException()
            return AudioSharingMessage(3, listOf(Cbor.Text(streamId), Cbor.Integer(sequence),
                Cbor.Integer((sequence - 1) * FRAMES_PER_PACKET), Cbor.Bytes(pcm))).also { it.validate() }
        }
    }
}
