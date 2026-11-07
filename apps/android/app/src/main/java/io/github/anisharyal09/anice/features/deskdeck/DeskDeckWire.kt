// SPDX-License-Identifier: GPL-3.0-or-later
// Defines bounded, versioned Mac Desk Deck messages carried by authenticated DATA.
package io.github.anisharyal09.anice.features.deskdeck

import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionCbor
import java.util.UUID

class DeskDeckWireException : Exception()

data class DeskDeckShortcut(val id: String, val name: String)

data class DeskDeckMessage(
    val kind: Long,
    val version: Long = 1,
    val actions: Long = 0,
    val subscription: String = "",
    val sequence: Long = 0,
    val cpuPercent: Long = -1,
    val memoryUsed: Long = 0,
    val memoryTotal: Long = 0,
    val memoryActive: Long = -1,
    val memoryWired: Long = -1,
    val memoryCompressed: Long = -1,
    val memoryApp: Long = -1,
    val memoryCached: Long = -1,
    val memoryFree: Long = -1,
    val memorySwap: Long = -1,
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
    val powerState: Long = 0,
    val powerPercent: Long = -1,
    val powerSource: Long = 0,
    val page: Long = 0,
    val pageCount: Long = 0,
    val catalogRevision: String = "",
    val shortcuts: List<DeskDeckShortcut> = emptyList(),
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
            2L, 6L, 7L -> listOf(Cbor.Text(subscription))
            8L -> listOf(Cbor.Text(subscription), Cbor.Integer(page))
            9L -> listOf(Cbor.Text(subscription), Cbor.Integer(page), Cbor.Integer(pageCount), Cbor.Text(catalogRevision),
                Cbor.Array(shortcuts.map { Cbor.Array(listOf(Cbor.Text(it.id), Cbor.Text(it.name))) }))
            10L -> listOf(Cbor.Text(subscription), Cbor.Text(catalogRevision))
            3L -> if (version == 1L) listOf(
                Cbor.Text(subscription), Cbor.Integer(sequence), Cbor.Integer(cpuPercent),
                Cbor.Integer(memoryUsed), Cbor.Integer(memoryTotal), Cbor.Integer(thermalState), Cbor.Integer(actions),
                Cbor.Bool(outputSupported), Cbor.Text(outputTarget), Cbor.Text(outputRevision), Cbor.Integer(outputLevel),
                Cbor.Bool(microphoneSupported), Cbor.Text(microphoneTarget), Cbor.Text(microphoneRevision), Cbor.Bool(microphoneMuted),
                Cbor.Bool(brightnessSupported), Cbor.Text(brightnessTarget), Cbor.Text(brightnessRevision), Cbor.Integer(brightnessLevel),
            ) else listOf(
                Cbor.Text(subscription), Cbor.Integer(sequence), Cbor.Integer(cpuPercent),
                Cbor.Integer(memoryActive), Cbor.Integer(memoryWired), Cbor.Integer(memoryCompressed), Cbor.Integer(memoryTotal),
                Cbor.Integer(thermalState), Cbor.Integer(actions),
                Cbor.Bool(outputSupported), Cbor.Text(outputTarget), Cbor.Text(outputRevision), Cbor.Integer(outputLevel),
                Cbor.Bool(microphoneSupported), Cbor.Text(microphoneTarget), Cbor.Text(microphoneRevision), Cbor.Bool(microphoneMuted),
                Cbor.Integer(powerState), Cbor.Integer(powerPercent), Cbor.Integer(powerSource),
            ) + if (version >= 3L) listOf(Cbor.Integer(memoryApp), Cbor.Integer(memoryCached), Cbor.Integer(memoryFree), Cbor.Integer(memorySwap)) else emptyList()
            4L -> listOf(Cbor.Text(subscription), Cbor.Integer(commandId), Cbor.Integer(action),
                Cbor.Text(target), Cbor.Text(revision), Cbor.Integer(value))
            5L -> listOf(Cbor.Text(subscription), Cbor.Integer(commandId), Cbor.Integer(result))
            else -> throw DeskDeckWireException()
        }
        val bytes = SessionCbor.encode(Cbor.Array(listOf(Cbor.Text(TAG), Cbor.Integer(version), Cbor.Integer(kind), Cbor.Array(fields))))
        if (bytes.size > if (version == 1L) V1_MAX_BYTES else MAX_BYTES) throw DeskDeckWireException()
        decode(bytes) ?: throw DeskDeckWireException()
        return bytes
    }

    companion object {
        const val TAG = "aniCe desk deck"
        const val MAX_BYTES = 3_800
        const val V1_MAX_BYTES = 512
        const val PAGE_SIZE = 8

        fun decode(bytes: ByteArray): DeskDeckMessage? {
            if (bytes.size > 4000) return null
            val row = (SessionCbor.decode(bytes) as? Cbor.Array)?.value ?: return null
            if ((row.firstOrNull() as? Cbor.Text)?.value != TAG) return null
            if (row.size != 4) throw DeskDeckWireException()
            val version = (row[1] as? Cbor.Integer)?.value ?: throw DeskDeckWireException()
            if (version !in 1L..4L || bytes.size > if (version == 1L) V1_MAX_BYTES else MAX_BYTES) throw DeskDeckWireException()
            val kind = (row[2] as? Cbor.Integer)?.value ?: throw DeskDeckWireException()
            val f = (row[3] as? Cbor.Array)?.value ?: throw DeskDeckWireException()
            fun number(i: Int) = (f.getOrNull(i) as? Cbor.Integer)?.value ?: throw DeskDeckWireException()
            fun string(i: Int) = (f.getOrNull(i) as? Cbor.Text)?.value ?: throw DeskDeckWireException()
            fun bool(i: Int) = (f.getOrNull(i) as? Cbor.Bool)?.value ?: throw DeskDeckWireException()
            fun uuid(value: String) = try { UUID.fromString(value).toString() == value } catch (_: IllegalArgumentException) { false }
            if (kind == 1L) {
                if (f.size != 1 || number(0) !in 0L..(if (version >= 4L) 31L else 15L)) throw DeskDeckWireException()
                return DeskDeckMessage(kind, version = version, actions = number(0))
            }
            if (kind in setOf(2L, 6L, 7L)) {
                if (kind == 7L && version < 2L || f.size != 1 || !uuid(string(0))) throw DeskDeckWireException()
                return DeskDeckMessage(kind, version = version, subscription = string(0))
            }
            if (kind == 8L && version >= 2L) {
                if (f.size != 2 || !uuid(string(0)) || number(1) !in 0L..3L) throw DeskDeckWireException()
                return DeskDeckMessage(kind, version = version, subscription = string(0), page = number(1))
            }
            if (kind == 9L && version >= 2L) {
                if (f.size != 5 || !uuid(string(0)) || number(1) !in 0L..3L || number(2) !in 1L..4L ||
                    number(1) >= number(2) || !uuid(string(3))) throw DeskDeckWireException()
                val rows = (f[4] as? Cbor.Array)?.value ?: throw DeskDeckWireException()
                if (rows.size > PAGE_SIZE) throw DeskDeckWireException()
                val entries = rows.map { item ->
                    val pair = (item as? Cbor.Array)?.value ?: throw DeskDeckWireException()
                    if (pair.size != 2) throw DeskDeckWireException()
                    val id = (pair[0] as? Cbor.Text)?.value ?: throw DeskDeckWireException()
                    val name = (pair[1] as? Cbor.Text)?.value ?: throw DeskDeckWireException()
                    if (!uuid(id) || name.isBlank() || name.length > 80 || name.any(Char::isISOControl)) throw DeskDeckWireException()
                    DeskDeckShortcut(id, name)
                }
                if (entries.map { it.id }.distinct().size != entries.size) throw DeskDeckWireException()
                return DeskDeckMessage(kind, version = version, subscription = string(0), page = number(1), pageCount = number(2), catalogRevision = string(3), shortcuts = entries)
            }
            if (kind == 10L && version >= 2L) {
                if (f.size != 2 || !uuid(string(0)) || !uuid(string(1))) throw DeskDeckWireException()
                return DeskDeckMessage(kind, version = version, subscription = string(0), catalogRevision = string(1))
            }
            if (kind == 3L) {
                if (!uuid(string(0))) throw DeskDeckWireException()
                val message = if (version == 1L) {
                    if (f.size != 19) throw DeskDeckWireException()
                    DeskDeckMessage(
                        kind = kind, version = version, subscription = string(0), sequence = number(1), cpuPercent = number(2),
                        memoryUsed = number(3), memoryTotal = number(4), thermalState = number(5), actions = number(6),
                        outputSupported = bool(7), outputTarget = string(8), outputRevision = string(9), outputLevel = number(10),
                        microphoneSupported = bool(11), microphoneTarget = string(12), microphoneRevision = string(13), microphoneMuted = bool(14),
                        brightnessSupported = bool(15), brightnessTarget = string(16), brightnessRevision = string(17), brightnessLevel = number(18),
                    ).also {
                        if (it.memoryUsed < 0 || it.memoryTotal < 0 || it.memoryUsed > it.memoryTotal || it.thermalState !in 0L..3L ||
                            it.actions !in 0L..15L || !validControl(it.outputSupported, it.outputTarget, it.outputRevision, it.outputLevel) ||
                            !validIdentity(it.microphoneSupported, it.microphoneTarget, it.microphoneRevision) ||
                            !validControl(it.brightnessSupported, it.brightnessTarget, it.brightnessRevision, it.brightnessLevel)) throw DeskDeckWireException()
                    }
                } else {
                    if (f.size != if (version >= 3L) 24 else 20) throw DeskDeckWireException()
                    val active = number(3); val wired = number(4); val compressed = number(5); val total = number(6)
                    val app = if (version >= 3L) number(20) else -1L
                    val cached = if (version >= 3L) number(21) else -1L
                    val free = if (version >= 3L) number(22) else -1L
                    val swap = if (version >= 3L) number(23) else -1L
                    if (version >= 3L) {
                        val unavailable = app == -1L && cached == -1L && free == -1L && swap == -1L
                        val available = app in 0..total && cached in 0..total && free in 0..total && swap >= -1L &&
                            cached <= total - free && app <= total - free - cached &&
                            wired <= total - free - cached - app && compressed <= total - free - cached - app - wired
                        if (!unavailable && !available) throw DeskDeckWireException()
                    }
                    val outputOK = validControl(bool(9), string(10), string(11), number(12))
                    val microphoneOK = validIdentity(bool(13), string(14), string(15))
                    if (active < 0 || wired < 0 || compressed < 0 || total < 0 || active > total || wired > total - active || compressed > total - active - wired ||
                        number(7) !in 0L..3L || number(8) !in 0L..(if (version >= 4L) 31L else 15L) || !outputOK || !microphoneOK ||
                        number(17) !in 0L..5L || number(18) !in -1L..100L || number(19) !in 0L..3L ||
                        number(17) < 2L && number(18) != -1L) throw DeskDeckWireException()
                    DeskDeckMessage(
                        kind = kind, version = version, subscription = string(0), sequence = number(1), cpuPercent = number(2),
                        memoryActive = active, memoryWired = wired, memoryCompressed = compressed, memoryTotal = total,
                        memoryUsed = if (version >= 3L) { if (app < 0) -1 else total - cached - free } else active + wired + compressed,
                        memoryApp = app, memoryCached = cached, memoryFree = free, memorySwap = swap, thermalState = number(7), actions = number(8),
                        outputSupported = bool(9), outputTarget = string(10), outputRevision = string(11), outputLevel = number(12),
                        microphoneSupported = bool(13), microphoneTarget = string(14), microphoneRevision = string(15), microphoneMuted = bool(16),
                        powerState = number(17), powerPercent = number(18), powerSource = number(19),
                    )
                }
                if (message.sequence !in 1L..4_294_967_295L || message.cpuPercent !in -1L..100L) throw DeskDeckWireException()
                return message
            }
            if (kind == 4L) {
                if (f.size != 6 || !uuid(string(0))) throw DeskDeckWireException()
                val message = DeskDeckMessage(version = version, kind = kind, subscription = string(0), commandId = number(1), action = number(2),
                    target = string(3), revision = string(4), value = number(5))
                val valid = when (message.action) {
                    1L, 5L -> message.target.isEmpty() && message.revision.isEmpty() && message.value == -1L
                    3L, 4L -> version == 1L && message.target.isEmpty() && message.revision.isEmpty() && message.value == -1L
                    2L -> message.target.isNotEmpty() && message.revision.isNotEmpty() && message.value in 0L..1L
                    6L -> message.target.isNotEmpty() && message.revision.isNotEmpty() && message.value in 0L..100L
                    7L -> version == 1L && message.target.isNotEmpty() && message.revision.isNotEmpty() && message.value in 0L..100L
                    8L -> version >= 2L && uuid(message.target) && uuid(message.revision) && message.value == -1L
                    9L -> version >= 4L && message.target.isEmpty() && message.revision.isEmpty() && message.value == -1L
                    else -> false
                }
                if (message.commandId !in 1L..4_294_967_295L || !valid) throw DeskDeckWireException()
                return message
            }
            if (kind == 5L) {
                if (f.size != 3 || !uuid(string(0))) throw DeskDeckWireException()
                val message = DeskDeckMessage(version = version, kind = kind, subscription = string(0), commandId = number(1), result = number(2))
                if (message.commandId !in 1L..4_294_967_295L || message.result !in 0L..7L) throw DeskDeckWireException()
                return message
            }
            throw DeskDeckWireException()
        }

        private fun validControl(supported: Boolean, target: String, revision: String, level: Long): Boolean =
            if (supported) target.isNotEmpty() && revision.isNotEmpty() && level in 0L..100L
            else target.isEmpty() && revision.isEmpty() && level == -1L

        private fun validIdentity(supported: Boolean, target: String, revision: String): Boolean =
            if (supported) target.isNotEmpty() && revision.isNotEmpty() else target.isEmpty() && revision.isEmpty()
    }
}
