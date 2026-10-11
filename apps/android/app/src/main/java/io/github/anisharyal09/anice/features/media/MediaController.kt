// SPDX-License-Identifier: GPL-3.0-or-later
// Owns foreground media subscriptions over exactly one existing authenticated channel.
package io.github.anisharyal09.anice.features.media

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.SystemClock
import androidx.compose.runtime.*
import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*
import java.util.UUID

 data class RemotePlayback(val message: MediaMessage, val sampledAt: Long = SystemClock.elapsedRealtime()) {
    val source get()=message.string(1)
    val revision get()=message.string(2)
    val title get()=message.string(3)
    val artist get()=message.string(4)
    val player get()=message.string(5)
    val state get()=message.number(6)
    val duration get()=message.number(8)
    val actions get()=message.number(10)
    val selection get()=message.string(11)
    val catalogue get()=message.string(12)
    val sources get()=(message.fields[13] as Cbor.Array).value.map { (it as Cbor.Array).value.let { row -> (row[0] as Cbor.Text).value to (row[1] as Cbor.Text).value } }
    val hash get()=(message.fields[14] as Cbor.Bytes).value
    fun elapsed(now: Long): Float {
        val position=message.number(7)
        if(position<0) return 0f
        val value=position.toDouble()/1000 + if(state==1L) maxOf(0,now-sampledAt)*message.number(9)/1000000.0 else 0.0
        return (if(duration>0) minOf(value,duration/1000.0) else value).toFloat()
    }
}
class MediaController(private val dispatcher: CoroutineDispatcher=Dispatchers.Main.immediate, private val clock: ()->Long=SystemClock::elapsedRealtime) {
    private class Link(val token: String, val origin: String, val send: suspend (ByteArray)->Unit) {
        var capable=false
        val queue=ArrayDeque<MediaMessage>()
        var sending=false
        var wake=false
    }
    private val scope=CoroutineScope(SupervisorJob()+dispatcher)
    private val links=mutableMapOf<String,Link>()
    private val presentations=mutableSetOf<Any>()
    private var backgroundJob: Job?=null
    private var active: String?=null
    private var subscription: String?=null
    private var acknowledged=false
    private var counter=0L
    private var pending: Long?=null
    private var timeout: Job?=null
    private var seekTimeout: Job?=null
    private var seekPreview by mutableStateOf<RemotePlayback?>(null)
    private var artTimeout: Job?=null
    private val assembly=MediaArtwork()
    var connected by mutableStateOf(false); private set
    var supported by mutableStateOf(false); private set
    var awaitingSnapshot by mutableStateOf(false); private set
    var playback by mutableStateOf<RemotePlayback?>(null); private set
    val displayedPlayback get()=seekPreview ?: playback
    var artwork by mutableStateOf<Bitmap?>(null); private set
    var origin by mutableStateOf(""); private set
    var feedback by mutableStateOf(""); private set
    var busy by mutableStateOf(false); private set
    fun attach(kind: String, token: String, origin: String, send: suspend (ByteArray)->Unit) {
        if(links[kind]?.token==token) return
        closed(kind); links[kind]=Link(token,origin,send); choose()
    }
    fun closed(kind: String) {
        if(active==kind) retire()
        links.remove(kind); choose()
    }
    fun invalidate() { scope.launch { retire(); links.clear(); connected=false; supported=false } }
    fun foreground(presentation: Any) { backgroundJob?.cancel(); backgroundJob=null; presentations.add(presentation); choose() }
    fun background(presentation: Any, changing: Boolean) {
        presentations.remove(presentation)
        if(presentations.isNotEmpty()) return
        if(changing) { backgroundJob=scope.launch { delay(1000); if(presentations.isEmpty()) retire() } }
        else retire()
    }
    private fun choose() {
        connected=links.isNotEmpty(); supported=links.values.any { it.capable }
        if(presentations.isEmpty()) return
        val kind=if(links["lan"]?.capable==true) "lan" else if(links["ble"]?.capable==true) "ble" else null
        if(kind==active) return
        retire()
        if(kind!=null) {
            active=kind; awaitingSnapshot=true; subscription=UUID.randomUUID().toString(); counter=0; origin=links.getValue(kind).origin
            queue(kind,MediaMessage(2,listOf(Cbor.Text(subscription!!))))
        }
    }
    private fun clearArtwork() { artTimeout?.cancel(); artTimeout=null; assembly.reset(); artwork=null }
    private fun clearSeek() { seekTimeout?.cancel(); seekTimeout=null; seekPreview=null }
    private fun retire() {
        val old=active; val sub=subscription
        active=null; subscription=null; acknowledged=false; awaitingSnapshot=false; playback=null; origin=""; busy=false; pending=null; timeout?.cancel(); timeout=null; feedback=""; clearArtwork(); clearSeek()
        if(old!=null && sub!=null) {
            links[old]?.queue?.clear()
            queue(old,MediaMessage(4,listOf(Cbor.Text(sub))))
        }
    }
    fun receive(kind: String, token: String, bytes: ByteArray): Boolean {
        val message=try { MediaMessage.decode(bytes) } catch(_: MediaWireException) { return true } catch(_: SessionException) { return false }
        if(message==null) return false
        val link=links[kind] ?: return true
        if(link.token!=token) return true
        if(message.kind==1L) { link.capable=true; choose(); return true }
        if(kind!=active || message.string(0)!=subscription) return true
        when(message.kind) {
            3L -> acknowledged=true
            5L -> if(acknowledged) {
                val next=RemotePlayback(message,clock())
                val old=playback
                if(old?.source!=next.source || old.revision!=next.revision || !old.hash.contentEquals(next.hash)) clearArtwork()
                seekPreview?.let { preview ->
                    if(preview.source!=next.source || preview.revision!=next.revision || kotlin.math.abs(preview.elapsed(clock())-next.elapsed(clock()))<=1f) clearSeek()
                }
                playback=next; awaitingSnapshot=false
            }
            7L -> if(pending==message.number(1)) {
                pending=null; busy=false; timeout?.cancel(); timeout=null
                if(message.number(2)!=0L) clearSeek()
                feedback=when(message.number(2)) { 0L->"";1L->"Playback changed. Try again.";2L->"This player does not support that action.";3L,4L->"Allow playback control on your Mac.";5L->"Player unavailable.";6L->"Player busy. Try again.";else->"Playback action failed." }
            }
            8L -> if(kind=="lan" && acknowledged) acceptArtwork(message)
        }
        return true
    }
    private fun acceptArtwork(message: MediaMessage) {
        val snapshot=playback ?: return
        val hash=(message.fields[3] as Cbor.Bytes).value
        if(message.string(1)!=snapshot.source || message.string(2)!=snapshot.revision || !hash.contentEquals(snapshot.hash)) return
        val buffer=assembly.accept(hash,message.number(4).toInt(),message.number(5).toInt(),(message.fields[6] as Cbor.Bytes).value,clock())
        if(message.number(5)==0L && artTimeout==null) artTimeout=scope.launch { delay(10000); assembly.expire(clock()); artTimeout=null }
        if(buffer==null) return
        artTimeout?.cancel();artTimeout=null
        val options=BitmapFactory.Options().apply { inJustDecodeBounds=true }
        BitmapFactory.decodeByteArray(buffer,0,buffer.size,options)
        if(options.outWidth !in 1..256 || options.outHeight !in 1..256 || options.outMimeType !in listOf("image/jpeg","image/png")) return
        artwork=BitmapFactory.decodeByteArray(buffer,0,buffer.size)
    }
    fun command(action: Long, value: Long=0, target: RemotePlayback?=playback, selection: String="") {
        val kind=active ?: return; val sub=subscription ?: return; val snapshot=target ?: return
        if(busy || !acknowledged || snapshot.message.string(0)!=sub || snapshot.source!=playback?.source || snapshot.revision!=playback?.revision) return
        if(action !in 1..6 || (action==4L && (value<0 || value>snapshot.duration))) return
        if(counter==4294967295L) { retire(); choose(); return }
        val id=++counter
        val source=if(action==5L) selection else if(action==6L) "" else snapshot.source
        val revision=if(action>=5) snapshot.catalogue else snapshot.revision
        clearSeek()
        if(action==4L) {
            seekPreview=RemotePlayback(snapshot.message.copy(fields=snapshot.message.fields.toMutableList().also { it[7]=Cbor.Integer(value) }),clock())
            // An applied result acknowledges delivery; only a position sample confirms the displayed seek.
            seekTimeout=scope.launch { delay(6000); seekPreview=null; seekTimeout=null }
        }
        busy=true; pending=id; feedback=""
        queue(kind,MediaMessage(6,listOf(Cbor.Text(sub),Cbor.Integer(id),Cbor.Text(source),Cbor.Text(revision),Cbor.Integer(action),Cbor.Integer(value))))
        timeout=scope.launch { delay(6000); if(pending==id) { pending=null; busy=false; clearSeek(); feedback="Action outcome unknown. It will not be retried."; links[kind]?.queue?.removeAll { it.kind==6L && it.number(1)==id } } }
    }
    private fun queue(kind: String, message: MediaMessage) { links[kind]?.let { if(it.queue.size<16) it.queue.addLast(message) }; capacity(kind) }
    fun capacity(kind: String) {
        val link=links[kind] ?: return
        if(link.sending) { link.wake=true; return }
        link.sending=true
        scope.launch {
            try {
                while(links[kind]===link && link.queue.isNotEmpty()) {
                    val message=link.queue.first()
                    try { link.send(message.encode()) } catch(_: SessionBackpressure) { return@launch } catch(_: SessionException) { closed(kind); return@launch } catch(error: Exception) { if(error is CancellationException) throw error; closed(kind); return@launch }
                    if(link.queue.firstOrNull()===message) link.queue.removeFirst()
                }
            } finally { link.sending=false; if(link.wake) { link.wake=false; capacity(kind) } }
        }
    }
}
