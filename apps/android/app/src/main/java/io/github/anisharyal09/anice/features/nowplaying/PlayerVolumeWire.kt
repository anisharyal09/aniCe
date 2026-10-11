// SPDX-License-Identifier: GPL-3.0-or-later
// Defines distinct optional player and output volume envelopes without changing media v1 bytes.
package io.github.anisharyal09.anice.features.nowplaying

import io.github.anisharyal09.anice.infrastructure.session.*
import java.util.UUID

enum class VolumeScope(val tag: String) { PLAYER("aniCe player volume"), OUTPUT("aniCe output volume") }

data class PlayerVolumeMessage(val kind: Long, val fields: List<Cbor>, val scope: VolumeScope=VolumeScope.PLAYER) {
    fun string(i: Int)=(fields[i] as Cbor.Text).value
    fun number(i: Int)=(fields[i] as Cbor.Integer).value
    fun encode(): ByteArray {
        validate()
        return SessionCbor.encode(Cbor.Array(listOf(Cbor.Text(scope.tag),Cbor.Integer(1),Cbor.Integer(kind),Cbor.Array(fields)))).also { if(it.size>4000) throw MediaWireException() }
    }
    private fun validate() {
        fun text(i: Int, empty: Boolean=false): Boolean { val s=(fields.getOrNull(i) as? Cbor.Text)?.value ?: return false;return (empty && s.isEmpty()) || (s.length==36 && runCatching { UUID.fromString(s).toString().equals(s,true) }.getOrDefault(false)) }
        fun number(i: Int, range: LongRange)=(fields.getOrNull(i) as? Cbor.Integer)?.value?.let { it in range }==true
        val valid=when(kind) {
            1L -> fields.size==1 && number(0,1L..1L)
            2L -> fields.size==5 && text(0) && text(1,true) && text(2,true) && string(1).isEmpty()==string(2).isEmpty() && (fields[3] as? Cbor.Bool)?.let { if(it.value) text(1) && text(2) && number(4,0L..100L) else number(4,-1L..-1L) }==true
            3L -> fields.size==5 && text(0) && number(1,1L..4294967295L) && text(2) && text(3) && number(4,0L..100L)
            4L -> fields.size==3 && text(0) && number(1,1L..4294967295L) && number(2,0L..7L)
            else -> false
        }
        if(!valid) throw MediaWireException()
    }
    companion object {
        fun decode(bytes: ByteArray): PlayerVolumeMessage? {
            if(bytes.size>4000) throw MediaWireException()
            val row=(SessionCbor.decode(bytes) as? Cbor.Array)?.value ?: return null
            val scope=VolumeScope.entries.firstOrNull { it.tag==(row.firstOrNull() as? Cbor.Text)?.value } ?: return null
            if(row.size!=4 || (row[1] as? Cbor.Integer)?.value!=1L) throw MediaWireException()
            val message=PlayerVolumeMessage((row[2] as? Cbor.Integer)?.value ?: throw MediaWireException(),(row[3] as? Cbor.Array)?.value ?: throw MediaWireException(),scope)
            message.validate();return message
        }
    }
}
