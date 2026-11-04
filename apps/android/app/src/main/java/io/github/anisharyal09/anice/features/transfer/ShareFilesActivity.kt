// SPDX-License-Identifier: GPL-3.0-or-later
// Keeps launch-scoped file access alive while the existing sender owns the shared batch.
package io.github.anisharyal09.anice.features.transfer

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.text.format.Formatter
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextOverflow
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.R
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
    fun isActive(owner: TransferController): Boolean = owns(owner) && owner.isBusy
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
            override fun handleOnBackPressed() {
                if (share.isActive(app.transfer)) moveTaskToBack(true) else finish()
            }
        })
        setContent { AniCeTheme {
            val owner = app.transfer
            LaunchedEffect(Unit) { share.send(owner) }
            val active = share.isActive(owner)
            Surface(
                modifier = Modifier.fillMaxWidth(),
                shape = MaterialTheme.shapes.large,
                color = MaterialTheme.colorScheme.surface,
                tonalElevation = 1.dp,
            ) {
                Column(
                    Modifier.fillMaxWidth().navigationBarsPadding().verticalScroll(rememberScrollState()).padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                        Icon(painterResource(R.drawable.ic_file_send), contentDescription = null, modifier = Modifier.size(24.dp))
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text("Send files to Mac", style = MaterialTheme.typography.titleMedium)
                            if (share.peerName.isNotBlank()) {
                                Text("To ${share.peerName}", style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                    HorizontalDivider()
                    when {
                        active -> ShareTransferProgress(owner)
                        !share.started -> {
                            Text(share.message ?: "Preparing share…", style = MaterialTheme.typography.bodyMedium)
                            if (share.urls != null) {
                                Button(onClick = { share.send(owner) }, modifier = Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.small) {
                                    Text("Retry")
                                }
                            }
                            TextButton(
                                onClick = {
                                    startActivity(Intent(this@ShareFilesActivity, MainActivity::class.java))
                                    finish()
                                },
                                modifier = Modifier.fillMaxWidth(),
                            ) { Text("Open aniCe") }
                        }
                        else -> ShareTransferResult(share, owner)
                    }
                    if (active) {
                        HorizontalDivider()
                        Button(onClick = { moveTaskToBack(true) }, modifier = Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.small) {
                            Text("Continue in background")
                        }
                        TextButton(
                            onClick = { share.cancel(owner); finish() },
                            modifier = Modifier.fillMaxWidth(),
                        ) { Text("Cancel transfer") }
                    } else if (share.started) {
                        Button(onClick = { finish() }, modifier = Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.small) {
                            Text("Done")
                        }
                    }
                }
            }
        } }
    }
    override fun onStart() {
        super.onStart()
        app.sessionController.foreground(this); app.lanSessionController.foreground(this)
        app.transfer.applicationForegrounded()
    }
    override fun onStop() {
        super.onStop()
        app.sessionController.background(this, isChangingConfigurations)
        app.lanSessionController.background(this, isChangingConfigurations)
        if (!isChangingConfigurations) app.transfer.applicationBackgrounded()
    }
}

@Composable
private fun ShareTransferProgress(controller: TransferController) {
    val context = androidx.compose.ui.platform.LocalContext.current
    when (val state = controller.state) {
        is TransferState.Transferring -> {
            val total = state.batch.totalBytes
            val fraction = if (total > 0) (state.totalBytes.toFloat() / total).coerceIn(0f, 1f) else 0f
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    if (controller.receiving) "Receiving from ${state.batch.peerName}" else "Sending to ${state.batch.peerName}",
                    style = MaterialTheme.typography.titleSmall,
                )
                if (total > 0) LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth())
                else LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                Text(
                    "${Formatter.formatFileSize(context, state.totalBytes)} of ${Formatter.formatFileSize(context, total)} · File ${state.fileIndex} of ${state.batch.files.size}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(state.fileName, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        is TransferState.Paused -> {
            val total = state.batch.totalBytes
            val fraction = if (total > 0) (state.totalBytes.toFloat() / total).coerceIn(0f, 1f) else 0f
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Transfer paused", style = MaterialTheme.typography.titleSmall)
                if (total > 0) LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth())
                Text("${Formatter.formatFileSize(context, state.totalBytes)} of ${Formatter.formatFileSize(context, total)} · ${state.reason}",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        is TransferState.WaitingForPeerApproval -> {
            Text("Waiting for ${state.batch.peerName} to accept the files…", style = MaterialTheme.typography.bodyMedium)
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        }
        is TransferState.Connecting -> {
            Text("Connecting to ${state.peerName}…", style = MaterialTheme.typography.bodyMedium)
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        }
        else -> {
            Text(if (controller.preparing) "Preparing files…" else "Starting transfer…", style = MaterialTheme.typography.bodyMedium)
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun ShareTransferResult(share: FileShareState, controller: TransferController) {
    when (val state = controller.state) {
        is TransferState.Completed -> Text(
            if (share.matches(state.batchId)) "Files sent to ${share.peerName}." else "Transfer ended. Check aniCe for the result.",
            style = MaterialTheme.typography.bodyMedium,
        )
        is TransferState.Rejected -> Text(
            if (share.matches(state.batchId)) "The Mac declined the files." else "Transfer ended. Check aniCe for the result.",
            style = MaterialTheme.typography.bodyMedium,
        )
        is TransferState.Failed -> Text(state.reason, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error)
        TransferState.Cancelled -> Text("Transfer cancelled.", style = MaterialTheme.typography.bodyMedium)
        else -> Text("Transfer ended. Check aniCe for the result.", style = MaterialTheme.typography.bodyMedium)
    }
}
