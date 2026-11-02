// SPDX-License-Identifier: GPL-3.0-or-later
// Keeps the normal Android IME local while forwarding committed edits and selected control keys.
package io.github.anisharyal09.anice.features.phoneinput

import android.content.Context
import android.text.Editable
import android.text.TextWatcher
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputConnectionWrapper
import android.widget.EditText

class PhoneInputEditor(context: Context) : EditText(context) {
    var onEditorSnapshot: ((String) -> Unit)? = null
    var onKeyTransition: ((usage: Int, modifiers: Int, pressed: Boolean) -> Boolean)? = null

    private val localDeleteKeys = mutableSetOf<Int>()
    private val forwardedDeleteKeys = mutableSetOf<Int>()
    private val heldModifiers = mutableMapOf<Int, Int>()
    private var modifierSnapshot = 0
    private val publishSnapshot = Runnable {
        PhoneInputTextSync.committedSnapshot(
            text.toString(), BaseInputConnection.getComposingSpanStart(text),
            BaseInputConnection.getComposingSpanEnd(text),
        )?.let { onEditorSnapshot?.invoke(it) }
    }

    init {
        isSaveEnabled = false
        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(value: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(value: CharSequence?, start: Int, before: Int, count: Int) = scheduleSnapshot()
            override fun afterTextChanged(value: Editable?) = Unit
        })
    }

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        val target = super.onCreateInputConnection(outAttrs) ?: return null
        return object : InputConnectionWrapper(target, false) {
            override fun endBatchEdit(): Boolean = super.endBatchEdit().also { scheduleSnapshot() }
            override fun finishComposingText(): Boolean = super.finishComposingText().also { scheduleSnapshot() }
            override fun commitText(text: CharSequence, newCursorPosition: Int): Boolean =
                super.commitText(text, newCursorPosition).also { scheduleSnapshot() }
            override fun setComposingText(text: CharSequence, newCursorPosition: Int): Boolean =
                super.setComposingText(text, newCursorPosition).also { scheduleSnapshot() }
            override fun setComposingRegion(start: Int, end: Int): Boolean =
                super.setComposingRegion(start, end).also { scheduleSnapshot() }
            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean =
                super.deleteSurroundingText(beforeLength, afterLength).also { scheduleSnapshot() }
            override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int): Boolean =
                super.deleteSurroundingTextInCodePoints(beforeLength, afterLength).also { scheduleSnapshot() }
            override fun setSelection(start: Int, end: Int): Boolean =
                super.setSelection(start, end).also { scheduleSnapshot() }

            override fun sendKeyEvent(event: KeyEvent): Boolean {
                val keyCode = event.keyCode
                if (keyCode == KeyEvent.KEYCODE_DEL || keyCode == KeyEvent.KEYCODE_FORWARD_DEL) {
                    return handleDeleteKey(event)
                }
                val usage = keyUsage(keyCode) ?: return super.sendKeyEvent(event)
                val pressed = event.action == KeyEvent.ACTION_DOWN
                modifierBit(keyCode)?.let { bit ->
                    val alreadyPressed = heldModifiers.containsKey(keyCode)
                    if (pressed) heldModifiers[keyCode] = bit else heldModifiers.remove(keyCode)
                    modifierSnapshot = heldModifiers.values.fold(0) { value, next -> value or next }
                    if (alreadyPressed == pressed) return true
                }
                return if (onKeyTransition?.invoke(usage, modifierSnapshot, pressed) == true) true
                else super.sendKeyEvent(event)
            }

            private fun handleDeleteKey(event: KeyEvent): Boolean {
                val keyCode = event.keyCode
                if (event.action == KeyEvent.ACTION_UP) {
                    if (localDeleteKeys.remove(keyCode)) return super.sendKeyEvent(event)
                    if (forwardedDeleteKeys.remove(keyCode)) {
                        onKeyTransition?.invoke(keyUsage(keyCode)!!, modifierSnapshot, false)
                        return true
                    }
                    return super.sendKeyEvent(event)
                }

                if (event.action != KeyEvent.ACTION_DOWN) return super.sendKeyEvent(event)
                val before = text.toString()
                val handled = super.sendKeyEvent(event)
                scheduleSnapshot()
                if (text.toString() != before) {
                    localDeleteKeys += keyCode
                    return handled
                }
                if (keyCode in localDeleteKeys || keyCode in forwardedDeleteKeys) return handled
                val usage = keyUsage(keyCode) ?: return handled
                if (onKeyTransition?.invoke(usage, modifierSnapshot, true) == true) {
                    forwardedDeleteKeys += keyCode
                    return true
                }
                return handled
            }
        }
    }

    fun resetForwardedKeys() {
        localDeleteKeys.clear()
        forwardedDeleteKeys.clear()
        heldModifiers.clear()
        modifierSnapshot = 0
    }

    private fun scheduleSnapshot() {
        removeCallbacks(publishSnapshot)
        post(publishSnapshot)
    }

    private fun keyUsage(keyCode: Int): Int? = when (keyCode) {
        KeyEvent.KEYCODE_DEL -> 0x2A
        KeyEvent.KEYCODE_TAB -> 0x2B
        KeyEvent.KEYCODE_ENTER -> 0x28
        KeyEvent.KEYCODE_ESCAPE -> 0x29
        KeyEvent.KEYCODE_DPAD_RIGHT -> 0x4F
        KeyEvent.KEYCODE_DPAD_LEFT -> 0x50
        KeyEvent.KEYCODE_DPAD_DOWN -> 0x51
        KeyEvent.KEYCODE_DPAD_UP -> 0x52
        KeyEvent.KEYCODE_FORWARD_DEL -> 0x4C
        KeyEvent.KEYCODE_CTRL_LEFT -> 0xE0
        KeyEvent.KEYCODE_SHIFT_LEFT -> 0xE1
        KeyEvent.KEYCODE_ALT_LEFT -> 0xE2
        KeyEvent.KEYCODE_META_LEFT -> 0xE3
        KeyEvent.KEYCODE_CTRL_RIGHT -> 0xE4
        KeyEvent.KEYCODE_SHIFT_RIGHT -> 0xE5
        KeyEvent.KEYCODE_ALT_RIGHT -> 0xE6
        KeyEvent.KEYCODE_META_RIGHT -> 0xE7
        else -> null
    }

    private fun modifierBit(keyCode: Int): Int? = when (keyCode) {
        KeyEvent.KEYCODE_CTRL_LEFT -> 0x01
        KeyEvent.KEYCODE_SHIFT_LEFT -> 0x02
        KeyEvent.KEYCODE_ALT_LEFT -> 0x04
        KeyEvent.KEYCODE_META_LEFT -> 0x08
        KeyEvent.KEYCODE_CTRL_RIGHT -> 0x10
        KeyEvent.KEYCODE_SHIFT_RIGHT -> 0x20
        KeyEvent.KEYCODE_ALT_RIGHT -> 0x40
        KeyEvent.KEYCODE_META_RIGHT -> 0x80
        else -> null
    }

}
