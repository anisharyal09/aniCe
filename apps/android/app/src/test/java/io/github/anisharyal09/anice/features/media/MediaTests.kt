// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies independent wire fixtures, channel exclusivity, foreground leases and immutable command targets.
package io.github.anisharyal09.anice.features.media

import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject

class MediaTests {
    private val root get()=JSONObject(javaClass.classLoader!!.getResource("media/media-vectors.json")!!.readText())
    private fun hex(text: String)=text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun fixture(name: String): MediaMessage {
        val rows=root.getJSONArray("valid")
        for(i in 0 until rows.length()) { val row=rows.getJSONObject(i); if(row.getString("name")==name) return MediaMessage.decode(hex(row.getString("bytesHex")))!! }
        error("Missing fixture $name")
    }
    @Test fun independentFixtureInventoriesAndCanonicalEncoding() {
        val good=root.getJSONArray("valid"); val bad=root.getJSONArray("invalid")
        assertTrue(good.length()>=12);assertTrue(bad.length()>=28)
        for(i in 0 until good.length()) {
            val row=good.getJSONObject(i); val bytes=hex(row.getString("bytesHex")); val message=MediaMessage.decode(bytes)
            assertNotNull(row.getString("name"),message);assertEquals(row.getLong("kind"),message!!.kind);assertArrayEquals(bytes,message.encode())
        }
        for(i in 0 until bad.length()) {
            val row=bad.getJSONObject(i)
            try { MediaMessage.decode(hex(row.getString("bytesHex")));fail("Accepted ${row.getString("name")}") }
            catch(_: MediaWireException) {} catch(_: SessionException) {}
        }
    }
    private fun subscribed(owner: MediaController,kind: String,token: String,out: List<MediaMessage>) {
        val sub=out.last { it.kind==2L }.string(0)
        owner.receive(kind,token,MediaMessage(3,listOf(Cbor.Text(sub))).encode())
        val snapshot=fixture("snapshot").let { it.copy(fields=it.fields.toMutableList().also { f->f[0]=Cbor.Text(sub) }) }
        owner.receive(kind,token,snapshot.encode())
    }
    @Test fun prefersCompatibleLanSwitchesFreshAndNeverReplaysCommands() {
        val owner=MediaController(Dispatchers.Unconfined,{0L});val ble=mutableListOf<MediaMessage>();val lan=mutableListOf<MediaMessage>(); val activity=Any()
        owner.foreground(activity)
        owner.attach("ble","b1","Mac") { ble.add(MediaMessage.decode(it)!!) }
        owner.receive("ble","b1",fixture("capability").encode());subscribed(owner,"ble","b1",ble)
        owner.command(1);assertEquals(1,ble.count { it.kind==6L });assertEquals(0,lan.count { it.kind==6L })
        val oldTarget=owner.playback!!
        val oldSub=ble.last { it.kind==2L }.string(0)
        owner.attach("lan","l1","Mac") { lan.add(MediaMessage.decode(it)!!) }
        assertNotNull(owner.playback)
        owner.receive("lan","l1",fixture("capability").encode());assertNull(owner.playback);assertFalse(owner.busy)
        assertEquals(1,ble.count { it.kind==4L });assertNotEquals(oldSub,lan.last().string(0))
        subscribed(owner,"lan","l1",lan);owner.command(1,target=oldTarget);assertEquals(0,lan.count { it.kind==6L });owner.command(3)
        assertEquals(1,ble.count { it.kind==6L });assertEquals(1,lan.count { it.kind==6L })
        owner.closed("lan");assertNull(owner.playback);assertEquals(2,ble.count { it.kind==2L });assertEquals(1,ble.count { it.kind==6L })
        owner.invalidate()
    }
    @Test fun overlappingForegroundLeasesLegacyPeerAndStaleScrub() {
        val owner=MediaController(Dispatchers.Unconfined,{10L}); val out=mutableListOf<MediaMessage>();val a=Any();val b=Any()
        owner.attach("ble","b","Mac") { out.add(MediaMessage.decode(it)!!) };owner.foreground(a);assertTrue(out.isEmpty());assertTrue(owner.connected);assertFalse(owner.supported)
        owner.receive("ble","b",fixture("capability").encode());assertTrue(owner.supported);subscribed(owner,"ble","b",out)
        val captured=owner.playback!!;val changed=captured.message.copy(fields=captured.message.fields.toMutableList().also { it[2]=Cbor.Text("55555555-5555-4555-8555-555555555555") })
        owner.receive("ble","b",changed.encode());owner.command(4,5000,captured);assertEquals(0,out.count { it.kind==6L })
        owner.foreground(b);owner.background(a,false);assertNotNull(owner.playback)
        owner.background(b,false);assertNull(owner.playback);assertEquals(1,out.count { it.kind==4L })
        owner.foreground(a);assertEquals(2,out.count { it.kind==2L });owner.invalidate()
    }
    @Test fun backpressureRetainsOnlyUnsentWorkAndChannelReplacementCancelsIt() {
        val owner=MediaController(Dispatchers.Unconfined,{0L});var full=true;val sent=mutableListOf<MediaMessage>()
        owner.foreground(this);owner.attach("ble","b","Mac") { if(full) throw SessionBackpressure();sent.add(MediaMessage.decode(it)!!) }
        owner.receive("ble","b",fixture("capability").encode());assertTrue(sent.isEmpty())
        full=false;owner.capacity("ble");assertEquals(1,sent.size);subscribed(owner,"ble","b",sent)
        full=true;owner.command(1);assertTrue(owner.busy)
        owner.attach("ble","new","Mac") { sent.add(MediaMessage.decode(it)!!) };assertNull(owner.playback);assertFalse(owner.busy)
        owner.receive("ble","new",fixture("capability").encode());assertEquals(0,sent.count { it.kind==6L });owner.invalidate()
    }
    @Test fun progressUsesPositionRateSampleAndBoundsUnknownDuration() {
        val sample=RemotePlayback(fixture("snapshot"),0)
        assertEquals(12f,sample.elapsed(2000),0.01f);assertEquals(200f,sample.elapsed(999999),0.01f)
        val paused=RemotePlayback(sample.message.copy(fields=sample.message.fields.toMutableList().also { it[6]=Cbor.Integer(2) }),0)
        assertEquals(10f,paused.elapsed(999999),0.01f)
        assertEquals(-1,RemotePlayback(fixture("live-stream"),0).duration.toInt())
    }
    @Test fun seekPreviewSurvivesOldSamplesAndAppliedResultUntilPositionConfirmation() {
        var now=0L
        val owner=MediaController(Dispatchers.Unconfined,{now});val out=mutableListOf<MediaMessage>()
        owner.foreground(this);owner.attach("ble","b","Mac") { out.add(MediaMessage.decode(it)!!) }
        owner.receive("ble","b",fixture("capability").encode());subscribed(owner,"ble","b",out)
        val old=owner.playback!!
        owner.command(4,90000,old)
        assertEquals(90f,owner.displayedPlayback!!.elapsed(now),0.01f)
        assertEquals(10f,owner.playback!!.elapsed(now),0.01f)
        owner.receive("ble","b",old.message.encode())
        val command=out.last { it.kind==6L }
        owner.receive("ble","b",MediaMessage(7,listOf(command.fields[0],command.fields[1],Cbor.Integer(0))).encode())
        assertFalse(owner.busy);now=500
        assertEquals(90.5f,owner.displayedPlayback!!.elapsed(now),0.01f)
        val confirmed=old.message.copy(fields=old.message.fields.toMutableList().also { it[7]=Cbor.Integer(90500) })
        owner.receive("ble","b",confirmed.encode())
        assertSame(owner.playback,owner.displayedPlayback)
        assertEquals(1,out.count { it.kind==6L });owner.invalidate()
    }
    @Test fun seekPreviewClearsOnFailureReplacementAndDisconnect() {
        val owner=MediaController(Dispatchers.Unconfined,{0L});val out=mutableListOf<MediaMessage>()
        owner.foreground(this);owner.attach("ble","b","Mac") { out.add(MediaMessage.decode(it)!!) }
        owner.receive("ble","b",fixture("capability").encode());subscribed(owner,"ble","b",out)
        for(result in 1L..7L) {
            owner.command(4,90000)
            val command=out.last { it.kind==6L }
            owner.receive("ble","b",MediaMessage(7,listOf(command.fields[0],command.fields[1],Cbor.Integer(result))).encode())
            assertSame(owner.playback,owner.displayedPlayback);assertFalse(owner.busy)
        }
        val captured=owner.playback!!;owner.command(4,90000)
        val replaced=captured.message.copy(fields=captured.message.fields.toMutableList().also { it[2]=Cbor.Text("55555555-5555-4555-8555-555555555555") })
        owner.receive("ble","b",replaced.encode());assertSame(owner.playback,owner.displayedPlayback)
        owner.closed("ble");assertNull(owner.displayedPlayback);assertFalse(owner.busy);owner.invalidate()
    }
    @Test fun seekPreviewExpiresWithoutConfirmationAndNeverRetries() = runBlocking {
        val owner=MediaController(Dispatchers.Unconfined,{0L});val out=mutableListOf<MediaMessage>()
        val uncertain=MediaController(Dispatchers.Unconfined,{0L});val unsent=mutableListOf<MediaMessage>()
        owner.foreground(this);owner.attach("ble","b","Mac") { out.add(MediaMessage.decode(it)!!) }
        owner.receive("ble","b",fixture("capability").encode());subscribed(owner,"ble","b",out)
        uncertain.foreground(this);uncertain.attach("ble","b","Mac") { unsent.add(MediaMessage.decode(it)!!) }
        uncertain.receive("ble","b",fixture("capability").encode());subscribed(uncertain,"ble","b",unsent)
        uncertain.command(4,90000)
        owner.command(4,90000)
        val command=out.last { it.kind==6L }
        owner.receive("ble","b",MediaMessage(7,listOf(command.fields[0],command.fields[1],Cbor.Integer(0))).encode())
        delay(6200)
        assertSame(owner.playback,owner.displayedPlayback);assertFalse(owner.busy)
        assertEquals(1,out.count { it.kind==6L });owner.invalidate()
        assertSame(uncertain.playback,uncertain.displayedPlayback);assertFalse(uncertain.busy)
        assertTrue(uncertain.feedback.contains("unknown"));assertEquals(1,unsent.count { it.kind==6L });uncertain.invalidate()
    }
    @Test fun artworkSequentialBoundsFixedDeadlineSupersessionAndHashFailure() {
        val assembly=MediaArtwork();val bytes=ByteArray(4096) { it.toByte() };val hash=java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
        assertNull(assembly.accept(hash,4096,2048,bytes.copyOfRange(2048,4096),0))
        assertNull(assembly.accept(hash,4096,0,bytes.copyOfRange(0,2048),0))
        assertArrayEquals(bytes,assembly.accept(hash,4096,2048,bytes.copyOfRange(2048,4096),9999))
        assertNull(assembly.accept(hash,4096,0,bytes.copyOfRange(0,2048),10000))
        assembly.reset();assertNull(assembly.accept(hash,4096,0,bytes.copyOfRange(0,2048),0))
        assertNull(assembly.accept(hash,4096,2048,bytes.copyOfRange(2048,4096),10000))
        assertNull(assembly.accept(hash,4096,0,bytes.copyOfRange(0,2048),10001))
        assembly.reset();assertNull(assembly.accept(hash,4096,0,bytes.copyOfRange(0,2048),0))
        assertNull(assembly.accept(hash,4096,0,bytes.copyOfRange(0,2048),1))
        assertNull(assembly.accept(hash,4096,2048,bytes.copyOfRange(2048,4096),2))
        assembly.reset();assertNull(assembly.accept(hash,4096,0,bytes.copyOfRange(0,2048),0))
        assertNull(assembly.accept(hash,4096,2048,ByteArray(2048),1))
        assembly.reset();assertNull(assembly.accept(hash,65537,0,bytes.copyOfRange(0,2048),0))
        assertNull(assembly.accept(hash,4096,0,ByteArray(2049),0))
        assembly.reset();assertNull(assembly.accept(hash,4096,0,bytes.copyOfRange(0,2048),0));assembly.reset()
        assertNull(assembly.accept(hash,4096,2048,bytes.copyOfRange(2048,4096),1))
    }

}
