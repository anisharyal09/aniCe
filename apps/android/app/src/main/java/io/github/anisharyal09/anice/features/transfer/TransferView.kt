// SPDX-License-Identifier: GPL-3.0-or-later
// Presents local file transfer controls, incoming batch approval and progress in the Android feature workspace.
package io.github.anisharyal09.anice.features.transfer

import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.res.painterResource
import io.github.anisharyal09.anice.R
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

@Composable
fun rememberSendFilesAction(controller: TransferController): () -> Unit {
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) controller.sendUris(uris)
        controller.endPicker()
    }
    return {
        // File selection requests LAN without retiring the secured BLE channel or waiting for LAN readiness.
        controller.onDemandLanConnection?.invoke()
        controller.beginPicker()
        launcher.launch(arrayOf("*/*"))
    }
}

@Composable
fun TransferView(controller: TransferController, open: (() -> Unit)? = null) {
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
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceContainer
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(Modifier.fillMaxWidth().then(if (open != null) Modifier.clickable(onClickLabel = "Open file transfer", onClick = open).heightIn(min = 48.dp) else Modifier),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text("Files", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
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
                            enabled = !controller.preparing,
                            onClick = sendFiles,
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
                                    sendFiles()
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
                                sendFiles()
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
                                sendFiles()
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
                                sendFiles()
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
    }
}
