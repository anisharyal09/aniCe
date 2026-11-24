// SPDX-License-Identifier: GPL-3.0-or-later
// Isolates the reverse audio tag while reusing the fixed, strictly validated PCM message shapes.
package io.github.anisharyal09.anice.features.privatelistening

import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionCbor

internal data class PhoneAudioMessage(val kind: Long, val fields: List<Cbor>) {
    fun text(index: Int) = (fields[index] as Cbor.Text).value
    fun number(index: Int) = (fields[index] as Cbor.Integer).value
    fun flag(index: Int) = (fields[index] as Cbor.Bool).value
    fun validated(): PrivateListeningMessage {
        if (kind !in 0..4) throw PrivateListeningWireException()
        return PrivateListeningMessage(kind, fields).also { it.validate() }
    }
    fun encode(): ByteArray {
        validated()
        return SessionCbor.encode(Cbor.Array(listOf(Cbor.Text(TAG), Cbor.Integer(1),
            Cbor.Integer(kind), Cbor.Array(fields))), maximumBytes = 4000)
    }
    companion object {
        const val TAG = "aniCe phone audio"
        private val audioPrefix = SessionCbor.encode(Cbor.Array(listOf(
            Cbor.Text(TAG), Cbor.Integer(1), Cbor.Integer(3), Cbor.Array(emptyList())))).dropLast(1).toByteArray()

        // Classification only; full canonical shape/timeline validation still precedes admission.
        internal fun hasAudioPrefix(bytes: ByteArray): Boolean =
            bytes.size >= audioPrefix.size && audioPrefix.indices.all { bytes[it] == audioPrefix[it] }

        fun decode(bytes: ByteArray): PhoneAudioMessage? {
            val small = bytes.size <= 4000
            val row = (SessionCbor.decode(bytes, maximumBytes = if (small) 4000 else 524416,
                materializeBytes = small) as? Cbor.Array)?.value ?: return null
            if (row.firstOrNull() != Cbor.Text(TAG)) return null
            if (!small || row.size != 4 || row[1] != Cbor.Integer(1)) throw PrivateListeningWireException()
            return PhoneAudioMessage((row[2] as? Cbor.Integer)?.value ?: throw PrivateListeningWireException(),
                (row[3] as? Cbor.Array)?.value ?: throw PrivateListeningWireException())
                .also { it.validated() }
        }
        fun from(message: PrivateListeningMessage) = PhoneAudioMessage(message.kind, message.fields).also { it.validated() }
    }
}
