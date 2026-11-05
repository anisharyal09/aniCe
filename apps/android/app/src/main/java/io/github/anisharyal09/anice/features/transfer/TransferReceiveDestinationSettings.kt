// SPDX-License-Identifier: GPL-3.0-or-later
// Lets the user choose and reset the saved receive folder from File transfer.
package io.github.anisharyal09.anice.features.transfer

import android.app.Activity
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
fun TransferReceiveDestinationSettings(controller: TransferController) {
    val selection = controller.destinationPreferences?.selection()
    val message = controller.destinationMessage
    val destinationLabel by produceState(
        initialValue = "Downloads/aniCe",
        key1 = selection,
        key2 = message,
    ) {
        // Document-provider metadata can block while the saved folder is resolved.
        value = withContext(Dispatchers.IO) {
            controller.destinationPreferences?.summary() ?: "Downloads/aniCe"
        }
    }
    val destinationPicker = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val intent = result.data
        if (result.resultCode == Activity.RESULT_OK && intent?.data != null) {
            controller.saveReceiveDestination(intent.data!!, intent.flags)
        }
        controller.endPicker()
    }
    val canChangeDestination = !controller.isBusy && !controller.preparing

    Row(
        modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Column(Modifier.weight(1f).padding(vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("Save received files to", style = MaterialTheme.typography.bodyMedium)
            Text(
                destinationLabel,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
            )
        }
        TextButton(
            onClick = {
                controller.beginPicker()
                destinationPicker.launch(
                    Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                    )
                )
            },
            enabled = canChangeDestination,
            modifier = Modifier.heightIn(min = 48.dp).semantics {
                contentDescription = "Choose receive folder"
            },
        ) {
            Text("Choose folder…")
        }
        if (controller.hasCustomReceiveDestination) {
            TextButton(
                onClick = controller::resetReceiveDestination,
                enabled = canChangeDestination,
                modifier = Modifier.heightIn(min = 48.dp).semantics {
                    contentDescription = "Reset receive folder to Downloads/aniCe"
                },
            ) {
                Text("Reset")
            }
        }
    }

}
