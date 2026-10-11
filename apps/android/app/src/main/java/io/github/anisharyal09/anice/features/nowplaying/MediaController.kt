// SPDX-License-Identifier: GPL-3.0-or-later
// Owns foreground or companion-leased media over exactly one existing authenticated channel.
package io.github.anisharyal09.anice.features.nowplaying

import io.github.anisharyal09.anice.infrastructure.connections.*
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.SystemClock
import androidx.compose.runtime.*
import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*
import java.util.UUID

 data class RemotePlayback(val message: MediaMessage, val sampledAt: Long = SystemClock.elapsedRealtime(), val frozen: Boolean=false) {
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
        val value=position.toDouble()/1000 + if(state==1L && !frozen) maxOf(0,now-sampledAt)*message.number(9)/1000000.0 else 0.0
        return (if(duration>0) minOf(value,duration/1000.0) else value).toFloat()
    }
}
private sealed interface MediaSubmission {
    val commandID: Long?
    val seek: Boolean
    fun encode(): ByteArray
    data class Playback(val message: MediaMessage): MediaSubmission {
        override val commandID get()=if(message.kind==6L) message.number(1) else null
        override val seek get()=message.kind==6L && message.number(4)==4L
        override fun encode()=message.encode()
    }
    data class Volume(val message: PlayerVolumeMessage): MediaSubmission {
        override val commandID get()=if(message.kind==3L) message.number(1) else null
        override val seek=false
        override fun encode()=message.encode()
    }
}
data class RemoteOutputVolume(val subscription: String,val device: String,val revision: String,val level: Int)

class MediaController(private val dispatcher: CoroutineDispatcher=Dispatchers.Main.immediate, private val clock: ()->Long=SystemClock::elapsedRealtime, private val wait: suspend (Long)->Unit={ delay(it) }) : FeatureHandler {
    override fun available(channel: SecuredChannel) { val d=channel.descriptor; attach(d.transport,d.instance,d.peer.deviceName,channel::sendData) }
    override fun retired(descriptor: ChannelDescriptor) { closed(descriptor.transport) }
    override fun capacityAvailable(descriptor: ChannelDescriptor) { capacity(descriptor.transport) }
    override fun handle(descriptor: ChannelDescriptor, bytes: ByteArray) = handleData(descriptor.transport,descriptor.instance,bytes)
    private class Link(val token: String, val origin: String, val send: suspend (ByteArray)->Unit) {
        var capable=false
        var volumeCapable=false
        var outputCapable=false
        val queue=ArrayDeque<MediaSubmission>()
        var sending=false
        var wake=false
    }
    private val scope=CoroutineScope(SupervisorJob()+dispatcher)
    private val links=mutableMapOf<String,Link>()
    private val presentations=mutableSetOf<Any>()
    var foregroundVisible by mutableStateOf(false); private set
    private var backgroundJob: Job?=null
    private var active: String?=null
    private var subscription: String?=null
    private var acknowledged=false
    private var counter=0L
    private var pending: Long?=null
    private var timeout: Job?=null
    private var seekTimeout: Job?=null
    private sealed interface SeekPresentation {
        data object Authoritative : SeekPresentation
        data class Dragging(val target: RemotePlayback, val preview: RemotePlayback) : SeekPresentation
        data class Pending(val preview: RemotePlayback, val deadline: Long) : SeekPresentation
    }
    private data class SeekIntent(val value: Long, val target: RemotePlayback)
    private var seekPresentation by mutableStateOf<SeekPresentation>(SeekPresentation.Authoritative)
    private var retainedSeek: SeekIntent?=null
    private var seekGestureCancelled=false
    private var submitted=false
    private var pendingVolume=false
    private var pendingOutput=false
    var outputVolume by mutableStateOf<RemoteOutputVolume?>(null);private set
    private var outputPreview by mutableStateOf<Int?>(null)
    private var outputTimeout: Job?=null
    private var retainedOutput: Pair<Int,RemoteOutputVolume>?=null
    val displayedOutputVolume get()=outputPreview ?: outputVolume?.level
    val canControlOutputVolume get()=acknowledged && compactVisible && outputVolume!=null
    private var volumePreview by mutableStateOf<Int?>(null)
    var playerVolume by mutableStateOf<Int?>(null);private set
    val displayedVolume get()=volumePreview ?: playerVolume
    private var volumeTimeout: Job?=null
    var trace: (String,Long)->Unit={ _,_ -> }
    var presentationChanged: ()->Unit={}
    private var companion=false
    private var pauseDeadline: Long?=null
    private var pauseJob: Job?=null
    var compactVisible by mutableStateOf(false); private set
    var openWorkspaceRequest by mutableStateOf(false); private set
    fun openWorkspace() { openWorkspaceRequest=true }
    fun workspaceOpened() { openWorkspaceRequest=false }
    fun companionOwnershipChanged(available: Boolean) { companion=available; if(presentations.isEmpty()) { if(!available) retire() else choose() }; presentationChanged() }
    private fun refreshPresentation() {
        val current=playback
        if(current==null || current.source.isEmpty() || current.state !in 1L..2L) {
            pauseJob?.cancel();pauseJob=null;pauseDeadline=null;compactVisible=false
        } else if(current.state==1L) {
            pauseJob?.cancel();pauseJob=null;pauseDeadline=null;compactVisible=true
        } else if(pauseDeadline==null) {
            val deadline=clock()+90000;pauseDeadline=deadline;compactVisible=true
            pauseJob=scope.launch { wait(90000); if(pauseDeadline==deadline) { compactVisible=false;pauseJob=null;presentationChanged() } }
        }
        presentationChanged()
    }
    private var artTimeout: Job?=null
    private val assembly=MediaArtwork()
    var connected by mutableStateOf(false); private set
    var supported by mutableStateOf(false); private set
    var awaitingSnapshot by mutableStateOf(false); private set
    var playback by mutableStateOf<RemotePlayback?>(null); private set
    val displayedPlayback get()=when(val state=seekPresentation) {
        SeekPresentation.Authoritative -> playback
        is SeekPresentation.Dragging -> state.preview
        is SeekPresentation.Pending -> state.preview
    }
    val draggingSeek get()=seekPresentation is SeekPresentation.Dragging
    val canSeek get()=acknowledged && playback?.let { it.source.isNotEmpty() && it.actions and 8L!=0L && it.duration>0 }==true
    private fun sameTarget(target: RemotePlayback) = target.message.string(0)==subscription && target.source==playback?.source && target.revision==playback?.revision
    private fun positionPreview(target: RemotePlayback, value: Long, frozen: Boolean=false) = RemotePlayback(target.message.copy(fields=target.message.fields.toMutableList().also { it[7]=Cbor.Integer(value) }),clock(),frozen)
    fun beginSeek() { seekGestureCancelled=false;val target=playback ?: return; if(!canSeek) return; seekPresentation=SeekPresentation.Dragging(target,displayedPlayback ?: target) }
    fun dragSeek(value: Long) {
        if(seekGestureCancelled) return
        if(seekPresentation !is SeekPresentation.Dragging) beginSeek()
        val dragging=seekPresentation as? SeekPresentation.Dragging ?: return
        if(!sameTarget(dragging.target)) { clearSeek();return }
        seekPresentation=SeekPresentation.Dragging(dragging.target,positionPreview(dragging.target,value.coerceIn(0,dragging.target.duration),true))
    }
    fun cancelSeekDrag() { if(draggingSeek) clearSeek();seekGestureCancelled=false }
    fun releaseSeek() {
        val dragging=seekPresentation as? SeekPresentation.Dragging ?: run { seekGestureCancelled=false;return }
        seekGestureCancelled=false
        command(4,dragging.preview.message.number(7),dragging.target)
    }
    private fun previewSeek(intent: SeekIntent) {
        seekTimeout?.cancel()
        val deadline=clock()+6000
        seekPresentation=SeekPresentation.Pending(positionPreview(intent.target,intent.value),deadline)
        seekTimeout=scope.launch { wait(6000); if((seekPresentation as? SeekPresentation.Pending)?.deadline==deadline) { clearSeek();feedback="Position was not confirmed. Showing the player’s latest position.";presentationChanged() } }
        presentationChanged()
    }
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
    fun foreground(presentation: Any) { backgroundJob?.cancel(); backgroundJob=null; presentations.add(presentation);foregroundVisible=true; choose() }
    fun background(presentation: Any, changing: Boolean) {
        presentations.remove(presentation);foregroundVisible=presentations.isNotEmpty()
        if(presentations.isNotEmpty()) return
        cancelSeekDrag()
        if(changing) { backgroundJob=scope.launch { wait(1000); if(presentations.isEmpty()) { if(companion) choose() else retire() } } }
        else { if(companion) choose() else retire() }
    }
    private fun choose() {
        connected=links.isNotEmpty(); supported=links.values.any { it.capable }
        if(presentations.isEmpty() && !companion) return
        val kind=if(presentations.isNotEmpty() && links["lan"]?.capable==true) "lan" else if(links["ble"]?.capable==true) "ble" else null
        if(kind==active) return
        retire()
        if(kind!=null) {
            active=kind; awaitingSnapshot=true; subscription=UUID.randomUUID().toString(); counter=0; origin=links.getValue(kind).origin
            queue(kind,MediaMessage(2,listOf(Cbor.Text(subscription!!))))
        }
    }
    private fun clearArtwork() { artTimeout?.cancel(); artTimeout=null; assembly.reset(); artwork=null }
    private fun clearSeek() { if(draggingSeek) seekGestureCancelled=true;seekTimeout?.cancel(); seekTimeout=null; retainedSeek=null; seekPresentation=SeekPresentation.Authoritative }
    private fun clearVolume() { volumeTimeout?.cancel();volumeTimeout=null;volumePreview=null;playerVolume=null }
    private fun retire() {
        val old=active; val sub=subscription
        active=null; subscription=null; acknowledged=false; awaitingSnapshot=false; playback=null; origin=""; busy=false; pending=null; timeout?.cancel(); timeout=null; feedback=""; clearArtwork(); clearSeek();clearVolume();clearOutputVolume();submitted=false;pendingVolume=false;pendingOutput=false;refreshPresentation()
        if(old!=null && sub!=null) {
            links[old]?.queue?.clear()
            queue(old,MediaMessage(4,listOf(Cbor.Text(sub))))
        }
    }
    fun receive(kind: String, token: String, bytes: ByteArray)=handleData(kind,token,bytes)!=DataHandling.UNRECOGNIZED
    private fun handleData(kind: String, token: String, bytes: ByteArray): DataHandling {
        return try {
            val media=MediaMessage.decode(bytes)
            if(media!=null) { receiveMedia(kind,token,media);DataHandling.HANDLED }
            else {
                val volume=PlayerVolumeMessage.decode(bytes)
                if(volume!=null) { receiveVolume(kind,token,volume);DataHandling.HANDLED } else DataHandling.UNRECOGNIZED
            }
        } catch(_: MediaWireException) { DataHandling.DISCARDED } catch(_: SessionException) { DataHandling.UNRECOGNIZED }
    }
    private fun receiveMedia(kind: String, token: String, message: MediaMessage): Boolean {
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
                if(old?.source!=next.source || old.revision!=next.revision) clearVolume()
                val presentation=seekPresentation
                val preview=when(presentation) { is SeekPresentation.Pending->presentation.preview;is SeekPresentation.Dragging->presentation.preview;else->null }
                if(preview!=null && (preview.message.string(0)!=next.message.string(0) || preview.source!=next.source || preview.revision!=next.revision || next.actions and 8L==0L)) clearSeek()
                else if(presentation is SeekPresentation.Pending && retainedSeek==null && kotlin.math.abs(presentation.preview.elapsed(clock())-next.elapsed(clock()))<=1f) clearSeek()
                val pendingPreview=seekPresentation as? SeekPresentation.Pending
                if(pendingPreview!=null && pendingPreview.preview.state!=next.state) {
                    val fields=pendingPreview.preview.message.fields.toMutableList()
                    fields[7]=Cbor.Integer((pendingPreview.preview.elapsed(clock())*1000).toLong());fields[6]=next.message.fields[6];fields[9]=next.message.fields[9]
                    seekPresentation=pendingPreview.copy(preview=RemotePlayback(pendingPreview.preview.message.copy(fields=fields),clock()))
                }
                playback=next; awaitingSnapshot=false;trace("sample",clock());refreshPresentation()
            }
            7L -> if(!pendingVolume && pending==message.number(1)) {
                trace("result ${message.number(2)}",clock())
                pending=null; busy=false; submitted=false; timeout?.cancel(); timeout=null
                if(message.number(2)!=0L) clearSeek()
                feedback=when(message.number(2)) { 0L->"";1L->"Playback changed. Try again.";2L->"This player does not support that action.";3L,4L->"Allow playback control on your Mac.";5L->"Player unavailable.";6L->"Player busy. Try again.";else->"Playback action failed." }
                if(message.number(2)==0L) {
                    val intent=retainedSeek;retainedSeek=null
                    if(intent!=null && sameTarget(intent.target)) submitCommand(4,intent.value,intent.target,"")
                }
                presentationChanged()
            }
            8L -> if(kind=="lan" && acknowledged) acceptArtwork(message)
        }
        return true
    }
    private fun receiveVolume(kind: String, token: String, message: PlayerVolumeMessage): Boolean {
        if(message.scope==VolumeScope.OUTPUT) return receiveOutputVolume(kind,token,message)
        val link=links[kind] ?: return true
        if(link.token!=token) return true
        if(message.kind==1L) {
            if(!link.volumeCapable) { link.volumeCapable=true;enqueue(kind,MediaSubmission.Volume(PlayerVolumeMessage(1,listOf(Cbor.Integer(1))))) }
            return true
        }
        if(kind!=active || message.string(0)!=subscription || !link.volumeCapable || !acknowledged) return true
        when(message.kind) {
            2L -> {
                val target=playback ?: return true
                if(message.string(1)!=target.source || message.string(2)!=target.revision) return true
                playerVolume=if((message.fields[3] as Cbor.Bool).value) message.number(4).toInt() else null
                if(playerVolume==null && volumePreview!=null) feedback="Player volume became unavailable."
                if(playerVolume==null || playerVolume==volumePreview) { volumeTimeout?.cancel();volumeTimeout=null;volumePreview=null }
                presentationChanged()
            }
            4L -> if(pendingVolume && !pendingOutput && pending==message.number(1)) {
                trace("volume result ${message.number(2)}",clock())
                pending=null;busy=false;submitted=false;pendingVolume=false;timeout?.cancel();timeout=null
                val result=message.number(2)
                if(result!=0L) { clearSeek();volumeTimeout?.cancel();volumeTimeout=null;volumePreview=null }
                feedback=when(result) { 0L->"";1L->"Playback changed. Try again.";2L->"Player volume unavailable.";3L,4L->"Allow player volume on your Mac.";5L->"Player unavailable.";6L->"Player busy. Try again.";else->"Player volume action failed." }
                if(result==0L) { val intent=retainedSeek;retainedSeek=null;if(intent!=null && sameTarget(intent.target)) submitCommand(4,intent.value,intent.target,"") }
                presentationChanged()
            }
        }
        return true
    }
    private fun sameOutput(target: RemoteOutputVolume)=outputVolume?.let { it.subscription==target.subscription && it.device==target.device && it.revision==target.revision }==true
    private fun clearOutputVolume() {
        outputTimeout?.cancel();outputTimeout=null;outputPreview=null;retainedOutput=null;outputVolume=null
        if(pendingOutput) {
            val id=pending;active?.let { links[it]?.queue?.removeAll { work -> work.commandID==id } }
            pending=null;pendingVolume=false;pendingOutput=false;busy=false;submitted=false;timeout?.cancel();timeout=null
        }
    }
    private fun receiveOutputVolume(kind: String, token: String, message: PlayerVolumeMessage): Boolean {
        val link=links[kind] ?: return true;if(link.token!=token) return true
        if(message.kind==1L) {
            if(!link.outputCapable) { link.outputCapable=true;enqueue(kind,MediaSubmission.Volume(PlayerVolumeMessage(1,listOf(Cbor.Integer(1)),VolumeScope.OUTPUT))) }
            return true
        }
        if(kind!=active || message.string(0)!=subscription || !link.outputCapable || !acknowledged) return true
        when(message.kind) {
            2L -> {
                if(!(message.fields[3] as Cbor.Bool).value) { if(outputPreview!=null) feedback="Mac output volume became unavailable.";clearOutputVolume() }
                else {
                    val next=RemoteOutputVolume(message.string(0),message.string(1),message.string(2),message.number(4).toInt())
                    if(outputVolume?.let { !sameOutput(next) }==true) { if(outputPreview!=null) feedback="Mac audio output changed.";clearOutputVolume() }
                    outputVolume=next
                    if(next.level==outputPreview) { outputTimeout?.cancel();outputTimeout=null;outputPreview=null }
                }
                presentationChanged()
            }
            4L -> if(pendingOutput && pending==message.number(1)) {
                val result=message.number(2);trace("output volume result $result",clock())
                pending=null;pendingOutput=false;pendingVolume=false;busy=false;submitted=false;timeout?.cancel();timeout=null
                val intent=retainedOutput;retainedOutput=null
                if(result!=0L) { outputPreview=null;outputTimeout?.cancel();outputTimeout=null }
                feedback=when(result) { 0L->"";1L->"Mac audio output changed. Try again.";2L->"This Mac output has no volume control.";5L->"Mac output unavailable.";6L->"Mac is busy. Try again.";else->"Mac output volume action failed." }
                if(result==0L && intent!=null && sameOutput(intent.second)) commandOutputVolume(intent.first,intent.second)
                presentationChanged()
            }
        }
        return true
    }
    fun adjustOutputVolume(direction: Int, target: RemoteOutputVolume?=outputVolume) {
        if(direction !in listOf(-1,1)) return
        val level=displayedOutputVolume ?: return
        commandOutputVolume((level+direction*5).coerceIn(0,100),target)
    }
    fun commandOutputVolume(value: Int, target: RemoteOutputVolume?=outputVolume) {
        val selected=target ?: return;val kind=active ?: return
        if(!canControlOutputVolume || !sameOutput(selected) || value !in 0..100 || links[kind]?.outputCapable!=true) return
        if(busy) {
            if(pendingOutput) { retainedOutput=value to selected;outputPreview=value;presentationChanged() }
            else { feedback="Mac is busy. Try again.";presentationChanged() }
            return
        }
        if(counter==4294967295L) { retire();choose();return }
        outputPreview=value;outputTimeout?.cancel();val id=++counter
        pending=id;pendingOutput=true;pendingVolume=true;busy=true;submitted=false;feedback=""
        outputTimeout=scope.launch { wait(6000);if(outputPreview!=null && pending==null) feedback="Mac volume was not confirmed. Showing the latest value.";outputPreview=null;outputTimeout=null;presentationChanged() }
        timeout=scope.launch { wait(6000);if(pending==id) { pending=null;pendingOutput=false;pendingVolume=false;busy=false;submitted=false;retainedOutput=null;outputPreview=null;feedback="Mac volume outcome unknown. It will not be retried.";links[kind]?.queue?.removeAll { it.commandID==id };presentationChanged() } }
        enqueue(kind,MediaSubmission.Volume(PlayerVolumeMessage(3,listOf(Cbor.Text(selected.subscription),Cbor.Integer(id),Cbor.Text(selected.device),Cbor.Text(selected.revision),Cbor.Integer(value.toLong())),VolumeScope.OUTPUT)))
        presentationChanged()
    }
    fun commandVolume(value: Int, target: RemotePlayback?=playback) {
        val snapshot=target ?: return;val kind=active ?: return;val sub=subscription ?: return
        if(busy || !acknowledged || !sameTarget(snapshot) || playerVolume==null || links[kind]?.volumeCapable!=true || value !in 0..100) return
        if(counter==4294967295L) { retire();choose();return }
        clearSeek();volumeTimeout?.cancel();volumePreview=value
        val id=++counter;pending=id;pendingVolume=true;busy=true;submitted=false;feedback=""
        volumeTimeout=scope.launch { wait(6000);if(volumePreview!=null && pending==null) feedback="Volume was not confirmed. Showing the player’s latest value.";volumePreview=null;volumeTimeout=null;presentationChanged() }
        timeout=scope.launch { wait(6000);if(pending==id) { pending=null;pendingVolume=false;busy=false;submitted=false;clearSeek();volumePreview=null;feedback="Volume outcome unknown. It will not be retried.";links[kind]?.queue?.removeAll { it.commandID==id };presentationChanged() } }
        enqueue(kind,MediaSubmission.Volume(PlayerVolumeMessage(3,listOf(Cbor.Text(sub),Cbor.Integer(id),Cbor.Text(snapshot.source),Cbor.Text(snapshot.revision),Cbor.Integer(value.toLong())))))
        presentationChanged()
    }
    private fun acceptArtwork(message: MediaMessage) {
        val snapshot=playback ?: return
        val hash=(message.fields[3] as Cbor.Bytes).value
        if(message.string(1)!=snapshot.source || message.string(2)!=snapshot.revision || !hash.contentEquals(snapshot.hash)) return
        val buffer=assembly.accept(hash,message.number(4).toInt(),message.number(5).toInt(),(message.fields[6] as Cbor.Bytes).value,clock())
        if(message.number(5)==0L && artTimeout==null) artTimeout=scope.launch { wait(10000); assembly.expire(clock()); artTimeout=null }
        if(buffer==null) return
        artTimeout?.cancel();artTimeout=null
        val options=BitmapFactory.Options().apply { inJustDecodeBounds=true }
        BitmapFactory.decodeByteArray(buffer,0,buffer.size,options)
        if(options.outWidth !in 1..256 || options.outHeight !in 1..256 || options.outMimeType !in listOf("image/jpeg","image/png")) return
        artwork=BitmapFactory.decodeByteArray(buffer,0,buffer.size);presentationChanged()
    }
    fun command(action: Long, value: Long=0, target: RemotePlayback?=playback, selection: String="") {
        val snapshot=target ?: return
        if(!acknowledged || !sameTarget(snapshot)) { if(action==4L) clearSeek();return }
        if(action !in 1..6 || (action==4L && (!canSeek || value<0 || value>(playback?.duration ?: -1)))) {
            if(action==4L) { clearSeek();feedback="Playback changed. Try again.";presentationChanged() };return
        }
        if(action==4L) {
            trace("release",clock())
            val intent=SeekIntent(value,snapshot);previewSeek(intent)
            if(busy) {
                val link=links[active]
                if(!submitted && link?.sending==false && link.queue.any { it.commandID==pending && it.seek }) {
                    link.queue.removeAll { it.commandID==pending }
                    timeout?.cancel();timeout=null;pending=null;busy=false
                } else { retainedSeek=intent;return }
            }
        } else if(busy) return
        submitCommand(action,value,snapshot,selection)
    }
    private fun submitCommand(action: Long, value: Long, snapshot: RemotePlayback, selection: String) {
        val kind=active ?: return;val sub=subscription ?: return
        if(!sameTarget(snapshot) || !acknowledged || (action==4L && (!canSeek || value<0 || value>(playback?.duration ?: -1)))) { clearSeek();feedback="Playback changed. Try again.";presentationChanged();return }
        if(counter==4294967295L) { retire();choose();return }
        val id=++counter
        val source=if(action==5L) selection else if(action==6L) "" else snapshot.source
        val revision=if(action>=5) snapshot.catalogue else snapshot.revision
        if(action!=4L) clearSeek()
        busy=true;pending=id;submitted=false;pendingVolume=false;feedback=""
        // Install the deadline before sending: an immediate reply can finish this operation synchronously.
        timeout=scope.launch { wait(6000); if(pending==id) { pending=null;busy=false;submitted=false;clearSeek();feedback="Action outcome unknown. It will not be retried.";links[kind]?.queue?.removeAll { it.commandID==id };presentationChanged() } }
        queue(kind,MediaMessage(6,listOf(Cbor.Text(sub),Cbor.Integer(id),Cbor.Text(source),Cbor.Text(revision),Cbor.Integer(action),Cbor.Integer(value))))
    }
    private fun queue(kind: String, message: MediaMessage) { enqueue(kind,MediaSubmission.Playback(message)) }
    private fun enqueue(kind: String, message: MediaSubmission) { links[kind]?.let { if(it.queue.size<16) it.queue.addLast(message) };capacity(kind) }
    fun capacity(kind: String) {
        val link=links[kind] ?: return
        if(link.sending) { link.wake=true; return }
        link.sending=true
        scope.launch {
            try {
                while(links[kind]===link && link.queue.isNotEmpty()) {
                    val message=link.queue.first()
                    try { if(message.commandID != null && pending==message.commandID) { submitted=true;trace("submission",clock()) };link.send(message.encode()) } catch(_: SessionBackpressure) { if(message.commandID != null && pending==message.commandID) submitted=false;return@launch } catch(_: SessionException) { closed(kind); return@launch } catch(error: Exception) { if(error is CancellationException) throw error; closed(kind); return@launch }
                    if(link.queue.firstOrNull()===message) link.queue.removeFirst()
                }
            } finally { link.sending=false; if(link.wake) { link.wake=false; capacity(kind) } }
        }
    }
}
