// SPDX-License-Identifier: GPL-3.0-or-later
// Validates bounded media envelopes carried by existing authenticated DATA records.
package io.github.anisharyal09.anice.features.media
import io.github.anisharyal09.anice.infrastructure.session.*
import java.util.UUID

class MediaWireException : Exception("Invalid media message")
data class MediaMessage(val kind: Long, val fields: List<Cbor>) {
    fun string(i: Int) = (fields[i] as? Cbor.Text)?.value.orEmpty()
    fun number(i: Int) = (fields[i] as? Cbor.Integer)?.value ?: 0L
    fun encode(): ByteArray { validate(); return SessionCbor.encode(Cbor.Array(listOf(Cbor.Text("aniCe media"), Cbor.Integer(1), Cbor.Integer(kind), Cbor.Array(fields)))).also { if(it.size>4000) throw MediaWireException() } }
    fun validate() {
        fun check(v: Boolean) { if(!v) throw MediaWireException() }
        fun n(i: Int, min: Long, max: Long) = (fields.getOrNull(i) as? Cbor.Integer)?.value?.let { it in min..max } == true
        fun t(i: Int, max: Int, uuid: Boolean = false, empty: Boolean = false): Boolean {
            val s = (fields.getOrNull(i) as? Cbor.Text)?.value ?: return false
            if(s.toByteArray(Charsets.UTF_8).size>max || '\u0000' in s) return false
            return !uuid || (empty && s.isEmpty()) || (s.length==36 && runCatching { UUID.fromString(s).toString().equals(s,true) }.getOrDefault(false))
        }
        fun b(i: Int, vararg sizes: Int): Boolean {
            val size = (fields.getOrNull(i) as? Cbor.Bytes)?.value?.size ?: return false
            return size in sizes
        }
        when(kind) {
            1L -> check(fields.size==2 && n(0,1,1) && fields[1] is Cbor.Bool)
            2L,3L,4L -> check(fields.size==1 && t(0,36,true))
            5L -> {
                check(fields.size==15 && t(0,36,true) && t(1,36,true,true) && t(2,36,true,true) && t(3,512) && t(4,256) && t(5,96) && n(6,0,3) && n(7,-1,604800000) && n(8,-1,604800000) && n(9,0,16000) && n(10,0,31) && t(11,36,true,true) && t(12,36,true) && b(14,0,32))
                val sources=(fields[13] as? Cbor.Array)?.value ?: throw MediaWireException()
                check(sources.size<=16);val ids=mutableSetOf<String>()
                sources.forEach { source ->
                    val row=(source as? Cbor.Array)?.value ?: throw MediaWireException()
                    val id=(row.getOrNull(0) as? Cbor.Text)?.value.orEmpty()
                    val name=(row.getOrNull(1) as? Cbor.Text)?.value ?: throw MediaWireException()
                    val state=(row.getOrNull(2) as? Cbor.Integer)?.value ?: throw MediaWireException()
                    check(row.size==3 && id.length==36 && runCatching { UUID.fromString(id).toString().equals(id,true) }.getOrDefault(false) && ids.add(id) && name.toByteArray().size<=96 && '\u0000' !in name && state in 0..3)
                }
                check(string(1).isEmpty()==string(2).isEmpty())
                check(string(1).isEmpty() || string(1) in ids)
                check(string(11).isEmpty() || string(11) in ids)
                check(number(10) and 8L==0L || number(8)>0)
                check(string(1).isNotEmpty() || (number(10)==0L && (fields[14] as Cbor.Bytes).value.isEmpty()))
            }
            6L -> { check(fields.size==6 && t(0,36,true) && n(1,1,4294967295) && t(2,36,true,true) && t(3,36,true) && n(4,1,6) && n(5,0,604800000))
                check((number(4)==6L)==string(2).isEmpty()); check(number(4)==4L || number(5)==0L)
            }
            7L -> check(fields.size==3 && t(0,36,true) && n(1,1,4294967295) && n(2,0,7))
            8L -> {
                check(fields.size==7 && t(0,36,true) && t(1,36,true) && t(2,36,true) && b(3,32) && n(4,1,65536) && n(5,0,65535))
                val chunk=(fields[6] as? Cbor.Bytes)?.value ?: throw MediaWireException()
                check(chunk.size in 1..2048 && number(5)+chunk.size<=number(4))
            }
            else -> throw MediaWireException()
        }
    }
    companion object {
        fun decode(bytes: ByteArray): MediaMessage? {
            if(bytes.size>4000) throw MediaWireException()
            val row=(SessionCbor.decode(bytes) as? Cbor.Array)?.value ?: return null
            if(row.firstOrNull()!=Cbor.Text("aniCe media")) return null
            if(row.size!=4 || row[1]!=Cbor.Integer(1)) throw MediaWireException()
            val kind=(row[2] as? Cbor.Integer)?.value ?: throw MediaWireException()
            val fields=(row[3] as? Cbor.Array)?.value ?: throw MediaWireException()
            return MediaMessage(kind,fields).also { it.validate() }
        }
    }
}
