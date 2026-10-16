// SPDX-License-Identifier: GPL-3.0-or-later
// Renders subscribed Mac playback and captures immutable scrub targets until release.
package io.github.anisharyal09.anice.features.nowplaying

import android.os.SystemClock
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.ui.Alignment
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.res.painterResource
import io.github.anisharyal09.anice.R
import kotlinx.coroutines.delay

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun MediaView(owner: MediaController, compact: Boolean=false, open: ()->Unit={}) {
    val media=owner.displayedPlayback
    var now by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    var volumeDrag by remember { mutableStateOf<Float?>(null) }
    var volumeTarget by remember { mutableStateOf<RemotePlayback?>(null) }
    var volumeCancelled by remember { mutableStateOf(false) }
    LaunchedEffect(media?.message?.string(0),media?.source,media?.revision) {
        if(volumeTarget!=null) { volumeCancelled=true;volumeDrag=null }
    }
    val interactions=remember { MutableInteractionSource() }
    var picker by remember { mutableStateOf(false) }
    DisposableEffect(owner) { onDispose { owner.cancelSeekDrag() } }
    LaunchedEffect(interactions) {
        interactions.interactions.collect { event ->
            if(event is DragInteraction.Start) owner.beginSeek()
            else if(event is DragInteraction.Cancel) owner.cancelSeekDrag()
        }
    }
    LaunchedEffect(owner.foregroundVisible,media?.state,media?.sampledAt) {
        now=SystemClock.elapsedRealtime();owner.trace("render",now)
        while(owner.foregroundVisible && media?.state==1L) { delay(250); now=SystemClock.elapsedRealtime() }
    }
    Surface(shape=MaterialTheme.shapes.medium,color=MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.fillMaxWidth().padding(if(compact) 12.dp else 16.dp),verticalArrangement=Arrangement.spacedBy(if(compact) 6.dp else 8.dp)) {
            Row(
                Modifier.fillMaxWidth().then(if(compact) Modifier.clickable(onClick=open) else Modifier),
                horizontalArrangement=Arrangement.SpaceBetween,
                verticalAlignment=Alignment.CenterVertically
            ) {
                Text("Now Playing",style=MaterialTheme.typography.titleMedium)
                if(compact) IconButton(onClick=open) { Icon(painterResource(R.drawable.ic_media_open),contentDescription="Open Now Playing") }
            }
            if(media!=null && (!compact || media.sources.size > 1)) Box {
                TextButton(onClick={picker=true},enabled=!owner.busy) { Text(if(media.selection.isEmpty()) "Player: Auto" else "Player: ${media.sources.firstOrNull { it.first==media.selection }?.second ?: media.player}") }
                DropdownMenu(expanded=picker,onDismissRequest={picker=false}) {
                    DropdownMenuItem(text={Text("Auto")},onClick={picker=false;owner.command(6)})
                    media.sources.forEach { (id,name)-> DropdownMenuItem(text={Text(name)},onClick={picker=false;owner.command(5,selection=id)}) }
                }
            }
            if(media!=null && media.source.isNotEmpty()) {
                Row(horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                    owner.artwork?.let { Image(it.asImageBitmap(),contentDescription=null,modifier=Modifier.size(if(compact) 44.dp else 96.dp)) }
                    Column(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(2.dp)) {
                        if(media.title.isNotEmpty()) Text(media.title,style=MaterialTheme.typography.bodyLarge)
                        if(media.artist.isNotEmpty()) Text(media.artist,color=MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(media.player,style=MaterialTheme.typography.bodySmall)
                    }
                }
                if(!compact) Text(owner.displayedOutputVolume?.let { "Phone volume buttons · Mac output $it%" } ?: "Mac output volume unavailable for this audio output.",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                if(media.actions and 8L!=0L && media.duration>0) Slider(
                    value=media.elapsed(now).coerceIn(0f,media.duration/1000f),
                    onValueChange={ owner.dragSeek((it*1000).toLong()) },
                    onValueChangeFinished=owner::releaseSeek,
                    valueRange=0f..(media.duration/1000f),enabled=owner.canSeek,interactionSource=interactions,
                    thumb={ Box(Modifier.size(12.dp).background(MaterialTheme.colorScheme.onSurface, androidx.compose.foundation.shape.CircleShape)) },
                    track={ slider -> SliderDefaults.Track(slider,modifier=Modifier.height(3.dp),thumbTrackGapSize=2.dp) },
                    modifier=Modifier.heightIn(min=48.dp).semantics { contentDescription="Playback position" })
                if(media.message.number(7)>=0) Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween) {
                    Text(mediaTime(media.elapsed(now)),style=MaterialTheme.typography.bodySmall,fontFamily=FontFamily.Monospace)
                    if(media.duration>0) Text(mediaTime(media.duration/1000f),style=MaterialTheme.typography.bodySmall,fontFamily=FontFamily.Monospace)
                }
                Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                    IconButton(onClick={owner.command(2)},enabled=!owner.busy && media.actions and 2L!=0L) { Icon(painterResource(R.drawable.ic_media_previous),contentDescription="Previous") }
                    IconButton(onClick={owner.command(1)},enabled=!owner.busy && media.actions and 1L!=0L) { Icon(painterResource(if(media.state==1L) R.drawable.ic_media_pause else R.drawable.ic_media_play),contentDescription=if(media.state==1L) "Pause" else "Play") }
                    IconButton(onClick={owner.command(3)},enabled=!owner.busy && media.actions and 4L!=0L) { Icon(painterResource(R.drawable.ic_media_next),contentDescription="Next") }
                }
                if(!compact) owner.displayedVolume?.let { level ->
                    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween) {
                        Text("Player volume",style=MaterialTheme.typography.bodySmall)
                        Text("${(volumeDrag ?: level.toFloat()).toInt()}%",style=MaterialTheme.typography.bodySmall,fontFamily=FontFamily.Monospace)
                    }
                    Slider(value=volumeDrag ?: level.toFloat(),valueRange=0f..100f,enabled=!owner.busy,
                        onValueChange={ if(!volumeCancelled) { if(volumeTarget==null) volumeTarget=owner.playback;volumeDrag=it } },
                        onValueChangeFinished={ val value=volumeDrag;val captured=volumeTarget;if(!volumeCancelled && value!=null && captured!=null) owner.commandVolume(value.toInt(),captured);volumeDrag=null;volumeTarget=null;volumeCancelled=false },
                        modifier=Modifier.heightIn(min=48.dp).semantics { contentDescription="Player volume" })
                }
                if(!compact && owner.playerVolume==null) Text("Player volume is unavailable. Check support and permissions in aniCe on your Mac.",style=MaterialTheme.typography.bodySmall)
                if(media.actions and 16L!=0L) Text("Allow playback control on your Mac.",style=MaterialTheme.typography.bodySmall)
            } else if(!compact) Text(if(!owner.connected) "Connect to your trusted Mac to use Now Playing." else if(!owner.supported) "Update aniCe on your Mac to use Now Playing." else if(owner.awaitingSnapshot) "Waiting for playback information from ${owner.origin}." else "Play media on ${owner.origin} to see it here.",color=MaterialTheme.colorScheme.onSurfaceVariant)
            if(owner.feedback.isNotEmpty()) Text(owner.feedback,style=MaterialTheme.typography.bodySmall)
        }
    }
}
private fun mediaTime(seconds: Float): String { val value=maxOf(0,seconds.toInt()); return "%d:%02d".format(value/60,value%60) }
