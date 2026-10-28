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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.shape.RoundedCornerShape
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord
import io.github.anisharyal09.anice.ui.theme.selectionAccent
import io.github.anisharyal09.anice.ui.theme.warning
import kotlinx.coroutines.launch

@Composable
fun SmsView(owner: SmsController, peers: List<PeerTrustRecord>, modifier: Modifier = Modifier) {
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
    val peerCredentials = peers.map { it.peer.deviceId + ":" + it.peer.fingerprint }
    LaunchedEffect(peerCredentials) { owner.retainDrafts(peerCredentials.toSet()) }
    Column(modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val relay = peers.firstOrNull { owner.reachable(it.peer) }
        val granted = state.receive && state.read && state.send
        Text(
            when {
                peers.isEmpty() -> "Pair a Mac to relay messages."
                relay != null -> "Sharing new messages with ${relay.peer.deviceName}."
                // Access granted is said once; the card below is the only thing that ever asks for it.
                granted -> "SMS access granted. Connect your Mac to share new messages and reply from it."
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
            Surface(color = MaterialTheme.colorScheme.surfaceContainerLow, shape = MaterialTheme.shapes.small) {
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
        if (owner.status.isNotEmpty() && owner.status !in setOf("Ready", "Message sent")) {
            Text(owner.status, style = MaterialTheme.typography.bodySmall,
                color = if ("rejected" in owner.status.lowercase() || "not confirmed" in owner.status.lowercase()) MaterialTheme.colorScheme.error
                else MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (owner.relayedLive + owner.waitingLive + owner.failedLive > 0) {
            Text("${owner.relayedLive} relayed · ${owner.waitingLive} waiting · ${owner.failedLive} not relayed",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (owner.skippedRows > 0) Text("${owner.skippedRows} rows could not be read", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)

        val threadId = owner.selectedThreadId
        if (threadId == null) {
            Text("Conversations", style = MaterialTheme.typography.titleSmall)
            when {
                owner.threads == null -> if (owner.loading) CircularProgressIndicator(Modifier.size(20.dp)) else Text("Conversations are unavailable", style = MaterialTheme.typography.bodyMedium)
                owner.threads!!.isEmpty() -> Text("No conversations on this device", style = MaterialTheme.typography.bodyMedium)
                else -> {
                    LazyColumn(Modifier.weight(1f).fillMaxWidth()) {
                        items(owner.threads!!, key = { it.threadId }) { record ->
                            Row(
                                Modifier.fillMaxWidth().clickable(role = Role.Button, onClickLabel = "Open conversation") { owner.select(record.threadId) }
                                    .heightIn(min = 64.dp).padding(vertical = 8.dp),
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
                        if (owner.threadsMore) item {
                            if (owner.loading) Text("Loading more conversations…", style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 8.dp))
                            else TextButton(onClick = owner::loadMoreThreads) { Text("Load more conversations") }
                        }
                    }
                }
            }
        } else {
            val record = owner.threads?.firstOrNull { it.threadId == threadId }
            val address = record?.address ?: threadId.removePrefix("addr:")
            val draftKey = "local|$threadId"
            var draft by remember(owner, draftKey) { mutableStateOf(owner.draft(draftKey)) }
            var sending by remember(draftKey) { mutableStateOf(false) }
            val bytes = draft.toByteArray(Charsets.UTF_8).size
            var simChoice by remember(draftKey) { mutableIntStateOf(0) }
            fun submitDraft() {
                if (sending || draft.isBlank() || bytes > SmsWireMessage.MAX_BODY_BYTES || !state.send) return
                sending = true
                val operation = owner.send(address, draft, simChoice, draftKey)
                scope.launch {
                    if (operation.result().result == 0L) {
                        draft = ""
                        owner.saveDraft(draftKey, "")
                    }
                    sending = false
                }
            }

            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { owner.select(null) }, contentPadding = PaddingValues(horizontal = 4.dp)) {
                    Icon(painterResource(R.drawable.ic_back), contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp)); Text("Conversations")
                }
                Text(address, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f))
                TextButton(onClick = owner::loadConversation, enabled = !owner.loading,
                    contentPadding = PaddingValues(horizontal = 8.dp), modifier = Modifier.heightIn(min = 48.dp)) { Text("Refresh") }
            }
            val multiSim = remember(draftKey) { owner.modemCount() >= 2 }
            val simListing = remember(draftKey) { mutableStateOf<SmsSubscriptionListing?>(null) }
            var simMenu by remember(draftKey) { mutableStateOf(false) }
            var simAnswered by remember(draftKey) { mutableStateOf(false) }
            LaunchedEffect(draftKey) { if (multiSim) simListing.value = owner.listSubscriptions() }
            val simEntries = simListing.value?.entries.orEmpty()
            val simChoiceLabel = simEntries.firstOrNull { it.subscriptionId == simChoice }?.let { simLabel(it, simEntries) }
            val phoneState = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
                simAnswered = true
                simListing.value = if (granted) owner.listSubscriptions() else SmsSubscriptionListing(1, emptyList())
            }
            val conversationList = rememberLazyListState()
            val conversationRows = owner.conversation.asReversed()
            LaunchedEffect(threadId, conversationRows.lastOrNull()?.messageId) {
                if (conversationRows.isNotEmpty()) conversationList.scrollToItem(conversationRows.size + if (owner.conversationMore) 0 else -1)
            }
            LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = conversationList, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (owner.conversationMore) item(key = "older") {
                    TextButton(onClick = owner::loadConversation, enabled = !owner.loading) { Text("Show older messages") }
                }
                if (conversationRows.isEmpty()) item(key = "empty") {
                    Text(if (owner.loading) "Loading messages…" else "No messages on this device",
                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 12.dp))
                }
                items(conversationRows, key = { it.messageId }) { message ->
                    val sim = if ((message.direction == 1L || message.subscriptionId != 0) && simEntries.map { it.subscriptionId }.distinct().size >= 2)
                        " · " + simName(message.subscriptionId, simEntries) else ""
                    val stateLabel = (if (message.direction == 1L) if (message.pending) "Sending" else "Sent" else "Received") +
                        " · " + stamp(message.dateMillis) + sim + if (message.unread) " · Unread" else ""
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (message.direction == 1L) Arrangement.End else Arrangement.Start) {
                        Surface(
                            modifier = Modifier.fillMaxWidth(0.88f),
                            shape = RoundedCornerShape(12.dp),
                            color = if (message.direction == 1L) MaterialTheme.colorScheme.surfaceContainerHigh else MaterialTheme.colorScheme.surfaceContainerLow
                        ) {
                            Column(Modifier.padding(horizontal = 12.dp, vertical = 9.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                Text(message.text, style = MaterialTheme.typography.bodyMedium)
                                Text(stateLabel, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                OutlinedTextField(value = draft, onValueChange = { draft = it; owner.saveDraft(draftKey, it) },
                    label = { Text("SMS message") }, modifier = Modifier.fillMaxWidth(), enabled = !sending,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(onSend = { submitDraft() }), maxLines = 4)
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("$bytes / ${SmsWireMessage.MAX_BODY_BYTES} bytes", style = MaterialTheme.typography.bodySmall,
                        color = if (bytes > SmsWireMessage.MAX_BODY_BYTES) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f))
                    if (multiSim && state.send && (simEntries.size >= 2 || (simListing.value?.result == 1L && !simAnswered))) {
                        Box {
                            TextButton(onClick = {
                                if (simEntries.size >= 2) simMenu = true else phoneState.launch(Manifest.permission.READ_PHONE_STATE)
                            }, contentPadding = PaddingValues(horizontal = 8.dp), modifier = Modifier.heightIn(min = 48.dp)) {
                                Text(if (simEntries.size >= 2) "SIM: " + (simChoiceLabel ?: "Default") else "Choose SIM…",
                                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                            DropdownMenu(expanded = simMenu, onDismissRequest = { simMenu = false }) {
                                DropdownMenuItem(text = { Text("Phone default") }, onClick = { simChoice = 0; simMenu = false })
                                simEntries.forEach { entry ->
                                    DropdownMenuItem(text = { Text(if (entry.isDefault) simLabel(entry, simEntries) + " (default)" else simLabel(entry, simEntries)) },
                                        onClick = { simChoice = entry.subscriptionId; simMenu = false })
                                }
                            }
                        }
                    }
                    OutlinedIconButton(onClick = ::submitDraft,
                        enabled = !sending && draft.isNotBlank() && bytes <= SmsWireMessage.MAX_BODY_BYTES && state.send,
                        modifier = Modifier.size(48.dp)) {
                        Icon(painterResource(R.drawable.ic_sms), contentDescription = if (sending) "Sending message" else "Send SMS")
                    }
                }
                if (draft.length > 1000) Text("Long messages may be rejected; Unicode text reaches the limit sooner.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.warning)
            }
        }
    }
}

@Composable
fun SmsSettings(owner: SmsController) {
    LaunchedEffect(Unit) { owner.refreshPermissions() }
    val state = owner.permissionsState
    // A full grant removes the Settings card entirely; the panel already reports **SMS access granted**.
    if (state.receive && state.read && state.send) return
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            "Still needed: ${missingLabels(state)}.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        if (owner.skippedRows > 0) Text("${owner.skippedRows} rows could not be read", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Two subscriptions can carry the same display name; the slot disambiguates them. */
private fun simLabel(entry: SmsSubscription, all: List<SmsSubscription>): String =
    if (entry.label.isNotEmpty() && all.count { it.label == entry.label } > 1) "${entry.label} (SIM ${entry.slotIndex + 1})" else entry.label

/** Subscription 0 means the phone default for a sent reply and unknown for a received row. */
private fun simName(subscriptionId: Int, entries: List<SmsSubscription>): String {
    if (subscriptionId == 0) return "Phone default"
    return entries.firstOrNull { it.subscriptionId == subscriptionId }?.let { simLabel(it, entries) } ?: "SIM $subscriptionId"
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
