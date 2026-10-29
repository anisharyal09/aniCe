// SPDX-License-Identifier: GPL-3.0-or-later
// Shares passed text or one explicitly focused clipboard sample through existing secured delivery.
package io.github.anisharyal09.anice.features.clipboard

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.ui.theme.AniCeTheme

internal fun clipboardActionText(action: String?, type: String?, value: CharSequence?): String? {
    if (type != "text/plain" || action !in setOf(Intent.ACTION_PROCESS_TEXT, Intent.ACTION_SEND) || value == null || value.length > 65536) return null
    return value.toString().takeIf(::validHistoryText)
}

internal class SelectionSendState(private val owner: ClipboardController) : ViewModel() {
    private var initialized = false
    var sampled by mutableStateOf(false); private set
    var clipboardMode by mutableStateOf(false); private set
    var sharedLink by mutableStateOf<String?>(null); private set
    var openingLink by mutableStateOf(false); private set
    val canOpenLink: Boolean get() = owner.sharePeer?.let(owner::supportsOpenLink) == true
    var sample by mutableStateOf<ClipboardSample?>(null); private set
    var confirming by mutableStateOf(false); private set
    var operation by mutableStateOf<ClipboardSendOperation?>(null); private set
    fun start(text: String?) {
        if (!initialized) {
            initialized = true
            if (clipboardLink(text) != null) sharedLink = text else operation = owner.sendSelection(text)
        }
    }
    fun chooseOpenLink() {
        val link = sharedLink ?: return
        sharedLink = null; openingLink = true; operation = owner.openLink(link)
    }
    fun chooseClipboardSend() {
        val text = sharedLink ?: return
        sharedLink = null; operation = owner.sendSelection(text)
    }
    fun openClipboard() { if (!initialized) { initialized = true; clipboardMode = true } }
    fun abandon() {
        if (initialized) return
        initialized = true
        // A new process cannot establish whether the previous receiver already applied the item.
        operation = ClipboardSendOperation().also { it.completion.complete(ClipboardSendResult.UNCONFIRMED) }
    }
    fun focused() {
        if (clipboardMode && !sampled && operation == null) { sampled = true; sample = owner.captureManual() }
    }
    fun send() {
        if (sample == null || operation != null) return
        if (sample!!.sensitive) confirming = true else submit()
    }
    fun confirm() { if (confirming) { confirming = false; submit() } }
    fun dismissConfirmation() { confirming = false }
    private fun submit() {
        // Pass the captured sample intact: dropping its marker would allow sensitive text into history.
        val captured = sample ?: return
        operation = owner.sendCaptured(captured); sample = null
    }
    fun cancel() { confirming = false; sample = null; sharedLink = null; operation?.let(owner::cancelSelection) }
    override fun onCleared() { cancel() }
}
class SendToMacActivity : ComponentActivity() {
    private lateinit var state: SelectionSendState
    private val app get() = application as AniCeApplication
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        val factory = viewModelFactory { initializer { SelectionSendState(app.clipboard) } }
        state = ViewModelProvider(this, factory)[SelectionSendState::class.java]
        // Configuration changes retain the ViewModel; process loss never restores text or replays a send.
        when {
            savedInstanceState != null -> state.abandon()
            intent.action == SEND_CLIPBOARD -> state.openClipboard()
            else -> {
                val text = try {
                    val extra = when (intent.action) {
                        Intent.ACTION_PROCESS_TEXT -> Intent.EXTRA_PROCESS_TEXT
                        Intent.ACTION_SEND -> Intent.EXTRA_TEXT
                        else -> null
                    }
                    clipboardActionText(intent.action, intent.type, extra?.let(intent::getCharSequenceExtra))
                } catch (_: android.os.BadParcelableException) { null }
                  catch (_: ClassCastException) { null }
                state.start(text)
            }
        }
        intent.replaceExtras(null as Bundle?); intent.clipData = null
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { state.cancel(); finish() }
        })
        setContent { AniCeTheme {
            var result by remember { mutableStateOf<ClipboardSendResult?>(null) }
            val operation = state.operation
            LaunchedEffect(operation) {
                result = operation?.result()
                if (result == ClipboardSendResult.APPLIED) {
                    Toast.makeText(this@SendToMacActivity, if (state.openingLink) "Opened in Mac" else "Sent to Mac", Toast.LENGTH_SHORT).show(); finish()
                }
            }
            Surface { Column(Modifier.verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(if (state.openingLink) "Open Link in Mac" else "Send to Mac", style = MaterialTheme.typography.titleLarge)
                if (state.sharedLink != null && operation == null) {
                    Text("Open this link in your Mac’s default browser, or send it to the Mac clipboard.")
                    Text(app.clipboard.sharePeer?.deviceName?.let { "To $it" } ?: "Connect your Mac first")
                    Button(onClick = state::chooseOpenLink, enabled = state.canOpenLink, shape = MaterialTheme.shapes.small) {
                        Text("Open in Mac")
                    }
                    OutlinedButton(onClick = state::chooseClipboardSend, shape = MaterialTheme.shapes.small) { Text("Send as clipboard") }
                    if (!state.canOpenLink) Text("Connect to a Mac with Open Link support to enable this option.")
                } else if (state.clipboardMode && operation == null) {
                    val captured = state.sample
                    if (!state.sampled) Text("Waiting for clipboard access…")
                    else if (captured == null) Text("Copy plain text, then open this tile again.")
                    else {
                        Text("${captured.text.toByteArray(Charsets.UTF_8).size} bytes · ${if (captured.sensitive) "Sensitive text" else "Plain text"}")
                        Text(app.clipboard.sharePeer?.deviceName?.let { "To $it" } ?: "Connect your Mac first")
                        OutlinedButton(onClick = state::send, shape = MaterialTheme.shapes.small) {
                            Icon(painterResource(R.drawable.ic_clipboard), contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Send to Mac")
                        }
                    }
                } else when (result) {
                    null -> { Text(if (state.openingLink) "Opening on ${app.clipboard.sharePeer?.deviceName ?: "Mac"}…" else "Sending to ${app.clipboard.sharePeer?.deviceName ?: "Mac"}…"); LinearProgressIndicator(Modifier.fillMaxWidth()) }
                    ClipboardSendResult.APPLIED -> Text(if (state.openingLink) "Opened in Mac" else "Sent to Mac")
                    ClipboardSendResult.UNAVAILABLE -> Text("Connect your Mac in aniCe, then try again.")
                    ClipboardSendResult.BUSY -> Text("Another send is in progress")
                    ClipboardSendResult.INVALID -> Text("Choose plain text up to 64 KiB")
                    ClipboardSendResult.CANCELLED -> Text(if (state.openingLink) "Open request cancelled." else "Send cancelled. Text already delivered cannot be recalled.")
                    ClipboardSendResult.REJECTED -> Text(if (state.openingLink) "The Mac could not open this link." else "The Mac could not apply this clipboard item")
                    ClipboardSendResult.UNCONFIRMED -> Text(if (state.openingLink) "Open request unconfirmed" else "Delivery unconfirmed")
                }
                if (result == ClipboardSendResult.UNAVAILABLE || state.clipboardMode && operation == null || state.sharedLink != null && !state.canOpenLink) {
                    TextButton(onClick = { state.cancel(); startActivity(Intent(this@SendToMacActivity, MainActivity::class.java)); finish() }) { Text("Open aniCe") }
                }
                TextButton(onClick = { state.cancel(); finish() }) { Text(if (operation != null && result == null) "Cancel" else "Close") }
            } }
            if (state.confirming) AlertDialog(onDismissRequest = state::dismissConfirmation,
                title = { Text("Send sensitive text?") }, text = { Text("Send this sensitive-marked clipboard item to your connected Mac?") },
                confirmButton = { TextButton(onClick = state::confirm) { Text("Send") } },
                dismissButton = { TextButton(onClick = state::dismissConfirmation) { Text("Cancel") } })
        } }
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Share/selection never reads the clipboard; only the tile's explicit mode receives read focus.
        if (::state.isInitialized && state.clipboardMode) {
            app.clipboard.focus(hasFocus, this, observe = false)
            if (hasFocus) state.focused()
        }
    }
    override fun onStart() { super.onStart(); app.sessionController.foreground(this); app.lanSessionController.foreground(this) }
    override fun onStop() {
        super.onStop()
        app.clipboard.focus(false, this, observe = false)
        if (!isChangingConfigurations) state.cancel()
        app.sessionController.background(this, isChangingConfigurations)
        app.lanSessionController.background(this, isChangingConfigurations)
    }
    companion object {
        private const val SEND_CLIPBOARD = "io.github.anisharyal09.anice.action.SEND_CLIPBOARD"
        fun clipboardIntent(context: Context): Intent = Intent(context, SendToMacActivity::class.java)
            .setAction(SEND_CLIPBOARD).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}
