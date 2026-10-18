// SPDX-License-Identifier: GPL-3.0-or-later
// Routes selected and shared text into existing secured clipboard delivery without clipboard reads.
package io.github.anisharyal09.anice.features.clipboard

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
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
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import kotlinx.coroutines.launch

internal fun clipboardActionText(action: String?, type: String?, value: CharSequence?): String? {
    if (type != "text/plain" || action !in setOf(Intent.ACTION_PROCESS_TEXT, Intent.ACTION_SEND) || value == null || value.length > 65536) return null
    return value.toString().takeIf(::validHistoryText)
}

internal class SelectionSendState(private val owner: ClipboardController) : ViewModel() {
    var operation: ClipboardSendOperation? = null; private set
    fun start(text: String?) { if (operation == null) operation = owner.sendSelection(text) }
    fun cancel() { operation?.let(owner::cancelSelection) }
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
        // Recreation retains the operation, never the selected text in saved instance state.
        val text = if (savedInstanceState == null) try {
            val extra = when (intent.action) {
                Intent.ACTION_PROCESS_TEXT -> Intent.EXTRA_PROCESS_TEXT
                Intent.ACTION_SEND -> Intent.EXTRA_TEXT
                else -> null
            }
            clipboardActionText(intent.action, intent.type, extra?.let(intent::getCharSequenceExtra))
        } catch (_: android.os.BadParcelableException) { null }
          catch (_: ClassCastException) { null } else null
        intent.replaceExtras(null as Bundle?)
        intent.clipData = null
        state.start(text)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { state.cancel(); finish() }
        })
        var result by mutableStateOf<ClipboardSendResult?>(null)
        lifecycleScope.launch {
            result = state.operation!!.result()
            if (result == ClipboardSendResult.APPLIED) {
                Toast.makeText(this@SendToMacActivity, "Sent to Mac", Toast.LENGTH_SHORT).show(); finish()
            }
        }
        setContent { AniCeTheme {
            Surface { Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("Send to Mac", style = MaterialTheme.typography.titleLarge)
                when (result) {
                    null -> { Text("Sending to ${app.clipboard.selected?.deviceName ?: "Mac"}…"); LinearProgressIndicator(Modifier.fillMaxWidth()) }
                    ClipboardSendResult.APPLIED -> Text("Sent to Mac")
                    ClipboardSendResult.UNAVAILABLE -> Text("Connect first")
                    ClipboardSendResult.BUSY -> Text("Another clipboard send is in progress")
                    ClipboardSendResult.INVALID -> Text("Choose plain text up to 64 KiB")
                    ClipboardSendResult.CANCELLED -> Text("Send cancelled. Text already delivered cannot be recalled.")
                    ClipboardSendResult.REJECTED -> Text("The Mac could not apply this clipboard item")
                    ClipboardSendResult.UNCONFIRMED -> Text("Delivery unconfirmed")
                }
                TextButton(onClick = { state.cancel(); finish() }) { Text(if (result == null) "Cancel" else "Close") }
            } }
        } }
    }
    override fun onStart() { super.onStart(); app.sessionController.foreground(this); app.lanSessionController.foreground(this) }
    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations) state.cancel()
        app.sessionController.background(this, isChangingConfigurations)
        app.lanSessionController.background(this, isChangingConfigurations)
    }
}
