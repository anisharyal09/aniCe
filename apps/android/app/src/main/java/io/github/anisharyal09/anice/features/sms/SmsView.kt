// SPDX-License-Identifier: GPL-3.0-or-later
// Presents SMS permission state, provider conversations, live relay and local compose.
package io.github.anisharyal09.anice.features.sms

import android.Manifest
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord
import io.github.anisharyal09.anice.ui.theme.selectionAccent
import io.github.anisharyal09.anice.ui.theme.warning
import kotlinx.coroutines.launch

@Composable
fun SmsView(owner: SmsController, peers: List<PeerTrustRecord>) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) owner.refreshPermissions()
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    var refused by remember { mutableStateOf(false) }
    val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
        owner.refreshPermissions()
        refused = results.any { (permission, granted) ->
            !granted && context.findActivity()?.shouldShowRequestPermissionRationale(permission) != true
        }
    }
    val state = owner.permissionsState
    LaunchedEffect(Unit) { owner.refreshPermissions() }
    LaunchedEffect(state.read) { if (state.read && owner.threads == null) owner.loadThreads() }
    BackHandler(enabled = owner.selectedThreadId != null) { owner.select(null) }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        val relay = peers.firstOrNull { owner.reachable(it.peer) }
        Text(
            when {
                peers.isEmpty() -> "Pair a Mac to relay messages."
                relay != null -> "Sharing new messages with ${relay.peer.deviceName}."
                else -> "Connect your Mac to share new messages and reply from it."
            },
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        val missing = buildList {
            if (!state.receive) add(Manifest.permission.RECEIVE_SMS)
            if (!state.read) add(Manifest.permission.READ_SMS)
            if (!state.send) add(Manifest.permission.SEND_SMS)
        }
        if (missing.isNotEmpty()) {
            Surface(color = MaterialTheme.colorScheme.surfaceContainer, shape = MaterialTheme.shapes.small) {
                Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("SMS permissions", style = MaterialTheme.typography.titleSmall)
                    Text("Needed to ${missingLabels(state)}.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    OutlinedButton(onClick = { refused = false; request.launch(missing.toTypedArray()) },
                        shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                        modifier = Modifier.heightIn(min = 48.dp)) { Text("Allow SMS access") }
                    if (refused) {
                        Text("Android may also restrict SMS access for apps installed outside a store. Open App info, choose Allow restricted settings, then grant permission.",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        TextButton(onClick = {
                            context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)))
                        }) { Text("Open app settings") }
                    }
                }
            }
        }
        val threadId = owner.selectedThreadId
        if (threadId == null) {
            Text("Conversations", style = MaterialTheme.typography.titleSmall)
            when {
                owner.threads == null -> if (owner.loading) CircularProgressIndicator(Modifier.size(20.dp)) else Text("Conversations are unavailable", style = MaterialTheme.typography.bodyMedium)
                owner.threads!!.isEmpty() -> Text("No conversations on this device", style = MaterialTheme.typography.bodyMedium)
                else -> owner.threads!!.forEach { record ->
                    Row(
                        Modifier.fillMaxWidth().clickable(role = Role.Button, onClickLabel = "Open conversation") { owner.select(record.threadId) }
                            .heightIn(min = 48.dp).padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(record.address, style = MaterialTheme.typography.titleSmall)
                            if (record.snippet.isNotEmpty()) Text(record.snippet, style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(stamp(record.dateMillis), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (record.unreadCount > 0) Text("${record.unreadCount} unread", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.selectionAccent)
                        }
                    }
                    HorizontalDivider()
                }
            }
        } else {
            TextButton(onClick = { owner.select(null) }) {
                Icon(painterResource(R.drawable.ic_back), contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("All conversations")
            }
            val record = owner.threads?.firstOrNull { it.threadId == threadId }
            Text(record?.address ?: threadId.removePrefix("addr:"), style = MaterialTheme.typography.titleSmall)
            // The reply box stays directly above the newest message, so sending a reply never needs a scroll.
            var draft by remember(threadId) { mutableStateOf("") }
            var sending by remember(threadId) { mutableStateOf(false) }
            val bytes = draft.toByteArray(Charsets.UTF_8).size
            OutlinedTextField(value = draft, onValueChange = { draft = it }, label = { Text("Reply from this phone") },
                modifier = Modifier.fillMaxWidth(), enabled = !sending)
            Text("$bytes / ${SmsWireMessage.MAX_BODY_BYTES} bytes", style = MaterialTheme.typography.bodySmall,
                color = if (bytes > SmsWireMessage.MAX_BODY_BYTES) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
            if (draft.length > 1000) Text("Very long messages may be rejected by carriers; Unicode text reaches the limit sooner.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.warning)
            val address = record?.address ?: threadId.removePrefix("addr:")
            OutlinedButton(
                onClick = {
                    sending = true
                    val operation = owner.send(address, draft)
                    scope.launch {
                        if (operation.result().result == 0L) draft = ""
                        sending = false
                    }
                },
                enabled = !sending && draft.isNotBlank() && bytes <= SmsWireMessage.MAX_BODY_BYTES && state.send,
                shape = MaterialTheme.shapes.small, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                modifier = Modifier.heightIn(min = 48.dp)
            ) {
                Icon(painterResource(R.drawable.ic_sms), contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Send SMS")
            }
            if (owner.conversation.isEmpty()) Text(if (owner.loading) "Loading messages…" else "No messages on this device",
                style = MaterialTheme.typography.bodyMedium)
            else owner.conversation.forEach { message ->
                Column(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(message.text, style = MaterialTheme.typography.bodyMedium)
                    Text(
                        (if (message.direction == 1L) "Sent" else "Received") + " · " + stamp(message.dateMillis) +
                            (if (message.unread) " · Unread" else "") + (if (message.pending) " · Sending" else ""),
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                HorizontalDivider()
            }
            if (owner.conversationMore) TextButton(onClick = owner::loadConversation, enabled = !owner.loading) { Text("Show older messages") }
        }
        if (owner.status != "Grant SMS permissions to relay messages") Text(owner.status, style = MaterialTheme.typography.bodySmall)
        // Counts are always shown so an idle relay is distinguishable from a missing line.
        Text(
            "${owner.relayedLive} relayed · ${owner.waitingLive} waiting · ${owner.failedLive} not relayed",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        if (owner.skippedRows > 0) Text("${owner.skippedRows} rows could not be read", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
fun SmsSettings(owner: SmsController, onOpen: () -> Unit) {
    LaunchedEffect(Unit) { owner.refreshPermissions() }
    val state = owner.permissionsState
    val ready = state.receive && state.read && state.send
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            if (ready) "Relaying incoming messages to your Mac."
            else "Grant ${missingLabels(state)} to relay messages.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        if (owner.skippedRows > 0) Text("${owner.skippedRows} rows could not be read", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        OutlinedButton(onClick = onOpen, shape = MaterialTheme.shapes.small,
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp), modifier = Modifier.heightIn(min = 48.dp)) { Text("Open Messages") }
    }
}

/** Lists the missing capabilities without implying a permission the user has not granted. */
private fun missingLabels(state: SmsPermissionState): String = listOfNotNull(
    if (!state.receive) "receive new messages" else null,
    if (!state.read) "read conversations" else null,
    if (!state.send) "send replies" else null,
).joinToString(", ").ifEmpty { "SMS access" }

private fun stamp(millis: Long): String =
    java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.SHORT, java.text.DateFormat.SHORT).format(java.util.Date(millis))

private fun Context.findActivity(): android.app.Activity? {
    var current: Context? = this
    while (current is ContextWrapper) {
        if (current is android.app.Activity) return current
        current = current.baseContext
    }
    return null
}
