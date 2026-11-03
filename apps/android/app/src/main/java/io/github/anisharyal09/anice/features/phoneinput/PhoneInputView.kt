// SPDX-License-Identifier: GPL-3.0-or-later
// Presents phone-side typing with the normal Android keyboard and explicit BLE session controls.
package io.github.anisharyal09.anice.features.phoneinput

import android.content.Context.INPUT_METHOD_SERVICE
import android.graphics.Color
import android.graphics.Typeface
import android.os.SystemClock
import android.text.InputType
import android.view.Gravity
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import io.github.anisharyal09.anice.features.session.SessionViewModel
import io.github.anisharyal09.anice.infrastructure.connections.ConnectionState
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord
import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.roundToInt

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
    var fullScreenEditor by remember { mutableStateOf<PhoneInputEditor?>(null) }
    var localStatus by remember { mutableStateOf("") }
    var liveTyping by remember { mutableStateOf(false) }
    var fullTrackpad by remember { mutableStateOf(false) }
    var openKeyboardAfterStart by remember { mutableStateOf(false) }
    var previouslyActive by remember { mutableStateOf(false) }

    val connectedPeer = session.selected?.takeIf {
        session.state == ConnectionState.SECURED && it.platform == "macos" && owner.connected(it)
    }
    val pairedMac = connectedPeer ?: session.selected?.takeIf { it.platform == "macos" }
        ?: peers.firstOrNull { it.peer.platform == "macos" }?.peer
    val compatible = connectedPeer?.let(owner::compatible) == true

    fun clearEditor() {
        listOfNotNull(editor, fullScreenEditor).distinct().forEach { field ->
            field.onEditorSnapshot = null
            field.onRawTextChanged = null
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
            listOfNotNull(editor, fullScreenEditor).distinct().forEach { field ->
                val rawTextCallback = field.onRawTextChanged
                field.onRawTextChanged = null
                field.setText("")
                field.setSelection(field.text.length)
                field.onRawTextChanged = rawTextCallback
            }
            (if (fullTrackpad) fullScreenEditor else editor)?.let { field ->
                if (openKeyboardAfterStart) {
                    openKeyboardAfterStart = false
                    field.requestFocus()
                    field.post {
                        (context.getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager)
                            ?.showSoftInput(field, InputMethodManager.SHOW_IMPLICIT)
                    }
                }
            }
        } else if (owner.active) {
            openKeyboardAfterStart = false
            owner.stop()
        } else if (previouslyActive) {
            keyboard?.hide()
            clearEditor()
        }
        if (owner.state == PhoneInputState.IDLE) openKeyboardAfterStart = false
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

    DisposableEffect(fullTrackpad) {
        onDispose {
            if (fullTrackpad) {
                fullScreenEditor?.let { field ->
                    field.onRawTextChanged = null
                    field.onEditorSnapshot = null
                    field.onKeyTransition = null
                    field.clearFocus()
                }
                fullScreenEditor = null
            }
        }
    }

    fun stopAndClear() {
        openKeyboardAfterStart = false
        owner.stop()
        keyboard?.hide()
        clearEditor()
    }

    fun syncEditorText(source: PhoneInputEditor, value: String) {
        // Mirror text while leaving IME composition metadata with the focused editor.
        val target = if (source === editor) fullScreenEditor else editor
        if (target == null || target.text.toString() == value) return
        val callback = target.onRawTextChanged
        target.onRawTextChanged = null
        target.setText(value)
        target.setSelection(target.text.length)
        target.onRawTextChanged = callback
    }

    fun handleEditorSnapshot(snapshot: String) {
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

    fun configurePhoneEditor(field: PhoneInputEditor, hint: String = "Type here") {
        field.sendComposingText = liveTyping
        configureInput(field, enabled = owner.active, textColor = inputTextColor, hintColor = inputHintColor)
        field.hint = hint
        field.onRawTextChanged = { value -> syncEditorText(field, value) }
        field.onEditorSnapshot = ::handleEditorSnapshot
        field.onKeyTransition = owner::sendKey
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
                    Text("Pair a Mac")
                }
            }
        }

        when {
            owner.state == PhoneInputState.ACTIVE -> OutlinedButton(
                onClick = ::stopAndClear,
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
            ) { Text("Stop control") }
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
                onClick = { openKeyboardAfterStart = false; localStatus = ""; connectedPeer?.let(owner::start) },
                shape = RoundedCornerShape(8.dp),
                enabled = connectedPeer != null && compatible && owner.canStart(connectedPeer),
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
            ) { Text("Start control") }
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

        if (connectedPeer != null) {
            PhoneInputTrackpad(
                owner = owner,
                enabled = owner.active && owner.supportsPointer(connectedPeer),
                pointerUnavailable = owner.active && !owner.supportsPointer(connectedPeer),
                onFullScreen = { keyboard?.hide(); fullTrackpad = true },
                sessionActive = owner.active,
            )
        }

        AutomaticConnectionToggle(
            checked = liveTyping,
            enabled = true,
            label = "Live typing",
            description = "Send text as it is composed.",
            compact = true,
            onCheckedChange = { liveTyping = it },
        )
        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(12.dp),
            color = MaterialTheme.colorScheme.surfaceContainerLow,
        ) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Phone keyboard", style = MaterialTheme.typography.titleSmall)
                AndroidView(
                    modifier = Modifier.fillMaxWidth().heightIn(min = 64.dp, max = 104.dp)
                        .semantics { contentDescription = "Text field for typing on the connected Mac" },
                    factory = { viewContext ->
                        PhoneInputEditor(viewContext).apply {
                            configurePhoneEditor(this)
                            editor = this
                        }
                    },
                    update = { field ->
                        editor = field
                        configurePhoneEditor(field)
                    },
                )
                Text(
                    if (owner.active) "Tap here to open your keyboard."
                    else "Start control, then tap here to type.",
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
    if (fullTrackpad) Dialog(
        onDismissRequest = { keyboard?.hide(); fullTrackpad = false },
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(Modifier.fillMaxSize()) {
            PhoneInputTrackpad(
                owner = owner,
                enabled = owner.active && connectedPeer?.let(owner::supportsPointer) == true,
                pointerUnavailable = owner.active && connectedPeer?.let { !owner.supportsPointer(it) } == true,
                onFullScreen = { keyboard?.hide(); fullTrackpad = false },
                fullScreen = true,
                sessionActive = owner.active,
                statusMessage = if (owner.active) null else localStatus.ifEmpty { owner.status },
                typingField = {
                    if (connectedPeer != null) {
                        Box(
                            Modifier.fillMaxWidth().height(52.dp)
                                .clip(RoundedCornerShape(10.dp))
                                .background(MaterialTheme.colorScheme.surfaceContainerLow)
                                .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(10.dp)),
                            contentAlignment = Alignment.CenterStart,
                        ) {
                            AndroidView(
                                modifier = Modifier.fillMaxSize().semantics {
                                    contentDescription = "Tap to type on the connected Mac"
                                },
                                factory = { viewContext ->
                                    PhoneInputEditor(viewContext).apply {
                                        editor?.let { setText(it.text) }
                                        configurePhoneEditor(this, "Type here on Mac")
                                        fullScreenEditor = this
                                        onFocusChangeListener = android.view.View.OnFocusChangeListener { view, focused ->
                                            if (focused) view.post {
                                                (context.getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager)
                                                    ?.showSoftInput(view, InputMethodManager.SHOW_IMPLICIT)
                                            }
                                        }
                                    }
                                },
                                update = { field ->
                                    fullScreenEditor = field
                                    configurePhoneEditor(field, "Type here on Mac")
                                },
                            )
                            if (!owner.active) {
                                Surface(
                                    modifier = Modifier.fillMaxSize().clickable(
                                        enabled = owner.state != PhoneInputState.STARTING && compatible &&
                                            owner.canStart(connectedPeer),
                                        role = Role.Button,
                                    ) {
                                        localStatus = ""
                                        openKeyboardAfterStart = true
                                        if (!owner.start(connectedPeer)) openKeyboardAfterStart = false
                                    }.semantics {
                                        contentDescription = when {
                                            !compatible -> "Update the Mac app to enable phone typing"
                                            owner.state == PhoneInputState.STARTING -> "Connecting to Mac"
                                            else -> "Tap to start typing on the connected Mac"
                                        }
                                    },
                                    color = MaterialTheme.colorScheme.surfaceContainerLow,
                                ) {
                                    Box(contentAlignment = Alignment.CenterStart) {
                                        Text(
                                            when {
                                                !compatible -> "Update the Mac app to enable typing"
                                                owner.state == PhoneInputState.STARTING -> "Connecting to Mac…"
                                                else -> "Tap to start typing"
                                            },
                                            modifier = Modifier.padding(horizontal = 12.dp),
                                            style = MaterialTheme.typography.bodyMedium,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                }
                            }
                        }
                    } else {
                        Text("Reconnect to a Mac to type.", style = MaterialTheme.typography.bodySmall)
                    }
                },
            )
        }
    }
}

@Composable
private fun PhoneInputTrackpad(
    owner: PhoneInputController,
    enabled: Boolean,
    pointerUnavailable: Boolean,
    onFullScreen: () -> Unit,
    fullScreen: Boolean = false,
    sessionActive: Boolean = enabled,
    statusMessage: String? = null,
    typingField: (@Composable () -> Unit)? = null,
) {
    val colorScheme = MaterialTheme.colorScheme
    val viewConfiguration = LocalViewConfiguration.current
    val touchSlop = viewConfiguration.touchSlop
    val longPressTimeout = viewConfiguration.longPressTimeoutMillis

    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        color = colorScheme.surfaceContainerLow,
    ) {
        Column(Modifier.padding(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Mac trackpad", style = MaterialTheme.typography.titleSmall)
                Spacer(Modifier.weight(1f))
                if (fullScreen && sessionActive) TextButton(onClick = owner::stop) { Text("Stop control") }
                else if (fullScreen && owner.state == PhoneInputState.STARTING) {
                    TextButton(onClick = owner::stop) { Text("Cancel") }
                }
                TextButton(onClick = onFullScreen) { Text(if (fullScreen) "Done" else "Full screen") }
            }
            if (fullScreen) typingField?.invoke()
            if (fullScreen && !sessionActive && !statusMessage.isNullOrBlank()) {
                Text(
                    statusMessage,
                    style = MaterialTheme.typography.bodySmall,
                    color = colorScheme.onSurfaceVariant,
                )
            }
            Box(
                modifier = Modifier.fillMaxWidth().then(if (fullScreen) Modifier.weight(1f) else Modifier.height(240.dp))
                    .clip(RoundedCornerShape(10.dp))
                    .background(colorScheme.surface)
                    .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(10.dp))
                    .semantics {
                        contentDescription = "Trackpad for the connected Mac"
                        stateDescription = if (enabled) "Active" else "Inactive"
                    }
                    .pointerInput(owner, enabled, touchSlop, longPressTimeout) {
                        // Leave events to the page's scroll container until the Mac session is active.
                        if (!enabled) return@pointerInput
                        awaitEachGesture {
                            val down = awaitFirstDown(requireUnconsumed = false)
                            down.consume()
                            var lastPosition = down.position
                            var lastCentroid: Offset? = null
                            var moved = false
                            var sentMovement = false
                            var multiplePointers = false
                            var dragging = false
                            var longPressTriggered = false
                            try {
                                while (true) {
                                    val remainingLongPress =
                                        (down.uptimeMillis + longPressTimeout - SystemClock.uptimeMillis())
                                            .coerceAtLeast(1L)
                                    val event = if (!moved && !multiplePointers && !dragging && !longPressTriggered) {
                                        withTimeoutOrNull(remainingLongPress) {
                                            awaitPointerEvent(PointerEventPass.Main)
                                        }
                                    } else {
                                        awaitPointerEvent(PointerEventPass.Main)
                                    }
                                    if (event == null) {
                                        // A failed long-press must not retry in a tight loop or become a tap.
                                        longPressTriggered = true
                                        dragging = owner.sendPointerButtons(1)
                                        continue
                                    }

                                    val pressed = event.changes.filter { it.pressed }
                                    if (pressed.isEmpty()) {
                                        event.changes.forEach { it.consume() }
                                        if (dragging) owner.sendPointerButtons(0)
                                        else if (!multiplePointers && !moved && !longPressTriggered) {
                                            owner.sendPointerButtons(1)
                                            owner.sendPointerButtons(0)
                                        }
                                        break
                                    }

                                    if (pressed.size > 1) {
                                        if (dragging) {
                                            owner.sendPointerButtons(0)
                                            dragging = false
                                        }
                                        multiplePointers = true
                                        val center = pressed.fold(Offset.Zero) { total, change -> total + change.position } /
                                            pressed.size.toFloat()
                                        lastCentroid?.let { previous ->
                                            val delta = center - previous
                                            owner.sendScroll((-delta.x).roundToInt(), (-delta.y).roundToInt())
                                        }
                                        lastCentroid = center
                                    } else if (!multiplePointers) {
                                        val change = pressed.first()
                                        val position = change.position
                                        val delta = position - lastPosition
                                        val total = position - down.position
                                        if (!moved && total.getDistance() > touchSlop) moved = true
                                        if (dragging) {
                                            owner.sendPointerMotion(delta.x.roundToInt(), delta.y.roundToInt())
                                        } else if (moved) {
                                            val movement = if (sentMovement) delta else total
                                            owner.sendPointerMotion(
                                                movement.x.roundToInt(), movement.y.roundToInt(),
                                            )
                                            sentMovement = true
                                        }
                                        lastPosition = position
                                    }
                                    event.changes.forEach { it.consume() }
                                }
                            } finally {
                                if (dragging) owner.sendPointerButtons(0)
                            }
                        }
                    },
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("⌖", style = MaterialTheme.typography.headlineMedium, color = colorScheme.onSurfaceVariant)
                    Text(
                        when {
                            enabled -> "Move to point · tap to click"
                            pointerUnavailable -> "Trackpad input needs a Mac update"
                            else -> "Start typing to use the trackpad"
                        },
                        style = MaterialTheme.typography.bodyMedium,
                        color = colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                }
            }
            Text(
                "One finger moves · long-press to drag · two fingers to scroll",
                style = MaterialTheme.typography.bodySmall,
                color = colorScheme.onSurfaceVariant,
            )
        }
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
        if (minLines != 1) minLines = 1
        if (maxLines != 2) maxLines = 2
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
