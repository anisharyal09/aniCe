// SPDX-License-Identifier: GPL-3.0-or-later
// Presents phone-side typing with the normal Android keyboard and explicit BLE session controls.
package io.github.anisharyal09.anice.features.phoneinput

import android.graphics.Color
import android.graphics.Typeface
import android.text.InputType
import android.view.Gravity
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.content.Context.INPUT_METHOD_SERVICE
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import io.github.anisharyal09.anice.features.session.SessionViewModel
import io.github.anisharyal09.anice.infrastructure.connections.ConnectionState
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord

@Composable
fun PhoneInputView(
    owner: PhoneInputController,
    session: SessionViewModel,
    peers: List<PeerTrustRecord>,
    onOpenDevice: (DeviceIdentity?) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val keyboard = LocalSoftwareKeyboardController.current
    val textSync = remember { PhoneInputTextSync() }
    val inputTextColor = MaterialTheme.colorScheme.onSurface.toArgb()
    val inputHintColor = MaterialTheme.colorScheme.onSurfaceVariant.toArgb()
    var editor by remember { mutableStateOf<PhoneInputEditor?>(null) }
    var localStatus by remember { mutableStateOf("") }
    var previouslyActive by remember { mutableStateOf(false) }

    val connectedPeer = session.selected?.takeIf {
        session.state == ConnectionState.SECURED && it.platform == "macos" && owner.connected(it)
    }
    val pairedMac = connectedPeer ?: session.selected?.takeIf { it.platform == "macos" }
        ?: peers.firstOrNull { it.peer.platform == "macos" }?.peer
    val compatible = connectedPeer?.let(owner::compatible) == true

    fun clearEditor() {
        editor?.let { field ->
            field.onEditorSnapshot = null
            field.onKeyTransition = null
            field.resetForwardedKeys()
            field.text.clear()
            field.clearFocus()
        }
        textSync.reset()
    }

    LaunchedEffect(owner.state, connectedPeer?.deviceId, connectedPeer?.fingerprint) {
        if (owner.active && connectedPeer != null) {
            localStatus = ""
            textSync.reset()
            editor?.let { field ->
                field.setText("")
                field.requestFocus()
                field.post {
                    (context.getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager)
                        ?.showSoftInput(field, InputMethodManager.SHOW_IMPLICIT)
                }
            }
        } else if (owner.active) {
            owner.stop()
        } else if (previouslyActive) {
            keyboard?.hide()
            editor?.let { field ->
                field.onEditorSnapshot = null
                field.onKeyTransition = null
                field.resetForwardedKeys()
                field.text.clear()
                field.clearFocus()
            }
            textSync.reset()
        }
        previouslyActive = owner.active
    }

    DisposableEffect(lifecycle, owner, textSync) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_PAUSE) {
                owner.stop()
                keyboard?.hide()
                clearEditor()
            }
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            owner.stop()
            clearEditor()
        }
    }

    fun stopAndClear() {
        owner.stop()
        keyboard?.hide()
        clearEditor()
    }

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        when {
            connectedPeer != null -> {
                Text(connectedPeer.deviceName, style = MaterialTheme.typography.titleSmall)
                Text(
                    "Bluetooth · Connected",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            pairedMac != null -> {
                Text("Connect to ${pairedMac.deviceName} over Bluetooth to type.",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedButton(onClick = { onOpenDevice(pairedMac) }, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text("Open device connection")
                }
            }
            else -> {
                Text("Pair a Mac, then connect over Bluetooth to type.",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedButton(onClick = { onOpenDevice(null) }, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text("Open Devices")
                }
            }
        }

        when {
            owner.state == PhoneInputState.ACTIVE -> OutlinedButton(
                onClick = ::stopAndClear,
                modifier = Modifier.heightIn(min = 48.dp),
            ) { Text("Stop typing") }
            owner.state == PhoneInputState.STARTING -> Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                Text("Waiting for Mac…", style = MaterialTheme.typography.bodyMedium)
                Spacer(Modifier.weight(1f))
                TextButton(onClick = ::stopAndClear, modifier = Modifier.heightIn(min = 48.dp)) { Text("Cancel") }
            }
            else -> OutlinedButton(
                onClick = { connectedPeer?.let(owner::start) },
                enabled = connectedPeer != null && compatible && owner.canStart(connectedPeer),
                modifier = Modifier.heightIn(min = 48.dp),
            ) { Text("Start typing") }
        }

        if (connectedPeer != null && !compatible) {
            Text(
                "Connect to a Mac running a version with Phone-to-Mac input support.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        val visibleStatus = localStatus.ifEmpty { owner.status }
        if (visibleStatus.isNotBlank()) {
            Text(visibleStatus, style = MaterialTheme.typography.bodySmall,
                color = if (localStatus.isNotEmpty() || visibleStatus.contains("unavailable", true) || visibleStatus.contains("stopped", true))
                    MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
        }

        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(12.dp),
            color = MaterialTheme.colorScheme.surfaceContainerLow,
        ) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Phone keyboard", style = MaterialTheme.typography.titleSmall)
                AndroidView(
                    modifier = Modifier.fillMaxWidth().heightIn(min = 104.dp, max = 176.dp)
                        .semantics { contentDescription = "Text field for typing on the connected Mac" },
                    factory = { viewContext ->
                        PhoneInputEditor(viewContext).apply {
                            configureInput(this, enabled = owner.active, textColor = inputTextColor, hintColor = inputHintColor)
                            editor = this
                        }
                    },
                    update = { field ->
                        editor = field
                        configureInput(field, enabled = owner.active, textColor = inputTextColor, hintColor = inputHintColor)
                        field.onEditorSnapshot = { snapshot ->
                            val commitLimit = connectedPeer?.let(owner::maximumTextBytes)
                                ?: PhoneInputTextSync.MAX_COMMIT_BYTES
                            when (val result = textSync.plan(snapshot, commitLimit)) {
                                is PhoneInputTextResult.Ready -> {
                                    if (!owner.sendText(result.plan)) localStatus = owner.status
                                }
                                PhoneInputTextResult.Unchanged -> Unit
                                PhoneInputTextResult.TooLarge -> {
                                    localStatus = "This typing session is limited to 64 KiB. Stop and start a new session."
                                    stopAndClear()
                                }
                                PhoneInputTextResult.InvalidUnicode -> {
                                    localStatus = "This keyboard edit could not be sent safely. Typing stopped."
                                    stopAndClear()
                                }
                                PhoneInputTextResult.CorrectionTooLarge -> {
                                    localStatus = "That edit changed too much sent text. Start a new typing session."
                                    stopAndClear()
                                }
                                PhoneInputTextResult.GraphemeTooLarge -> {
                                    localStatus = "That character sequence is too large to send safely."
                                    stopAndClear()
                                }
                            }
                        }
                        field.onKeyTransition = owner::sendKey
                    },
                )
                Text(
                    if (owner.active) "Type with your usual Android keyboard."
                    else "Start typing to open your usual Android keyboard.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Text(
            "Text stays in this screen. It is sent over the encrypted Bluetooth session and cleared when typing stops.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private fun configureInput(field: PhoneInputEditor, enabled: Boolean, textColor: Int, hintColor: Int) {
    field.apply {
        isEnabled = enabled
        isFocusable = true
        isFocusableInTouchMode = true
        val textInput = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or
            InputType.TYPE_TEXT_FLAG_AUTO_CORRECT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        if (inputType != textInput) inputType = textInput
        val options = EditorInfo.IME_ACTION_NONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI
        if (imeOptions != options) imeOptions = options
        if (minLines != 2) minLines = 2
        if (maxLines != 4) maxLines = 4
        if (gravity != (Gravity.TOP or Gravity.START)) gravity = Gravity.TOP or Gravity.START
        textSize = 16f
        typeface = Typeface.DEFAULT
        setTextColor(textColor)
        setHintTextColor(hintColor)
        hint = "Type here"
        setPadding((12 * resources.displayMetrics.density).toInt(), (10 * resources.displayMetrics.density).toInt(),
            (12 * resources.displayMetrics.density).toInt(), (10 * resources.displayMetrics.density).toInt())
        setBackgroundColor(Color.TRANSPARENT)
        if (isSingleLine) isSingleLine = false
    }
}
