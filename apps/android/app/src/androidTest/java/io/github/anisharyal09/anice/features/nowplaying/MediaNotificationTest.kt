// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies native media-session metadata, supported commands and silent notification retirement without UI automation.
package io.github.anisharyal09.anice.features.nowplaying

import android.app.NotificationManager
import android.media.MediaMetadata
import android.media.AudioManager
import android.media.VolumeProvider
import android.media.session.MediaController as SystemMediaController
import android.media.session.PlaybackState
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.Dispatchers
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class MediaNotificationTest {
    @Test fun nativePresentationUsesSourceBoundSeekAndRetiresWithoutAService() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=ApplicationProvider.getApplicationContext<AniCeApplication>()
        val owner=MediaController(Dispatchers.Main.immediate)
        val outgoing=mutableListOf<MediaMessage>()
        val commandArrived=java.util.concurrent.CountDownLatch(1)
        lateinit var presenter: MediaNotification
        var priorToken: android.media.session.MediaSession.Token? = null
        try {
        instrumentation.runOnMainSync {
            presenter=MediaNotification(app,owner);owner.presentationChanged=presenter::update
            owner.foreground(this);owner.attach("ble","native-notification-test","Fixture Mac") { val message=MediaMessage.decode(it)!!;outgoing.add(message);if(message.kind==6L) commandArrived.countDown() }
            owner.receive("ble","native-notification-test",MediaMessage(1,listOf(Cbor.Integer(1),Cbor.Bool(false))).encode())
            val sub=outgoing.last { it.kind==2L }.string(0)
            owner.receive("ble","native-notification-test",MediaMessage(3,listOf(Cbor.Text(sub))).encode())
            val vectors=JSONObject(instrumentation.context.assets.open("media/media-vectors.json").bufferedReader().use { it.readText() }).getJSONArray("valid")
            val row=(0 until vectors.length()).map { vectors.getJSONObject(it) }.first { it.getString("name")=="snapshot" }
            val bytes=row.getString("bytesHex").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            val sample=MediaMessage.decode(bytes)!!.let { it.copy(fields=it.fields.toMutableList().also { f->f[0]=Cbor.Text(sub) }) }
            owner.receive("ble","native-notification-test",sample.encode())
            assertTrue(owner.compactVisible)
        }
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync {
            val system=SystemMediaController(app,requireNotNull(presenter.token))
            assertEquals("Title 🎵",requireNotNull(system.metadata).getString(MediaMetadata.METADATA_KEY_TITLE))
            assertEquals(PlaybackState.STATE_PLAYING,requireNotNull(system.playbackState).state)
            assertTrue(requireNotNull(system.playbackState).actions and PlaybackState.ACTION_SEEK_TO!=0L)
            val nativePosition=requireNotNull(system.playbackState).position
            val localPosition=(requireNotNull(owner.playback).elapsed(android.os.SystemClock.elapsedRealtime())*1000).toLong()
            assertTrue(kotlin.math.abs(nativePosition-localPosition)<100)
            system.transportControls.seekTo(45000)
        }
        val manager=app.getSystemService(NotificationManager::class.java)
        fun awaitNotification(present: Boolean) {
            val deadline=android.os.SystemClock.elapsedRealtime()+2000
            while(manager.activeNotifications.any { it.id==4101 }!=present && android.os.SystemClock.elapsedRealtime()<deadline) Thread.sleep(25)
            assertEquals(present,manager.activeNotifications.any { it.id==4101 })
        }
        awaitNotification(true)
        assertTrue(commandArrived.await(3,java.util.concurrent.TimeUnit.SECONDS))
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync {
            assertEquals(1,outgoing.count { it.kind==6L });assertEquals(45000L,outgoing.last { it.kind==6L }.number(5))
            priorToken=presenter.token
            owner.attach("lan","handoff","Fixture Mac") { MediaMessage.decode(it)?.let(outgoing::add) }
            owner.receive("lan","handoff",MediaMessage(1,listOf(Cbor.Integer(1),Cbor.Bool(true))).encode())
            assertTrue(owner.awaitingSnapshot)
            presenter.update()
        }
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync {
            assertEquals("Connected handoff must preserve the native media session",priorToken,presenter.token)
            owner.closed("lan");owner.closed("ble")
        }
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync {
            assertNull("Full disconnection must retire the native media session",presenter.token)
            owner.background(this,false);assertFalse(owner.compactVisible)
            owner.invalidate()
        }
        awaitNotification(false)
        } finally { instrumentation.runOnMainSync { owner.invalidate() } }
    }
    @Test fun nativeRemoteVolumeProviderTargetsMacOutputAndRetires() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=ApplicationProvider.getApplicationContext<AniCeApplication>()
        val owner=MediaController(Dispatchers.Main.immediate)
        val media=mutableListOf<MediaMessage>();val volume=mutableListOf<PlayerVolumeMessage>()
        val arrived=java.util.concurrent.CountDownLatch(1)
        lateinit var presenter: MediaNotification
        lateinit var system: SystemMediaController
        lateinit var sub: String
        val device="11111111-1111-4111-8111-111111111111";val revision="22222222-2222-4222-8222-222222222222"
        try {
            instrumentation.runOnMainSync {
                presenter=MediaNotification(app,owner);owner.presentationChanged=presenter::update
                owner.foreground(this);owner.attach("ble","output-test","Fixture Mac") { bytes -> MediaMessage.decode(bytes)?.let { media.add(it) } ?: run { val message=PlayerVolumeMessage.decode(bytes)!!;volume.add(message);if(message.kind==3L) arrived.countDown() } }
                owner.receive("ble","output-test",MediaMessage(1,listOf(Cbor.Integer(1),Cbor.Bool(false))).encode())
                sub=media.last { it.kind==2L }.string(0);owner.receive("ble","output-test",MediaMessage(3,listOf(Cbor.Text(sub))).encode())
                val rows=JSONObject(instrumentation.context.assets.open("media/media-vectors.json").bufferedReader().use { it.readText() }).getJSONArray("valid")
                val row=(0 until rows.length()).map { rows.getJSONObject(it) }.first { it.getString("name")=="snapshot" }
                val bytes=row.getString("bytesHex").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
                val snapshot=MediaMessage.decode(bytes)!!.let { it.copy(fields=it.fields.toMutableList().also { f->f[0]=Cbor.Text(sub) }) }
                owner.receive("ble","output-test",snapshot.encode())
                owner.receive("ble","output-test",PlayerVolumeMessage(1,listOf(Cbor.Integer(1)),VolumeScope.OUTPUT).encode())
                owner.receive("ble","output-test",PlayerVolumeMessage(2,listOf(Cbor.Text(sub),Cbor.Text(device),Cbor.Text(revision),Cbor.Bool(true),Cbor.Integer(40)),VolumeScope.OUTPUT).encode())
            }
            instrumentation.waitForIdleSync()
            instrumentation.runOnMainSync {
                system=SystemMediaController(app,requireNotNull(presenter.token))
                assertEquals(VolumeProvider.VOLUME_CONTROL_ABSOLUTE,system.playbackInfo.volumeControl);assertEquals(20,system.playbackInfo.maxVolume);assertEquals(8,system.playbackInfo.currentVolume)
                system.adjustVolume(AudioManager.ADJUST_RAISE,0)
            }
            assertTrue(arrived.await(3,java.util.concurrent.TimeUnit.SECONDS));instrumentation.waitForIdleSync()
            instrumentation.runOnMainSync {
                val command=volume.single { it.kind==3L };assertEquals(VolumeScope.OUTPUT,command.scope);assertEquals(45L,command.number(4));assertEquals(device,command.string(2));assertNull(owner.playerVolume)
                owner.receive("ble","output-test",PlayerVolumeMessage(4,listOf(Cbor.Text(sub),command.fields[1],Cbor.Integer(0)),VolumeScope.OUTPUT).encode())
                owner.receive("ble","output-test",PlayerVolumeMessage(2,listOf(Cbor.Text(sub),Cbor.Text(device),Cbor.Text(revision),Cbor.Bool(true),Cbor.Integer(45)),VolumeScope.OUTPUT).encode())
                assertEquals(9,system.playbackInfo.currentVolume)
                owner.closed("ble");assertNull(presenter.token);assertFalse(owner.canControlOutputVolume);assertEquals(1,volume.count { it.kind==3L })
            }
        } finally { instrumentation.runOnMainSync { owner.invalidate() } }
    }

    @Test fun artworkLivesOnlyForTheCurrentRecording() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val owner = MediaController(Dispatchers.Main.immediate)
        val outgoing = mutableListOf<MediaMessage>()
        val bitmap = android.graphics.Bitmap.createBitmap(8,8,android.graphics.Bitmap.Config.ARGB_8888)
        val stream = java.io.ByteArrayOutputStream()
        assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,stream))
        val bytes = stream.toByteArray()
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
        lateinit var snapshot: MediaMessage
        fun subscribe(kind: String, token: String) {
            owner.attach(kind,token,"Mac") { MediaMessage.decode(it)?.let(outgoing::add) }
            owner.receive(kind,token,MediaMessage(1,listOf(Cbor.Integer(1),Cbor.Bool(kind=="lan"))).encode())
            val sub = outgoing.last { it.kind==2L }.string(0)
            owner.receive(kind,token,MediaMessage(3,listOf(Cbor.Text(sub))).encode())
            snapshot = snapshot.copy(fields=snapshot.fields.toMutableList().also { it[0]=Cbor.Text(sub) })
            owner.receive(kind,token,snapshot.encode())
        }
        try {
            instrumentation.runOnMainSync {
                val rows=JSONObject(instrumentation.context.assets.open("media/media-vectors.json").bufferedReader().use { it.readText() }).getJSONArray("valid")
                val row=(0 until rows.length()).map { rows.getJSONObject(it) }.first { it.getString("name")=="snapshot" }
                snapshot=MediaMessage.decode(row.getString("bytesHex").chunked(2).map { it.toInt(16).toByte() }.toByteArray())!!
                snapshot=snapshot.copy(fields=snapshot.fields.toMutableList().also { it[14]=Cbor.Bytes(hash) })
                owner.foreground(this)
                subscribe("lan","l1")
                owner.receive("lan","l1",MediaMessage(8,listOf(snapshot.fields[0],snapshot.fields[1],snapshot.fields[2],Cbor.Bytes(hash),Cbor.Integer(bytes.size.toLong()),Cbor.Integer(0),Cbor.Bytes(bytes))).encode())
            }
            val deadline=android.os.SystemClock.elapsedRealtime()+3000
            var loaded: android.graphics.Bitmap? = null
            while(loaded==null && android.os.SystemClock.elapsedRealtime()<deadline) {
                instrumentation.runOnMainSync { loaded=owner.artwork }
                if(loaded==null) Thread.sleep(10)
            }
            assertNotNull("Artwork did not decode",loaded)
            instrumentation.runOnMainSync {
                snapshot=snapshot.copy(fields=snapshot.fields.toMutableList().also { it[2]=Cbor.Text(java.util.UUID.randomUUID().toString()); it[10]=Cbor.Integer(snapshot.number(10) xor 16L) })
                owner.receive("lan","l1",snapshot.encode())
                assertSame("A control revision keeps the current cover",loaded,owner.artwork)
                val original=snapshot
                snapshot=snapshot.copy(fields=snapshot.fields.toMutableList().also { it[3]=Cbor.Text("Next recording") })
                owner.receive("lan","l1",snapshot.encode())
                assertNull("Changing tracks releases the previous cover",owner.artwork)
                owner.receive("lan","l1",original.encode())
                assertNull("Returning to a track must not restore historical artwork",owner.artwork)
                owner.closed("lan")
                subscribe("ble","b1")
                assertNull("Fresh subscriptions do not retain artwork",owner.artwork)
            }
        } finally { instrumentation.runOnMainSync { owner.invalidate() } }
    }

}
