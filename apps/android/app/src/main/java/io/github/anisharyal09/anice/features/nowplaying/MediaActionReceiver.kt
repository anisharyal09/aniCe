// SPDX-License-Identifier: GPL-3.0-or-later
// Preserves the installed receiver component identity while handling source-bound Now Playing actions.
package io.github.anisharyal09.anice.features.media

import android.content.*
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.features.nowplaying.MediaNotification

class MediaActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if(intent.action!=MediaNotification.ACTION) return
        val owner=(context.applicationContext as AniCeApplication).nowPlaying
        val target=owner.playback ?: return
        if(!owner.compactVisible || intent.getStringExtra("subscription")!=target.message.string(0) ||
            intent.getStringExtra("source")!=target.source || intent.getStringExtra("revision")!=target.revision) return
        val action=intent.getLongExtra("action",0)
        if(action in 1..3) owner.command(action,target=target)
    }
}
