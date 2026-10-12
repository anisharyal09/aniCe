// SPDX-License-Identifier: GPL-3.0-or-later
// Presents local file transfer controls, incoming batch approval and progress in the Android feature workspace.
package io.github.anisharyal09.anice.features.transfer

import android.os.Environment
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.io.File

@Composable
fun TransferView(controller: TransferController, compact: Boolean = false, onOpenDetails: () -> Unit = {}) {
    val context = LocalContext.current
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) {
            controller.sendUris(uris)
        }
    }

    val defaultDownloadFolder = remember {
        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            ?: context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: File(context.filesDir, "Downloads")
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
                Text("Local file transfer", style = MaterialTheme.typography.titleMedium)
            }

            when (val current = controller.state) {
                is TransferState.Idle -> {
                    Text(
                        "Send and receive files directly over authenticated local network.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    if (!controller.peerConnected) {
                        Text(
                            "Connect your trusted Mac over local network to transfer files.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Button(
                            onClick = {
                                if (!controller.peerConnected) {
                                    controller.onDemandLanConnection?.invoke()
                                }
                                launcher.launch(arrayOf("*/*"))
                            },
                            shape = MaterialTheme.shapes.small,
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
                            Text("Send files…")
                        }
                        if (!controller.peerConnected) {
                            OutlinedButton(
                                onClick = { controller.onDemandLanConnection?.invoke() },
                                shape = MaterialTheme.shapes.small,
                                modifier = Modifier.heightIn(min = 48.dp)
                            ) {
                                Text("Connect LAN")
                            }
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
                        "Save to: Downloads",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(
                            onClick = { controller.acceptIncomingOffer(defaultDownloadFolder) },
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
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            "Transferring ${current.fileName}",
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
                    LinearProgressIndicator(
                        progress = {
                            if (current.batch.totalBytes > 0)
                                (current.totalBytes.toFloat() / current.batch.totalBytes.toFloat()).coerceIn(0f, 1f)
                            else 0f
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(6.dp)
                    )
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            "${Formatter.formatFileSize(context, current.totalBytes)} of ${Formatter.formatFileSize(context, current.batch.totalBytes)}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        if (current.speedBps > 0) {
                            Text(
                                "${Formatter.formatFileSize(context, current.speedBps.toLong())}/s",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                    OutlinedButton(
                        onClick = { controller.cancelTransfer(local = true) },
                        shape = MaterialTheme.shapes.small,
                        modifier = Modifier.heightIn(min = 48.dp)
                    ) {
                        Text("Cancel")
                    }
                }
                is TransferState.Completed -> {
                    Text(
                        "Transfer completed",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.primary
                    )
                    Text(
                        "${current.fileCount} file${if (current.fileCount == 1) "" else "s"} (${Formatter.formatFileSize(context, current.totalBytes)}) transferred successfully.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(
                            onClick = {
                                controller.dismiss()
                                launcher.launch(arrayOf("*/*"))
                            },
                            enabled = controller.peerConnected,
                            shape = MaterialTheme.shapes.small,
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
                            Text("Send more…")
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
                        Button(
                            onClick = {
                                controller.dismiss()
                                launcher.launch(arrayOf("*/*"))
                            },
                            enabled = controller.peerConnected,
                            shape = MaterialTheme.shapes.small,
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
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
                        Button(
                            onClick = {
                                controller.dismiss()
                                launcher.launch(arrayOf("*/*"))
                            },
                            enabled = controller.peerConnected,
                            shape = MaterialTheme.shapes.small,
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
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
                        Button(
                            onClick = {
                                controller.dismiss()
                                launcher.launch(arrayOf("*/*"))
                            },
                            enabled = controller.peerConnected,
                            shape = MaterialTheme.shapes.small,
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) {
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
