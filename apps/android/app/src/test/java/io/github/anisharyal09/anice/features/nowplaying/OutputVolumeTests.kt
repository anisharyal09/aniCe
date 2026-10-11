// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies independently negotiated output volume, bounded key intents and retirement without replay.
package io.github.anisharyal09.anice.features.nowplaying

import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class OutputVolumeTests {
    private fun hex(text: String)=text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    @Test fun independentScopeAndPositiveNegativeInventories() {
        val root=JSONObject(javaClass.classLoader!!.getResource("media/output-volume-vectors.json")!!.readText())
        val good=root.getJSONArray("valid");val bad=root.getJSONArray("invalid")
        assertTrue(good.length()>=9);assertTrue(bad.length()>=23)
        for(i in 0 until good.length()) {
            val bytes=hex(good.getJSONObject(i).getString("bytesHex"));val message=PlayerVolumeMessage.decode(bytes)!!
            assertEquals(VolumeScope.OUTPUT,message.scope);assertArrayEquals(bytes,message.encode());assertNull(MediaMessage.decode(bytes))
        }
        for(i in 0 until bad.length()) {
            try { PlayerVolumeMessage.decode(hex(bad.getJSONObject(i).getString("bytesHex")));fail("Accepted output negative") }
            catch(_: MediaWireException) {} catch(_: SessionException) {}
        }
    }
    private class Fixture {
        var now=0L
        val gates=mutableListOf<Pair<Long,CompletableDeferred<Unit>>>()
        val owner=MediaController(Dispatchers.Unconfined,{now},{ duration -> val gate=CompletableDeferred<Unit>();gates.add(now+duration to gate);gate.await() })
        val media=mutableListOf<MediaMessage>();val volume=mutableListOf<PlayerVolumeMessage>()
        lateinit var sub: String
        val device="11111111-1111-4111-8111-111111111111"
        val revision="22222222-2222-4222-8222-222222222222"
        fun connect() {
            owner.foreground(this);owner.attach("ble","b","Mac") { bytes -> MediaMessage.decode(bytes)?.let { media.add(it) } ?: run { volume.add(PlayerVolumeMessage.decode(bytes)!!) } }
            owner.receive("ble","b",MediaMessage(1,listOf(Cbor.Integer(1),Cbor.Bool(false))).encode())
            sub=media.last { it.kind==2L }.string(0);owner.receive("ble","b",MediaMessage(3,listOf(Cbor.Text(sub))).encode())
            val rows=JSONObject(javaClass.classLoader!!.getResource("media/media-vectors.json")!!.readText()).getJSONArray("valid")
            val row=(0 until rows.length()).map { rows.getJSONObject(it) }.first { it.getString("name")=="snapshot" }
            val bytes=row.getString("bytesHex").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            val sample=MediaMessage.decode(bytes)!!.let { it.copy(fields=it.fields.toMutableList().also { f->f[0]=Cbor.Text(sub) }) }
            owner.receive("ble","b",sample.encode())
        }
        fun negotiate() { owner.receive("ble","b",PlayerVolumeMessage(1,listOf(Cbor.Integer(1)),VolumeScope.OUTPUT).encode()) }
        fun sample(level: Long=40, id: String=device, rev: String=revision) { owner.receive("ble","b",PlayerVolumeMessage(2,listOf(Cbor.Text(sub),Cbor.Text(id),Cbor.Text(rev),Cbor.Bool(true),Cbor.Integer(level)),VolumeScope.OUTPUT).encode()) }
        fun ack(result: Long=0,scope: VolumeScope=VolumeScope.OUTPUT) { val command=volume.last { it.kind==3L };owner.receive("ble","b",PlayerVolumeMessage(4,listOf(command.fields[0],command.fields[1],Cbor.Integer(result)),scope).encode()) }
        fun advance() { now+=6000;gates.filter { it.first<=now }.toList().forEach { it.second.complete(Unit) } }
    }
    @Test fun keysRequireNegotiationAndCoalesceWithoutCrossScopeResults() {
        val f=Fixture();f.connect();f.sample();assertFalse(f.owner.canControlOutputVolume)
        f.negotiate();f.sample();assertTrue(f.owner.canControlOutputVolume);val old=f.owner.outputVolume!!
        f.owner.adjustOutputVolume(1);f.owner.adjustOutputVolume(1);f.owner.adjustOutputVolume(1)
        assertEquals(55,f.owner.displayedOutputVolume);assertEquals(1,f.volume.count { it.kind==3L })
        f.sample();assertEquals(55,f.owner.displayedOutputVolume)
        f.ack(scope=VolumeScope.PLAYER);assertTrue(f.owner.busy)
        f.ack();assertEquals(listOf(45L,55L),f.volume.filter { it.kind==3L }.map { it.number(4) })
        f.sample(45);assertEquals(55,f.owner.displayedOutputVolume);f.ack();f.sample(55);assertEquals(55,f.owner.displayedOutputVolume)
        assertFalse(f.owner.busy);assertNull(f.owner.playerVolume)
        f.owner.adjustOutputVolume(0);assertEquals(2,f.volume.count { it.kind==3L })
        f.sample(55,id="33333333-3333-4333-8333-333333333333");f.owner.commandOutputVolume(90,old);assertEquals(2,f.volume.count { it.kind==3L })
        f.owner.closed("ble");assertFalse(f.owner.canControlOutputVolume);assertNull(f.owner.displayedOutputVolume)
        f.connect();f.negotiate();f.sample();f.owner.commandOutputVolume(90,old);assertEquals(2,f.volume.count { it.kind==3L });f.owner.invalidate()
    }
    @Test fun uncertaintyDropsRetainedIntentAndDeviceReplacementCancelsPreview() {
        val f=Fixture();f.connect();f.negotiate();f.sample()
        f.owner.adjustOutputVolume(1);f.owner.adjustOutputVolume(1);f.advance()
        assertFalse(f.owner.busy);assertEquals(40,f.owner.displayedOutputVolume);assertTrue(f.owner.feedback.contains("unknown"));assertEquals(1,f.volume.count { it.kind==3L })
        f.sample();assertEquals(1,f.volume.count { it.kind==3L })
        f.owner.adjustOutputVolume(1);f.owner.adjustOutputVolume(1)
        f.sample(10,id="33333333-3333-4333-8333-333333333333");assertFalse(f.owner.busy);assertEquals(10,f.owner.displayedOutputVolume)
        f.ack();assertEquals(2,f.volume.count { it.kind==3L });f.owner.invalidate()
    }
    @Test fun appliedResultDoesNotConfirmPreviewAndFailureNeverReplays() {
        val f=Fixture();f.connect();f.negotiate();f.sample()
        f.owner.commandOutputVolume(80);f.ack();f.sample();assertEquals(80,f.owner.displayedOutputVolume)
        f.advance();assertEquals(40,f.owner.displayedOutputVolume);assertTrue(f.owner.feedback.contains("not confirmed"))
        f.owner.commandOutputVolume(70);f.owner.commandOutputVolume(90);f.ack(7)
        assertEquals(40,f.owner.displayedOutputVolume);assertFalse(f.owner.busy);assertEquals(2,f.volume.count { it.kind==3L });f.owner.invalidate()
    }
}
