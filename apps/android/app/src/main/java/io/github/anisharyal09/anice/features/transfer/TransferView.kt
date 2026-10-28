// SPDX-License-Identifier: GPL-3.0-or-later
// Presents local file transfer controls, incoming batch approval and progress in the Android feature workspace.
package io.github.anisharyal09.anice.features.transfer

import android.text.format.Formatter
import android.content.ContentResolver
import android.provider.OpenableColumns
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.res.painterResource
import io.github.anisharyal09.anice.R
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal data class TransferReviewFile(val uri: Uri, val name: String, val size: Long?)
private data class TransferReviewPeer(val deviceId: String, val fingerprint: String, val name: String)

@Stable
class TransferSendReview internal constructor(private val controller: TransferController) {
    private var files by mutableStateOf<List<TransferReviewFile>>(emptyList())
        private set
    private var resolving by mutableStateOf(false)
        private set
    private var visible by mutableStateOf(false)
        private set
    private var reviewedPeer by mutableStateOf<TransferReviewPeer?>(null)
        private set
    private var launchPicker: () -> Unit = {}

    private fun currentPeer(): TransferReviewPeer? = controller.activeChannel?.descriptor?.peer?.let {
        TransferReviewPeer(it.deviceId, it.fingerprint, it.deviceName)
    }

    internal fun installPicker(action: () -> Unit) { launchPicker = action }

    fun chooseFiles() {
        reviewedPeer = currentPeer()
        files = emptyList()
        visible = false
        resolving = false
        // Ask for a faster route before opening the picker; the captured peer remains the review target.
        controller.onDemandLanConnection?.invoke()
        controller.beginPicker()
        launchPicker()
    }

    internal fun selectionReturned(uris: List<Uri>) {
        controller.endPicker()
        if (uris.isEmpty()) { dismiss(); return }
        visible = true
        resolving = true
    }

    internal fun resolved(selection: List<TransferReviewFile>) {
        files = selection
        resolving = false
    }

    private fun retargetToCurrentPeer() { reviewedPeer = currentPeer() }

    private fun sendReviewedFiles() {
        val target = reviewedPeer ?: return
        val current = currentPeer() ?: return
        if (target.deviceId != current.deviceId || target.fingerprint != current.fingerprint) return
        if (files.isEmpty() || files.size > 128) return
        controller.sendUris(files.map { it.uri }, target.deviceId, target.fingerprint)
        dismiss()
    }

    fun dismiss() {
        files = emptyList()
        resolving = false
        visible = false
        reviewedPeer = null
    }

    @Composable
    fun ReviewDialog() {
        if (!visible) return
        val activePeer = currentPeer()
        val target = reviewedPeer
        val matches = target != null && activePeer?.deviceId == target.deviceId && activePeer.fingerprint == target.fingerprint
        val identityReady = controller.peerConnected && controller.peerCompatible && activePeer != null
        val totalSize = files.mapNotNull { it.size }.takeIf { it.size == files.size }?.sum()
        AlertDialog(
            onDismissRequest = ::dismiss,
            properties = DialogProperties(usePlatformDefaultWidth = true),
            title = { Text("Review files") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(target?.let { "To ${it.name}" } ?: "No connected device was selected.")
                    if (files.isNotEmpty()) {
                        Text(
                            "${files.size} file${if (files.size == 1) "" else "s"}" +
                                (totalSize?.let { " · ${Formatter.formatFileSize(LocalContext.current, it)}" } ?: ""),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        files.take(5).forEach { file ->
                            Text(file.name, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        if (files.size > 5) Text("+ ${files.size - 5} more", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (resolving) LinearProgressIndicator(Modifier.fillMaxWidth())
                    if (files.size > 128) Text("Choose no more than 128 files.", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error)
                    if (!identityReady) Text("Reconnect to the reviewed device before sending.", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    else if (!matches) Text("The connection changed. Review the current device before sending.", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            },
            confirmButton = {
                when {
                    resolving || files.isEmpty() || files.size > 128 -> Button(onClick = {}, enabled = false) { Text("Preparing…") }
                    !identityReady -> Button(onClick = {}, enabled = false) { Text("Reconnect") }
                    !matches -> Button(onClick = ::retargetToCurrentPeer) { Text("Review current device") }
                    else -> Button(onClick = ::sendReviewedFiles) { Text("Send files") }
                }
            },
            dismissButton = { TextButton(onClick = ::dismiss) { Text("Cancel") } }
        )
    }
}

@Composable
fun rememberSendFilesAction(controller: TransferController): TransferSendReview {
    val context = LocalContext.current
    val resolver = context.contentResolver
    val scope = rememberCoroutineScope()
    val review = remember(controller) { TransferSendReview(controller) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        review.selectionReturned(uris)
        if (uris.isNotEmpty()) scope.launch {
            val files = withContext(Dispatchers.IO) { uris.map { reviewFile(resolver, it) } }
            review.resolved(files)
        }
    }
    review.installPicker { launcher.launch(arrayOf("*/*")) }
    return review
}

private fun reviewFile(resolver: ContentResolver, uri: Uri): TransferReviewFile {
    var name = uri.lastPathSegment ?: "File"
    var size: Long? = null
    resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) {
            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (nameIndex >= 0) name = cursor.getString(nameIndex)?.takeIf(String::isNotEmpty) ?: name
            if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex).takeIf { it >= 0 }
        }
    }
    return TransferReviewFile(uri, name, size)
}

@Composable
fun TransferView(controller: TransferController, open: (() -> Unit)? = null, overview: Boolean = false) {
    val context = LocalContext.current
    val sendFiles = rememberSendFilesAction(controller)

    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }
    val destinationPicker = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val intent = result.data
        if (result.resultCode == android.app.Activity.RESULT_OK && intent?.data != null) {
            controller.acceptIncomingOffer(intent.data!!, intent.flags)
        }
        controller.endPicker()
    }

    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RectangleShape,
        color = Color.Transparent
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(if (overview) 0.dp else 16.dp),
            verticalArrangement = Arrangement.spacedBy(if (overview) 8.dp else 10.dp)
        ) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(Modifier.fillMaxWidth().then(if (open != null) Modifier.clickable(onClickLabel = "Open file transfer", onClick = open).heightIn(min = 48.dp) else Modifier),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(if (overview) "File transfer" else "Files", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                    if (open != null) Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = null, modifier = Modifier.size(18.dp))
                }
            }

            if (android.os.Build.VERSION.SDK_INT >= 33 && !androidx.core.app.NotificationManagerCompat.from(context).areNotificationsEnabled()) {
                TextButton(
                    onClick = { notificationPermission.launch(android.Manifest.permission.POST_NOTIFICATIONS) },
                    modifier = Modifier.heightIn(min = 48.dp)
                ) {
                    Text("Show transfer notifications")
                }
            }
            if (controller.preparing) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Preparing files…", style = MaterialTheme.typography.bodySmall)
                    TextButton(
                        onClick = { controller.cancelTransfer() },
                        modifier = Modifier.heightIn(min = 48.dp)
                    ) { Text("Cancel") }
                }
            }
            when (val current = controller.state) {
                is TransferState.Idle -> {
                    controller.activeChannel?.let { channel ->
                        Text(
                            if (channel.descriptor.transport == "lan") "Using local network" else "Using Bluetooth",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    if (!controller.peerConnected) {
                        Text(
                            "Connect your Mac to send files.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        OutlinedButton(
                            enabled = controller.peerConnected && controller.peerCompatible && !controller.preparing && controller.state is TransferState.Idle,
                            onClick = sendFiles::chooseFiles,
                            shape = MaterialTheme.shapes.small,
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
                            Icon(painterResource(R.drawable.ic_file_send), contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Send files…")
                        }

                    }
                }
                is TransferState.Connecting -> {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(20.dp),
                            strokeWidth = 2.dp
                        )
                        Text(
                            "Connecting to ${current.peerName} over local network…",
                            style = MaterialTheme.typography.bodyMedium
                        )
                    }
                    Text(
                        "Files will send automatically once connected.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    OutlinedButton(
                        onClick = { controller.cancelTransfer(local = true) },
                        shape = MaterialTheme.shapes.small,
                        modifier = Modifier.heightIn(min = 48.dp)
                    ) {
                        Text("Cancel")
                    }
                }
                is TransferState.WaitingForPeerApproval -> {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(20.dp),
                            strokeWidth = 2.dp
                        )
                        Text(
                            "Waiting for ${current.batch.peerName} to accept…",
                            style = MaterialTheme.typography.bodyMedium
                        )
                    }
                    Text(
                        "${current.batch.files.size} file${if (current.batch.files.size == 1) "" else "s"} · ${Formatter.formatFileSize(context, current.batch.totalBytes)}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    OutlinedButton(
                        onClick = { controller.cancelTransfer(local = true) },
                        shape = MaterialTheme.shapes.small,
                        modifier = Modifier.heightIn(min = 48.dp)
                    ) {
                        Text("Cancel")
                    }
                }
                is TransferState.IncomingOffer -> {
                    Text(
                        "Incoming files from ${current.batch.peerName}",
                        style = MaterialTheme.typography.bodyMedium
                    )
                    Text(
                        "${current.batch.files.size} file${if (current.batch.files.size == 1) "" else "s"} · ${Formatter.formatFileSize(context, current.batch.totalBytes)}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .background(
                                MaterialTheme.colorScheme.surface,
                                shape = MaterialTheme.shapes.extraSmall
                            )
                            .padding(8.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        current.batch.files.take(4).forEach { f ->
                            Text(
                                f.name,
                                style = MaterialTheme.typography.bodySmall,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        if (current.batch.files.size > 4) {
                            Text(
                                "+ ${current.batch.files.size - 4} more…",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                    Text(
                        "Choose a local folder for received files.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(
                            onClick = {
                                controller.beginPicker()
                                destinationPicker.launch(android.content.Intent(android.content.Intent.ACTION_OPEN_DOCUMENT_TREE)
                                    .addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                        android.content.Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION))
                            },
                            shape = MaterialTheme.shapes.small,
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
                            Text("Accept")
                        }
                        OutlinedButton(
                            onClick = { controller.rejectIncomingOffer(reason = 0L) },
                            shape = MaterialTheme.shapes.small,
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
                            Text("Decline")
                        }
                    }
                }
                is TransferState.Transferring -> {
                    val activity = if (controller.receiving) "Receiving" else "Sending"
                    val target = if (controller.receiving) "from" else "to"
                    // A received file is hashed and published after its final chunk, so the bar sits at
                    // 100% with no rate while nothing is being transferred. Say so instead of stalling.
                    val saving = controller.finalizing && current.fileBytes >= current.fileSize
                    val hasTotal = current.batch.totalBytes > 0
                    val fraction = if (hasTotal)
                        (current.totalBytes.toFloat() / current.batch.totalBytes.toFloat()).coerceIn(0f, 1f)
                    else 0f
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            "$activity ${current.fileName} $target ${current.batch.peerName}",
                            style = MaterialTheme.typography.bodyMedium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false)
                        )
                        Text(
                            "${current.fileIndex} of ${current.batch.files.size}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    controller.activeChannel?.let { channel ->
                        Text(
                            if (channel.descriptor.transport == "lan") "Using local network" else "Using Bluetooth",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    when {
                        saving -> LinearProgressIndicator(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(6.dp)
                                .semantics { contentDescription = "Verifying and saving ${current.fileName}" }
                        )
                        // An empty batch has no proportion to report; an invented 0% would read as a stall.
                        !hasTotal -> LinearProgressIndicator(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(6.dp)
                                .semantics { contentDescription = "$activity ${current.fileName}" }
                        )
                        else -> LinearProgressIndicator(
                            progress = { fraction },
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(6.dp)
                                .semantics { contentDescription = "$activity ${current.fileName}, ${(fraction * 100).toInt()} percent" }
                        )
                    }
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            if (hasTotal)
                                "${Formatter.formatFileSize(context, current.totalBytes)} of ${Formatter.formatFileSize(context, current.batch.totalBytes)}"
                            else "${Formatter.formatFileSize(context, current.totalBytes)} transferred",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        // No rate is not a rate of zero: the rolling window reports nothing until it has
                        // two observations and decays on a stall. Hold the cell and mark it unavailable.
                        Text(
                            if (current.speedBps > 0) "${Formatter.formatFileSize(context, current.speedBps.toLong())}/s" else "—",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    OutlinedButton(
                        onClick = { controller.cancelTransfer(local = true) },
                        shape = MaterialTheme.shapes.small,
                        modifier = Modifier.heightIn(min = 48.dp)
                    ) {
                        Text("Cancel")
                    }
                }
                is TransferState.Paused -> {
                    val activity = if (controller.receiving) "Receiving" else "Sending"
                    val target = if (controller.receiving) "from" else "to"
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            "$activity ${current.fileName} $target ${current.batch.peerName}",
                            style = MaterialTheme.typography.bodyMedium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false)
                        )
                        Text(
                            "${current.fileIndex} of ${current.batch.files.size}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Text(
                        "Paused: ${current.reason}. Progress is kept.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    val hasTotal = current.batch.totalBytes > 0
                    val fraction = if (hasTotal)
                        (current.totalBytes.toFloat() / current.batch.totalBytes.toFloat()).coerceIn(0f, 1f)
                    else 0f
                    if (hasTotal) {
                        LinearProgressIndicator(
                            progress = { fraction },
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(6.dp)
                                .semantics { contentDescription = "$activity ${current.fileName} paused, ${(fraction * 100).toInt()} percent" }
                        )
                    } else {
                        LinearProgressIndicator(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(6.dp)
                                .semantics { contentDescription = "$activity ${current.fileName} paused" }
                        )
                    }
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            if (hasTotal)
                                "${Formatter.formatFileSize(context, current.totalBytes)} of ${Formatter.formatFileSize(context, current.batch.totalBytes)}"
                            else "${Formatter.formatFileSize(context, current.totalBytes)} transferred",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(
                            when {
                                current.canResumeOverBle -> "Waiting, or continue over Bluetooth"
                                controller.receiving -> "Waiting for the connection"
                                else -> "Will resume automatically"
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (current.canResumeOverBle) {
                            Button(
                                onClick = { controller.resumeOverBluetooth() },
                                shape = MaterialTheme.shapes.small,
                                modifier = Modifier.heightIn(min = 48.dp)
                            ) {
                                Text("Continue over Bluetooth")
                            }
                        }
                        OutlinedButton(
                            onClick = { controller.cancelTransfer(local = true) },
                            shape = MaterialTheme.shapes.small,
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
                            Text("Cancel transfer")
                        }
                    }
                }
                is TransferState.Completed -> {
                    val files = "${current.fileCount} file${if (current.fileCount == 1) "" else "s"} (${Formatter.formatFileSize(context, current.totalBytes)})"
                    Text(
                        "Transfer completed",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.primary
                    )
                    Text(
                        if (controller.receiving) "$files saved to the folder you chose."
                        else "$files sent to your Mac.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (!controller.receiving) {
                            OutlinedButton(
                                onClick = {
                                    controller.dismiss()
                                    sendFiles.chooseFiles()
                                },
                                enabled = controller.peerConnected,
                                shape = MaterialTheme.shapes.small,
                                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                                modifier = Modifier.heightIn(min = 48.dp)
                            ) {
                                Icon(painterResource(R.drawable.ic_file_send), contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("Send more…")
                            }
                        }
                        OutlinedButton(
                            onClick = { controller.dismiss() },
                            shape = MaterialTheme.shapes.small,
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
                            Text("Done")
                        }
                    }
                }
                is TransferState.Rejected -> {
                    Text(
                        "Transfer declined by your Mac.",
                        style = MaterialTheme.typography.bodyMedium
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(
                            onClick = {
                                controller.dismiss()
                                sendFiles.chooseFiles()
                            },
                            enabled = controller.peerConnected,
                            shape = MaterialTheme.shapes.small,
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
                            Icon(painterResource(R.drawable.ic_file_send), contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Send files…")
                        }
                        OutlinedButton(
                            onClick = { controller.dismiss() },
                            shape = MaterialTheme.shapes.small,
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
                            Text("Dismiss")
                        }
                    }
                }
                is TransferState.Failed -> {
                    Text(
                        "Transfer failed: ${current.reason}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(
                            onClick = {
                                controller.dismiss()
                                sendFiles.chooseFiles()
                            },
                            enabled = controller.peerConnected,
                            shape = MaterialTheme.shapes.small,
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
                            Icon(painterResource(R.drawable.ic_file_send), contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Send files…")
                        }
                        OutlinedButton(
                            onClick = { controller.dismiss() },
                            shape = MaterialTheme.shapes.small,
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
                            Text("Dismiss")
                        }
                    }
                }
                is TransferState.Cancelled -> {
                    Text(
                        "Transfer cancelled.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(
                            onClick = {
                                controller.dismiss()
                                sendFiles.chooseFiles()
                            },
                            enabled = controller.peerConnected,
                            shape = MaterialTheme.shapes.small,
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
                            Icon(painterResource(R.drawable.ic_file_send), contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Send files…")
                        }
                        OutlinedButton(
                            onClick = { controller.dismiss() },
                            shape = MaterialTheme.shapes.small,
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
                            Text("Dismiss")
                        }
                    }
                }
            }
        }
        if (overview) {
            Spacer(Modifier.height(14.dp))
            HorizontalDivider()
        }
        sendFiles.ReviewDialog()
    }
}
