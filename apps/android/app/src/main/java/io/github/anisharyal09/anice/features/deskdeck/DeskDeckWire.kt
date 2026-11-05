// SPDX-License-Identifier: GPL-3.0-or-later
// Defines bounded Mac Desk Deck messages carried by the authenticated session.
package io.github.anisharyal09.anice.features.deskdeck

import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionCbor
import java.util.UUID

class DeskDeckWireException : Exception()

data class DeskDeckMessage(
    val kind: Long,
    val actions: Long = 0,
    val subscription: String = "",
    val sequence: Long = 0,
    val cpuPercent: Long = -1,
    val memoryUsed: Long = 0,
    val memoryTotal: Long = 0,
    val thermalState: Long = 0,
    val outputSupported: Boolean = false,
    val outputTarget: String = "",
    val outputRevision: String = "",
    val outputLevel: Long = -1,
    val microphoneSupported: Boolean = false,
    val microphoneTarget: String = "",
    val microphoneRevision: String = "",
    val microphoneMuted: Boolean = false,
    val brightnessSupported: Boolean = false,
    val brightnessTarget: String = "",
    val brightnessRevision: String = "",
    val brightnessLevel: Long = -1,
    val commandId: Long = 0,
    val action: Long = 0,
    val target: String = "",
    val revision: String = "",
    val value: Long = -1,
    val result: Long = 0,
) {
    fun encode(): ByteArray {
        val fields = when (kind) {
            1L -> listOf(Cbor.Integer(actions))
            2L, 6L -> listOf(Cbor.Text(subscription))
            3L -> listOf(
                Cbor.Text(subscription), Cbor.Integer(sequence), Cbor.Integer(cpuPercent),
                Cbor.Integer(memoryUsed), Cbor.Integer(memoryTotal), Cbor.Integer(thermalState), Cbor.Integer(actions),
                Cbor.Bool(outputSupported), Cbor.Text(outputTarget), Cbor.Text(outputRevision), Cbor.Integer(outputLevel),
                Cbor.Bool(microphoneSupported), Cbor.Text(microphoneTarget), Cbor.Text(microphoneRevision), Cbor.Bool(microphoneMuted),
                Cbor.Bool(brightnessSupported), Cbor.Text(brightnessTarget), Cbor.Text(brightnessRevision), Cbor.Integer(brightnessLevel),
            )
            4L -> listOf(Cbor.Text(subscription), Cbor.Integer(commandId), Cbor.Integer(action),
                Cbor.Text(target), Cbor.Text(revision), Cbor.Integer(value))
            5L -> listOf(Cbor.Text(subscription), Cbor.Integer(commandId), Cbor.Integer(result))
            else -> throw DeskDeckWireException()
        }
        val bytes = SessionCbor.encode(Cbor.Array(listOf(Cbor.Text(TAG), Cbor.Integer(1), Cbor.Integer(kind), Cbor.Array(fields))))
        decode(bytes) ?: throw DeskDeckWireException()
        return bytes
    }

    companion object {
        const val TAG = "aniCe desk deck"
        const val MAX_BYTES = 512

        fun decode(bytes: ByteArray): DeskDeckMessage? {
            if (bytes.size > 4000) return null
            val row = (SessionCbor.decode(bytes) as? Cbor.Array)?.value ?: return null
            if ((row.firstOrNull() as? Cbor.Text)?.value != TAG) return null
            if (bytes.size > MAX_BYTES || row.size != 4 || (row[1] as? Cbor.Integer)?.value != 1L) throw DeskDeckWireException()
            val kind = (row[2] as? Cbor.Integer)?.value ?: throw DeskDeckWireException()
            val f = (row[3] as? Cbor.Array)?.value ?: throw DeskDeckWireException()
            fun number(i: Int) = (f.getOrNull(i) as? Cbor.Integer)?.value ?: throw DeskDeckWireException()
            fun string(i: Int) = (f.getOrNull(i) as? Cbor.Text)?.value ?: throw DeskDeckWireException()
            fun bool(i: Int) = (f.getOrNull(i) as? Cbor.Bool)?.value ?: throw DeskDeckWireException()
            fun uuid(value: String) = try { UUID.fromString(value).toString() == value } catch (_: IllegalArgumentException) { false }
            if (kind == 1L) {
                if (f.size != 1 || number(0) !in 0L..15L) throw DeskDeckWireException()
                return DeskDeckMessage(kind, actions = number(0))
            }
            if (kind == 2L || kind == 6L) {
                if (f.size != 1 || !uuid(string(0))) throw DeskDeckWireException()
                return DeskDeckMessage(kind, subscription = string(0))
            }
            if (kind == 3L) {
                if (f.size != 19 || !uuid(string(0))) throw DeskDeckWireException()
                val message = DeskDeckMessage(
                    kind = kind, subscription = string(0), sequence = number(1), cpuPercent = number(2),
                    memoryUsed = number(3), memoryTotal = number(4), thermalState = number(5), actions = number(6),
                    outputSupported = bool(7), outputTarget = string(8), outputRevision = string(9), outputLevel = number(10),
                    microphoneSupported = bool(11), microphoneTarget = string(12), microphoneRevision = string(13), microphoneMuted = bool(14),
                    brightnessSupported = bool(15), brightnessTarget = string(16), brightnessRevision = string(17), brightnessLevel = number(18),
                )
                if (message.sequence !in 1L..4294967295L || message.cpuPercent !in -1L..100L ||
                    message.memoryUsed < 0 || message.memoryTotal < 0 || message.memoryUsed > message.memoryTotal ||
                    message.thermalState !in 0L..3L || message.actions !in 0L..15L ||
                    !validControl(message.outputSupported, message.outputTarget, message.outputRevision, message.outputLevel) ||
                    !validIdentity(message.microphoneSupported, message.microphoneTarget, message.microphoneRevision) ||
                    !validControl(message.brightnessSupported, message.brightnessTarget, message.brightnessRevision, message.brightnessLevel)) throw DeskDeckWireException()
                return message
            }
            if (kind == 4L) {
                if (f.size != 6 || !uuid(string(0))) throw DeskDeckWireException()
                val message = DeskDeckMessage(kind, subscription = string(0), commandId = number(1), action = number(2),
                    target = string(3), revision = string(4), value = number(5))
                val valid = when (message.action) {
                    1L, 3L, 4L, 5L -> message.target.isEmpty() && message.revision.isEmpty() && message.value == -1L
                    2L -> message.target.isNotEmpty() && message.revision.isNotEmpty() && message.value in 0L..1L
                    6L, 7L -> message.target.isNotEmpty() && message.revision.isNotEmpty() && message.value in 0L..100L
                    else -> false
                }
                if (message.commandId !in 1L..4294967295L || !valid) throw DeskDeckWireException()
                return message
            }
            if (kind == 5L) {
                if (f.size != 3 || !uuid(string(0))) throw DeskDeckWireException()
                val message = DeskDeckMessage(kind, subscription = string(0), commandId = number(1), result = number(2))
                if (message.commandId !in 1L..4294967295L || message.result !in 0L..7L) throw DeskDeckWireException()
                return message
            }
            throw DeskDeckWireException()
        }

        private fun validControl(supported: Boolean, target: String, revision: String, level: Long): Boolean =
            if (supported) target.isNotEmpty() && revision.isNotEmpty() && level in 0L..100L
            else target.isEmpty() && revision.isEmpty() && level == -1L

        private fun validIdentity(supported: Boolean, target: String, revision: String): Boolean =
            if (supported) target.isNotEmpty() && revision.isNotEmpty()
            else target.isEmpty() && revision.isEmpty()
    }
}
