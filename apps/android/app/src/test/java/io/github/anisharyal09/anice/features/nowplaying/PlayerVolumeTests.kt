// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies independent extension fixtures, stale targets, denied commands and uncertain channel retirement.
package io.github.anisharyal09.anice.features.nowplaying

import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject

class PlayerVolumeTests {
    private fun hex(text: String)=text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    @Test fun independentInventoriesAndNegativeBoundsLeaveV1Unchanged() {
        val root=JSONObject(javaClass.classLoader!!.getResource("media/volume-vectors.json")!!.readText())
        val good=root.getJSONArray("valid");val bad=root.getJSONArray("invalid")
        assertTrue(good.length()>=9);assertTrue(bad.length()>=23)
        for(i in 0 until good.length()) {
            val row=good.getJSONObject(i);val bytes=hex(row.getString("bytesHex"));val message=PlayerVolumeMessage.decode(bytes)!!
            assertEquals(row.getLong("kind"),message.kind);assertArrayEquals(bytes,message.encode());assertNull(MediaMessage.decode(bytes))
        }
        for(i in 0 until bad.length()) {
            val row=bad.getJSONObject(i)
            try { PlayerVolumeMessage.decode(hex(row.getString("bytesHex")));fail("Accepted ${row.getString("name")}") } catch(_: MediaWireException) {} catch(_: SessionException) {}
        }
    }
    @Test fun volumeRequiresNegotiationAndRejectsStaleOrUnsupportedTargetsWithoutReplay() {
        val owner=MediaController(Dispatchers.Unconfined,{0L});val media=mutableListOf<MediaMessage>();val volume=mutableListOf<PlayerVolumeMessage>()
        owner.foreground(this);owner.attach("ble","b","Mac") { bytes -> MediaMessage.decode(bytes)?.let { media.add(it) } ?: run { volume.add(PlayerVolumeMessage.decode(bytes)!!) } }
        owner.receive("ble","b",MediaMessage(1,listOf(Cbor.Integer(1),Cbor.Bool(false))).encode())
        val sub=media.last { it.kind==2L }.string(0);owner.receive("ble","b",MediaMessage(3,listOf(Cbor.Text(sub))).encode())
        val root=JSONObject(javaClass.classLoader!!.getResource("media/media-vectors.json")!!.readText());val rows=root.getJSONArray("valid")
        val row=(0 until rows.length()).map { rows.getJSONObject(it) }.first { it.getString("name")=="snapshot" }
        val snapshot=MediaMessage.decode(hex(row.getString("bytesHex")))!!.let { it.copy(fields=it.fields.toMutableList().also { f->f[0]=Cbor.Text(sub) }) }
        owner.receive("ble","b",snapshot.encode());val target=owner.playback!!
        val sample=PlayerVolumeMessage(2,listOf(Cbor.Text(sub),Cbor.Text(target.source),Cbor.Text(target.revision),Cbor.Bool(true),Cbor.Integer(42)))
        owner.receive("ble","b",sample.encode());assertNull(owner.playerVolume);owner.commandVolume(55);assertEquals(0,volume.count { it.kind==3L })
        owner.receive("ble","b",PlayerVolumeMessage(1,listOf(Cbor.Integer(1))).encode());owner.receive("ble","b",sample.encode())
        assertEquals(42,owner.playerVolume);owner.commandVolume(101);assertEquals(0,volume.count { it.kind==3L })
        owner.commandVolume(55);assertEquals(55,owner.displayedVolume);val command=volume.last { it.kind==3L }
        owner.receive("ble","b",sample.encode());assertEquals(55,owner.displayedVolume)
        owner.receive("ble","b",PlayerVolumeMessage(4,listOf(command.fields[0],command.fields[1],Cbor.Integer(4))).encode())
        assertFalse(owner.busy);assertEquals(42,owner.displayedVolume);assertTrue(owner.feedback.contains("Allow"))
        owner.commandVolume(60);assertEquals(2,volume.count { it.kind==3L });owner.closed("ble");assertNull(owner.playerVolume);assertNull(owner.displayedVolume)
        owner.attach("ble","new","Mac") { bytes -> MediaMessage.decode(bytes)?.let { media.add(it) } ?: run { volume.add(PlayerVolumeMessage.decode(bytes)!!) } }
        owner.receive("ble","new",MediaMessage(1,listOf(Cbor.Integer(1),Cbor.Bool(false))).encode());owner.commandVolume(70,target)
        assertEquals(2,volume.count { it.kind==3L });owner.invalidate()
    }
    @Test fun appliedVolumeNeedsMatchingSampleOrReadableFixedDeadline() {
        var now=0L
        val waiters=mutableListOf<Pair<Long,CompletableDeferred<Unit>>>()
        val owner=MediaController(Dispatchers.Unconfined,{now},{ duration -> val gate=CompletableDeferred<Unit>();waiters.add(now+duration to gate);gate.await() })
        val media=mutableListOf<MediaMessage>();val volume=mutableListOf<PlayerVolumeMessage>()
        owner.foreground(this);owner.attach("ble","b","Mac") { bytes -> MediaMessage.decode(bytes)?.let { media.add(it) } ?: run { volume.add(PlayerVolumeMessage.decode(bytes)!!) } }
        owner.receive("ble","b",MediaMessage(1,listOf(Cbor.Integer(1),Cbor.Bool(false))).encode())
        val sub=media.last { it.kind==2L }.string(0);owner.receive("ble","b",MediaMessage(3,listOf(Cbor.Text(sub))).encode())
        val rows=JSONObject(javaClass.classLoader!!.getResource("media/media-vectors.json")!!.readText()).getJSONArray("valid")
        val row=(0 until rows.length()).map { rows.getJSONObject(it) }.first { it.getString("name")=="snapshot" }
        val snapshot=MediaMessage.decode(hex(row.getString("bytesHex")))!!.let { it.copy(fields=it.fields.toMutableList().also { f->f[0]=Cbor.Text(sub) }) }
        owner.receive("ble","b",snapshot.encode());val target=owner.playback!!
        owner.receive("ble","b",PlayerVolumeMessage(1,listOf(Cbor.Integer(1))).encode())
        fun sample(level: Long)=PlayerVolumeMessage(2,listOf(Cbor.Text(sub),Cbor.Text(target.source),Cbor.Text(target.revision),Cbor.Bool(true),Cbor.Integer(level))).encode()
        fun acknowledge() { val command=volume.last { it.kind==3L };owner.receive("ble","b",PlayerVolumeMessage(4,listOf(command.fields[0],command.fields[1],Cbor.Integer(0))).encode()) }
        owner.receive("ble","b",sample(42));owner.commandVolume(70);acknowledge()
        owner.receive("ble","b",sample(42));assertEquals(70,owner.displayedVolume)
        owner.receive("ble","b",sample(70));assertEquals(70,owner.displayedVolume);assertTrue(owner.feedback.isEmpty())
        owner.commandVolume(80);acknowledge();owner.receive("ble","b",sample(70));assertEquals(80,owner.displayedVolume)
        now=6000;waiters.filter { it.first<=now }.toList().forEach { it.second.complete(Unit) }
        assertEquals(70,owner.displayedVolume);assertTrue(owner.feedback.contains("not confirmed"));assertEquals(2,volume.count { it.kind==3L })
        owner.invalidate()
    }

}
