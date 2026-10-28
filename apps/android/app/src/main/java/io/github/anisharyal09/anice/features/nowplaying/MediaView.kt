// SPDX-License-Identifier: GPL-3.0-or-later
// Renders subscribed Mac playback and captures immutable scrub targets until release.
package io.github.anisharyal09.anice.features.nowplaying

import io.github.anisharyal09.anice.ui.theme.selectionAccent
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
@Composable fun MediaView(owner: MediaController, compact: Boolean=false, showPlayerSelector: Boolean=true, compactVolume: Boolean=false, overview: Boolean = false, open: (() -> Unit)? = null) {
    val media=owner.displayedPlayback
    var now by remember { mutableLongStateOf(SystemClock.elapsedRealtime()) }
    var volumeDrag by remember { mutableStateOf<Float?>(null) }
    var volumeTarget by remember { mutableStateOf<RemotePlayback?>(null) }
    var volumeCancelled by remember { mutableStateOf(false) }
    LaunchedEffect(media?.message?.string(0),media?.source,media?.revision) {
        if(volumeTarget!=null) { volumeCancelled=true;volumeDrag=null }
    }
    val interactions=remember { MutableInteractionSource() }
    var options by remember { mutableStateOf(false) }
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
    Surface(shape=if (overview) androidx.compose.ui.graphics.RectangleShape else MaterialTheme.shapes.medium,
        color=if (overview) androidx.compose.ui.graphics.Color.Transparent else MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.fillMaxWidth().padding(if (overview) 0.dp else if(compact) 12.dp else 16.dp),
            verticalArrangement=Arrangement.spacedBy(if(compact || overview) 6.dp else 8.dp)) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement=Arrangement.SpaceBetween,
                verticalAlignment=Alignment.CenterVertically
            ) {
                Row(Modifier.weight(1f).then(if (open != null) Modifier.clickable(onClickLabel = "Open Now Playing", onClick = open).heightIn(min = 48.dp) else Modifier),
                    verticalAlignment=Alignment.CenterVertically, horizontalArrangement=Arrangement.spacedBy(4.dp)) {
                    Text(if (overview) "Now Playing" else "Now playing",style=MaterialTheme.typography.titleSmall, modifier=Modifier.weight(1f, fill=false))
                    if (open != null) Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription=null, modifier=Modifier.size(16.dp))
                }
                Text(if (overview) owner.origin.ifBlank { "Your Mac" } else "On ${owner.origin.ifBlank { "your Mac" }}",
                    style=MaterialTheme.typography.bodySmall, modifier=Modifier.weight(1f),textAlign=androidx.compose.ui.text.style.TextAlign.End)
                if (!showPlayerSelector && !overview) IconButton(onClick={ options = !options }, modifier=Modifier.semantics { contentDescription="More playback controls" }) { Text("⋯",style=MaterialTheme.typography.titleLarge) }
            }
            if(media!=null && (showPlayerSelector || options)) Box {
                TextButton(onClick={picker=true},enabled=!owner.busy) { Text(if(media.selection.isEmpty()) "Player: Auto" else "Player: ${media.sources.firstOrNull { it.first==media.selection }?.second ?: media.player}") }
                DropdownMenu(expanded=picker,onDismissRequest={picker=false}) {
                    DropdownMenuItem(text={Text("Auto")},onClick={picker=false;owner.command(6)})
                    media.sources.forEach { (id,name)-> DropdownMenuItem(text={Text(name)},onClick={picker=false;owner.command(5,selection=id)}) }
                }
            }
            if(media!=null && media.source.isNotEmpty()) {
                Row(horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                    Box(Modifier.size(if (overview) 74.dp else if(compact) 50.dp else 72.dp)
                        .background(MaterialTheme.colorScheme.surfaceVariant, MaterialTheme.shapes.small), contentAlignment=Alignment.Center) {
                        val artwork = owner.artwork
                        if (artwork != null) Image(artwork.asImageBitmap(), contentDescription=null, modifier=Modifier.fillMaxSize())
                        else Icon(painterResource(R.drawable.ic_media_note), contentDescription=null, modifier=Modifier.size(24.dp))
                    }
                    Column(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(2.dp)) {
                        if(media.title.isNotEmpty()) Text(media.title,style=MaterialTheme.typography.bodyMedium)
                        if(media.artist.isNotEmpty()) Text(media.artist,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                        if (!overview) Text(media.player,style=MaterialTheme.typography.bodySmall)
                    }
                }
                if(showPlayerSelector || options) Text(owner.displayedOutputVolume?.let { "Phone volume buttons · Mac output $it%" } ?: "Mac output volume unavailable for this audio output.",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                if (overview && media.actions and 8L!=0L && media.duration>0) Row(
                    Modifier.fillMaxWidth(), verticalAlignment=Alignment.CenterVertically,
                    horizontalArrangement=Arrangement.spacedBy(6.dp)) {
                    Text(mediaTime(media.elapsed(now)),style=MaterialTheme.typography.bodySmall,fontFamily=FontFamily.Monospace)
                    Slider(
                        value=media.elapsed(now).coerceIn(0f,media.duration/1000f),
                        onValueChange={ owner.dragSeek((it*1000).toLong()) },
                        onValueChangeFinished=owner::releaseSeek,
                        valueRange=0f..(media.duration/1000f),enabled=owner.canSeek,interactionSource=interactions,
                        thumb={ Box(Modifier.size(12.dp).background(MaterialTheme.colorScheme.onSurface, androidx.compose.foundation.shape.CircleShape)) },
                        track={ slider -> SliderDefaults.Track(slider,modifier=Modifier.height(3.dp),thumbTrackGapSize=2.dp) },
                        modifier=Modifier.weight(1f).heightIn(min = 48.dp).semantics { contentDescription="Playback position" })
                    Text(mediaTime(media.duration/1000f),style=MaterialTheme.typography.bodySmall,fontFamily=FontFamily.Monospace)
                }
                if(!overview && media.actions and 8L!=0L && media.duration>0) Slider(
                    value=media.elapsed(now).coerceIn(0f,media.duration/1000f),
                    onValueChange={ owner.dragSeek((it*1000).toLong()) },
                    onValueChangeFinished=owner::releaseSeek,
                    valueRange=0f..(media.duration/1000f),enabled=owner.canSeek,interactionSource=interactions,
                    thumb={ Box(Modifier.size(12.dp).background(MaterialTheme.colorScheme.onSurface, androidx.compose.foundation.shape.CircleShape)) },
                    track={ slider -> SliderDefaults.Track(slider,modifier=Modifier.height(3.dp),thumbTrackGapSize=2.dp) },
                    modifier=Modifier.heightIn(min=48.dp).semantics { contentDescription="Playback position" })
                if(!overview && media.message.number(7)>=0) Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween) {
                    Text(mediaTime(media.elapsed(now)),style=MaterialTheme.typography.bodySmall,fontFamily=FontFamily.Monospace)
                    if(media.duration>0) Text(mediaTime(media.duration/1000f),style=MaterialTheme.typography.bodySmall,fontFamily=FontFamily.Monospace)
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement=Arrangement.Center) {
                    IconButton(onClick={owner.command(2)},enabled=owner.canAcceptPlayback && media.actions and 2L!=0L) { Icon(painterResource(R.drawable.ic_media_previous),contentDescription="Previous") }
                    if (overview) IconButton(onClick={owner.command(1)},enabled=owner.canAcceptPlayback && media.actions and 1L!=0L,
                        modifier = Modifier.size(48.dp)) {
                        Box(Modifier.size(40.dp).background(MaterialTheme.colorScheme.selectionAccent, MaterialTheme.shapes.small), contentAlignment = Alignment.Center) {
                            Icon(painterResource(if(media.state==1L) R.drawable.ic_media_pause else R.drawable.ic_media_play),contentDescription=if(media.state==1L) "Pause" else "Play", tint=MaterialTheme.colorScheme.onPrimary)
                        }
                    } else FilledIconButton(onClick={owner.command(1)},shape=MaterialTheme.shapes.small,modifier=Modifier.size(36.dp),enabled=owner.canAcceptPlayback && media.actions and 1L!=0L,
                        colors=IconButtonDefaults.filledIconButtonColors(containerColor=MaterialTheme.colorScheme.selectionAccent,contentColor=MaterialTheme.colorScheme.onPrimary)) { Icon(painterResource(if(media.state==1L) R.drawable.ic_media_pause else R.drawable.ic_media_play),contentDescription=if(media.state==1L) "Pause" else "Play") }
                    IconButton(onClick={owner.command(3)},enabled=owner.canAcceptPlayback && media.actions and 4L!=0L) { Icon(painterResource(R.drawable.ic_media_next),contentDescription="Next") }
                }
                if(!compact) owner.displayedVolume?.let { level ->
                    if (!compactVolume) Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween) {
                        Text("Player volume",style=MaterialTheme.typography.bodySmall)
                        Text("${(volumeDrag ?: level.toFloat()).toInt()}%",style=MaterialTheme.typography.bodySmall,fontFamily=FontFamily.Monospace)
                    }
                    Row(Modifier.fillMaxWidth(), verticalAlignment=Alignment.CenterVertically, horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                    if (compactVolume) Text("Volume", style=MaterialTheme.typography.bodySmall)
                    Slider(value=volumeDrag ?: level.toFloat(),valueRange=0f..100f,enabled=owner.playerVolume!=null,
                        onValueChange={ if(!volumeCancelled) { if(volumeTarget==null) volumeTarget=owner.playback;volumeDrag=it } },
                        onValueChangeFinished={ val value=volumeDrag;val captured=volumeTarget;if(!volumeCancelled && value!=null && captured!=null) owner.commandVolume(value.toInt(),captured);volumeDrag=null;volumeTarget=null;volumeCancelled=false },
                        thumb={ Box(Modifier.size(12.dp).background(MaterialTheme.colorScheme.onSurface, androidx.compose.foundation.shape.CircleShape)) },
                        track={ slider -> SliderDefaults.Track(slider,modifier=Modifier.height(3.dp),thumbTrackGapSize=2.dp) },
                        modifier=Modifier.weight(1f).heightIn(min=48.dp).semantics { contentDescription="Player volume" })
                    if (compactVolume) Text("${(volumeDrag ?: level.toFloat()).toInt()}%", style=MaterialTheme.typography.bodySmall)
                    }
                }
                if((showPlayerSelector || options) && owner.playerVolume==null) Text("Player volume is unavailable. Check support and permissions in aniCe on your Mac.",style=MaterialTheme.typography.bodySmall)
                if(media.actions and 16L!=0L) Text("Allow playback control on your Mac.",style=MaterialTheme.typography.bodySmall)
            } else if(!compact) Text(if(!owner.connected) "Connect to your trusted Mac to use Now Playing." else if(!owner.supported) "Update aniCe on your Mac to use Now Playing." else if(owner.awaitingSnapshot) "Waiting for playback information from ${owner.origin}." else "Play media on ${owner.origin} to see it here.",color=MaterialTheme.colorScheme.onSurfaceVariant)
            if(owner.feedback.isNotEmpty()) Text(owner.feedback,style=MaterialTheme.typography.bodySmall)
            if (overview) {
                Spacer(Modifier.height(16.dp))
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            }
        }
    }
}
private fun mediaTime(seconds: Float): String { val value=maxOf(0,seconds.toInt()); return "%d:%02d".format(value/60,value%60) }
