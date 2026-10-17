// SPDX-License-Identifier: GPL-3.0-or-later
// Restricts Android clipboard reads to actual window focus and marks remote writes for echo suppression.
package io.github.anisharyal09.anice.features.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.PersistableBundle

data class ClipboardSample(val text: String, val sensitive: Boolean = false, val excluded: Boolean = false, val token: String = "")
interface NativeClipboard {
    fun read(): ClipboardSample?
    fun token(): String?
    fun write(text: String, sensitive: Boolean): Boolean
    fun observe(enabled: Boolean, changed: () -> Unit)
}
class AndroidClipboard(context: Context) : NativeClipboard {
    private val manager = context.getSystemService(ClipboardManager::class.java)
    var focused = false
    private var change = 0L
    private var listener: ClipboardManager.OnPrimaryClipChangedListener? = null
    override fun read(): ClipboardSample? {
        if (!focused) return null
        return try {
            val clip = manager.primaryClip ?: return null
            if (clip.itemCount != 1) return null
            val text = clip.getItemAt(0).text?.toString() ?: return null
            if (text.length > 65536) return null
            val extras = clip.description.extras
            ClipboardSample(text, extras?.getBoolean(SENSITIVE) == true, extras?.getBoolean(REMOTE) == true,
                clip.description.timestamp.toString() + ":" + change)
        } catch (_: SecurityException) { null }
    }
    override fun token(): String? = if (!focused) null else try {
        read()?.let { it.token + ":" + it.text } ?: manager.primaryClipDescription?.timestamp?.toString() ?: "empty"
    } catch (_: SecurityException) { null }
    override fun write(text: String, sensitive: Boolean): Boolean = try {
        val clip = ClipData.newPlainText("aniCe", text)
        clip.description.extras = PersistableBundle().apply { putBoolean(REMOTE, true); putBoolean(SENSITIVE, sensitive) }
        manager.setPrimaryClip(clip)
        true
    } catch (_: SecurityException) { false }
      catch (_: IllegalArgumentException) { false }
    override fun observe(enabled: Boolean, changed: () -> Unit) {
        listener?.let(manager::removePrimaryClipChangedListener); listener = null
        if (enabled && focused) {
            listener = ClipboardManager.OnPrimaryClipChangedListener { change++; changed() }
            manager.addPrimaryClipChangedListener(listener!!)
        }
    }
    companion object {
        const val SENSITIVE = "android.content.extra.IS_SENSITIVE"
        const val REMOTE = "android.content.extra.IS_REMOTE_DEVICE"
    }
}
