// SPDX-License-Identifier: GPL-3.0-or-later
// Presents remote playback through native system media UI without audio playback or a service.
package io.github.anisharyal09.anice.features.nowplaying

import io.github.anisharyal09.anice.features.media.MediaActionReceiver
import android.app.*
import android.content.*
import android.media.MediaMetadata
import android.media.VolumeProvider
import android.media.AudioAttributes
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.R

class MediaNotification(private val app: AniCeApplication, private val owner: MediaController) {
    private val manager=app.getSystemService(NotificationManager::class.java)
    private var session: MediaSession?=null
    internal val token get()=session?.sessionToken
    private var notificationKey: List<Any?>?=null
    private var providerKey: List<Any?>?=null
    private var provider: VolumeProvider?=null
    private var lastPlaybackState: List<Any?>?=null
    private val actions=mutableListOf<PendingIntent>()
    private val mainHandler=Handler(Looper.getMainLooper())
    private var retirementScheduled=false
    private val retireRunnable=Runnable { retirementScheduled=false;clear() }
    private var updateScheduled=false
    private val updateRunnable=Runnable {
        updateScheduled=false
        performUpdate()
    }
    init {
        manager.cancel(ID)
        manager.createNotificationChannel(NotificationChannel(CHANNEL,"Mac playback",NotificationManager.IMPORTANCE_LOW).apply {
            setSound(null,null);enableVibration(false);setShowBadge(false)
        })
    }
    private fun clear() {
        mainHandler.removeCallbacks(retireRunnable)
        retirementScheduled=false
        mainHandler.removeCallbacks(updateRunnable)
        updateScheduled=false
        actions.forEach { it.cancel() };actions.clear()
        session?.isActive=false;session?.release();session=null;provider=null;providerKey=null;notificationKey=null
        lastPlaybackState=null
        manager.cancel(ID)
    }
    fun update() {
        if(updateScheduled) return
        updateScheduled=true
        mainHandler.post(updateRunnable)
    }
    // MediaStyle notifications attached to a MediaSession are exempt from POST_NOTIFICATIONS.
    @android.annotation.SuppressLint("NotificationPermission")
    private fun performUpdate() {
        val target=owner.playback
        if(!owner.compactVisible || target==null || target.source.isEmpty() || target.state !in 1L..2L) {
            if(owner.connected && owner.awaitingSnapshot && session!=null) {
                if(!retirementScheduled) { retirementScheduled=true;mainHandler.postDelayed(retireRunnable,6000) }
            } else clear()
            return
        }
        mainHandler.removeCallbacks(retireRunnable);retirementScheduled=false
        val current=session ?: MediaSession(app,"aniCe Mac playback").also { newSession ->
            session=newSession
            newSession.setCallback(object : MediaSession.Callback() {
                override fun onPlay() { if(owner.playback?.state!=1L) owner.command(1) }
                override fun onPause() { if(owner.playback?.state==1L) owner.command(1) }
                override fun onSkipToPrevious() { owner.command(2) }
                override fun onSkipToNext() { owner.command(3) }
                override fun onSeekTo(pos: Long) { owner.command(4,pos) }
            },mainHandler)
        }
        val output=owner.outputVolume
        // Mac changes device and revision together (MacOutputVolume.swift:100); keyed on subscription/device/capability only.
        val nextProviderKey=listOf(target.message.string(0),output?.device,owner.canControlOutputVolume)
        if(providerKey!=nextProviderKey) {
            provider=if(owner.canControlOutputVolume) object : VolumeProvider(VOLUME_CONTROL_ABSOLUTE,20,((owner.displayedOutputVolume ?: 0)+2)/5) {
                override fun onSetVolumeTo(volume: Int) { mainHandler.post { owner.commandOutputVolume(volume*5,owner.outputVolume) } }
                override fun onAdjustVolume(direction: Int) { mainHandler.post { owner.adjustOutputVolume(direction,owner.outputVolume) } }
            }
            else null
            provider?.let { current.setPlaybackToRemote(it) } ?: current.setPlaybackToLocal(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            providerKey=nextProviderKey
        }
        provider?.setCurrentVolume(((owner.displayedOutputVolume ?: 0)+2)/5)
        var supported=0L
        if(target.actions and 1L!=0L) supported=supported or PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE
        if(target.actions and 2L!=0L) supported=supported or PlaybackState.ACTION_SKIP_TO_PREVIOUS
        if(target.actions and 4L!=0L) supported=supported or PlaybackState.ACTION_SKIP_TO_NEXT
        if(target.actions and 8L!=0L && target.duration>0) supported=supported or PlaybackState.ACTION_SEEK_TO
        val presentation=owner.displayedPlayback ?: target
        val nextPlaybackState=listOf(supported,if(target.state==1L) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
            presentation.message.number(7),if(presentation.state==1L && !presentation.frozen) presentation.message.number(9)/1000f else 0f,presentation.sampledAt)
        if(lastPlaybackState!=nextPlaybackState) {
            lastPlaybackState=nextPlaybackState
            current.setPlaybackState(PlaybackState.Builder().setActions(supported)
                .setState(if(target.state==1L) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    presentation.message.number(7),if(presentation.state==1L && !presentation.frozen) presentation.message.number(9)/1000f else 0f,presentation.sampledAt).build())
        }
        val isNotificationActive=manager.activeNotifications.any { it.id==ID }
        val nextKey=listOf(target.message.string(0),target.source,target.revision,target.title,target.artist,target.player,target.state,target.actions,target.duration,owner.origin,owner.artwork)
        if(notificationKey==nextKey && isNotificationActive) return
        notificationKey=nextKey
        val metadata=MediaMetadata.Builder().putString(MediaMetadata.METADATA_KEY_TITLE,target.title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST,target.artist)
            .putString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE,"${target.player} · ${owner.origin}")
        if(target.duration>0) metadata.putLong(MediaMetadata.METADATA_KEY_DURATION,target.duration)
        owner.artwork?.let { metadata.putBitmap(MediaMetadata.METADATA_KEY_ART,it) }
        current.setMetadata(metadata.build())
        val open=PendingIntent.getActivity(app,0,Intent(app,MainActivity::class.java).putExtra(OPEN,true)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        current.setSessionActivity(open);current.isActive=true
        actions.forEach { it.cancel() };actions.clear()
        val builder=Notification.Builder(app,CHANNEL).setSmallIcon(R.drawable.ic_media_play)
            .setContentTitle(target.title.ifEmpty { target.player }).setContentText("${target.player} · ${owner.origin}")
            .setContentIntent(open).setOnlyAlertOnce(true).setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC).setOngoing(target.state==1L)
        owner.artwork?.let { builder.setLargeIcon(it) }
        fun action(mask: Long, number: Long, icon: Int, label: String) {
            if(target.actions and mask==0L) return
            val intent=Intent(app,MediaActionReceiver::class.java).setAction(ACTION)
                .setData(Uri.Builder().scheme("anice").authority("media").appendPath(target.message.string(0)).appendPath(target.source).appendPath(target.revision).appendPath(number.toString()).build())
                .putExtra("subscription",target.message.string(0)).putExtra("source",target.source).putExtra("revision",target.revision).putExtra("action",number)
            val pending=PendingIntent.getBroadcast(app,number.toInt(),intent,PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            actions.add(pending);builder.addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(app,icon),label,pending).build())
        }
        action(2,2,R.drawable.ic_media_previous,"Previous")
        action(1,1,if(target.state==1L) R.drawable.ic_media_pause else R.drawable.ic_media_play,if(target.state==1L) "Pause" else "Play")
        action(4,3,R.drawable.ic_media_next,"Next")
        builder.setStyle(Notification.MediaStyle().setMediaSession(current.sessionToken).setShowActionsInCompactView(*actions.indices.toList().take(3).toIntArray()))
        manager.notify(ID,builder.build())
    }
    companion object {
        const val OPEN="io.github.anisharyal09.anice.OPEN_NOW_PLAYING"
        const val ACTION="io.github.anisharyal09.anice.MEDIA_ACTION"
        private const val CHANNEL="mac_playback_v1"
        private const val ID=4101
    }
}
