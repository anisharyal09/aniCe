// SPDX-License-Identifier: GPL-3.0-or-later
// Keeps launch-scoped file access alive while the existing sender owns the shared batch.
package io.github.anisharyal09.anice.features.transfer

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.ui.theme.AniCeTheme

internal fun sharedFileUris(intent: Intent): List<Uri>? {
    return try {
    if (intent.action !in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) null
    else {
        @Suppress("DEPRECATION")
        val streams = if (intent.action == Intent.ACTION_SEND_MULTIPLE)
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
        else intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let(::listOf)
        val uris = streams ?: intent.clipData?.let { clip ->
            if (clip.itemCount !in 1..128) return null
            (0 until clip.itemCount).map { clip.getItemAt(it).uri ?: return null }
        }
        uris?.takeIf { it.size in 1..128 && it.all { uri -> uri.scheme == "content" && !uri.authority.isNullOrBlank() } }
    }
} catch (_: RuntimeException) { null }
}

private class FileShareState : ViewModel() {
    var initialized = false
    var urls: List<Uri>? = null
    var started by mutableStateOf(false)
    var message by mutableStateOf<String?>(null)
    var peerName by mutableStateOf("")
    private var epoch: java.util.UUID? = null
    private var batch: String? = null

    fun owns(owner: TransferController): Boolean {
        if (!started) return false
        if (batch == null && owner.epoch == epoch) batch = owner.currentBatch?.id
        return batch?.let { owner.currentBatch?.id == it } ?: (owner.epoch == epoch)
    }
    fun send(owner: TransferController) {
        if (started) return
        val files = urls ?: return
        if (owner.isBusy) { message = "A transfer is already in progress. Try again when it finishes."; return }
        val peer = owner.activeChannel?.descriptor?.peer
        if (!owner.peerConnected || !owner.peerCompatible || peer?.platform != "macos") {
            message = "Connect your Mac in aniCe, then tap Retry."; return
        }
        peerName = peer.deviceName
        epoch = owner.epoch
        started = true
        message = null
        owner.sendUris(files, peer.deviceId, peer.fingerprint)
    }
    fun matches(batchId: String): Boolean = batch == batchId
    fun cancel(owner: TransferController) { if (owns(owner) && owner.isBusy) owner.cancelTransfer() }
}

class ShareFilesActivity : ComponentActivity() {
    private val app get() = application as AniCeApplication
    private lateinit var share: FileShareState
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        share = ViewModelProvider(this, viewModelFactory { initializer { FileShareState() } })[FileShareState::class.java]
        if (!share.initialized) {
            share.initialized = true
            // Process recreation must not replay a send whose receiver outcome is unknown.
            share.urls = if (savedInstanceState == null) sharedFileUris(intent) else null
            if (share.urls == null) share.message = if (savedInstanceState == null)
                "Share 1–128 readable files. No files were sent." else "Share interrupted. Check aniCe before sharing these files again."
        }
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { share.cancel(app.transfer); finish() }
        })
        setContent { AniCeTheme {
            val owner = app.transfer
            LaunchedEffect(Unit) { share.send(owner) }
            Surface { Column(Modifier.padding(24.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Send files to Mac", style = MaterialTheme.typography.titleLarge)
                if (!share.started) {
                    Text(share.message ?: "Preparing share…")
                    if (share.urls != null) Button(onClick = { share.send(owner) }) { Text("Retry") }
                    TextButton(onClick = { startActivity(Intent(this@ShareFilesActivity, MainActivity::class.java)) }) { Text("Open aniCe") }
                } else {
                    Text("To ${share.peerName}")
                    val owns = share.owns(owner)
                    if (owns && owner.isBusy) TransferView(owner, overview = true)
                    else Text(when (val state = owner.state) {
                        is TransferState.Completed -> if (share.matches(state.batchId)) "Files received by your Mac." else "Transfer ended. Check aniCe for the result."
                        is TransferState.Rejected -> if (share.matches(state.batchId)) "The Mac declined the files." else "Transfer ended. Check aniCe for the result."
                        else -> "Transfer ended. Check aniCe for the result."
                    })
                }
                TextButton(onClick = { share.cancel(owner); finish() }) {
                    Text(if (share.owns(owner) && owner.isBusy) "Cancel transfer" else "Close")
                }
            } }
        } }
    }
    override fun onStart() {
        super.onStart()
        app.sessionController.foreground(this); app.lanSessionController.foreground(this)
        app.transfer.applicationForegrounded()
    }
    override fun onDestroy() {
        if (isFinishing && ::share.isInitialized) share.cancel(app.transfer)
        super.onDestroy()
    }
    override fun onStop() {
        super.onStop()
        app.sessionController.background(this, isChangingConfigurations)
        app.lanSessionController.background(this, isChangingConfigurations)
        if (!isChangingConfigurations) app.transfer.applicationBackgrounded()
    }
}
