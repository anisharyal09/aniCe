// SPDX-License-Identifier: GPL-3.0-or-later
// Debug-only screen for observing real Android IME callback ordering without transmitting text.
package io.github.anisharyal09.anice.spikes

import android.app.Activity
import android.content.Context
import android.graphics.Typeface
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.Log
import android.view.KeyEvent
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputConnectionWrapper
import android.view.inputmethod.InputMethodManager
import android.view.inputmethod.SurroundingText
import android.view.inputmethod.TextAttribute
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

class ImeProbeActivity : Activity() {
    private val traceLock = Any()
    private val trace = ArrayDeque<String>()
    private var sequence = 0
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var editor: ProbeEditText
    private lateinit var traceView: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "IME input probe"

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(12), dp(16), dp(16))
        }
        root.addView(TextView(this).apply {
            text = "Debug-only. Use disposable text. Callback names and lengths stay on this device; text content is never recorded or sent."
            textSize = 14f
        }, matchWrap())

        editor = ProbeEditText(this, ::record).apply {
            hint = "Type a test word, use suggestions, then try Backspace"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or
                InputType.TYPE_TEXT_FLAG_AUTO_CORRECT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            imeOptions = EditorInfo.IME_ACTION_NONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI
            minLines = 3
            maxLines = 4
            textSize = 18f
            setPadding(dp(12), dp(10), dp(12), dp(10))
        }
        root.addView(editor, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(112)).apply {
            topMargin = dp(12)
        })

        root.addView(row(
            button("Clear editor") {
                editor.setText("")
                editor.setSelection(0)
                focusAndShowKeyboard()
            },
            button("Seed U+200B marker") {
                editor.setText(INVISIBLE_MARKER.toString())
                editor.setSelection(editor.text.length)
                focusAndShowKeyboard()
                record("editor seeded with one local U+200B marker")
            },
        ), matchWrap(top = 8))

        root.addView(row(
            button("Show keyboard") { focusAndShowKeyboard() },
            button("Hide keyboard") {
                (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager)
                    .hideSoftInputFromWindow(editor.windowToken, 0)
            },
            button("Clear trace") { clearTrace() },
        ), matchWrap(top = 4))

        traceView = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            textSize = 12f
            setTextIsSelectable(true)
            setPadding(dp(8), dp(8), dp(8), dp(8))
        }
        val scroll = ScrollView(this).apply { addView(traceView) }
        root.addView(scroll, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f,
        ).apply { topMargin = dp(8) })

        setContentView(root)
        editor.requestFocus()
        record("Ready. Test empty editor, marker, composing, suggestion replacement, autocorrect, and repeated Backspace.")
    }

    private fun focusAndShowKeyboard() {
        editor.requestFocus()
        editor.post {
            (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager)
                .showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT)
        }
    }

    private fun record(message: String) {
        val snapshot = synchronized(traceLock) {
            sequence += 1
            val line = "%03d %s".format(sequence, message)
            trace.addLast(line)
            while (trace.size > MAX_TRACE_LINES) trace.removeFirst()
            line
        }
        Log.i(TAG, snapshot)
        mainHandler.post {
            if (::traceView.isInitialized) {
                traceView.text = synchronized(traceLock) { trace.joinToString("\n") }
                (traceView.parent as? ScrollView)?.let { scrollView ->
                    scrollView.post { scrollView.scrollTo(0, traceView.height) }
                }
            }
        }
    }

    private fun clearTrace() {
        synchronized(traceLock) { trace.clear(); sequence = 0 }
        traceView.text = "Trace cleared"
    }

    private fun button(label: String, action: () -> Unit) = Button(this).apply {
        text = label
        setOnClickListener { action() }
        isAllCaps = false
    }

    private fun row(vararg children: Button) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        children.forEachIndexed { index, child ->
            addView(child, LinearLayout.LayoutParams(0, dp(48), 1f).apply {
                if (index > 0) marginStart = dp(6)
            })
        }
    }

    private fun matchWrap(top: Int = 0) = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
    ).apply { if (top > 0) topMargin = dp(top) }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    private fun textShape(text: CharSequence) =
        "utf16=${text.length}, codePoints=${Character.codePointCount(text, 0, text.length)}"

    private inner class ProbeEditText(context: Context, private val emit: (String) -> Unit) : EditText(context) {
        override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
            val target = super.onCreateInputConnection(outAttrs) ?: return null
            emit("onCreateInputConnection(inputType=${outAttrs.inputType}, imeOptions=${outAttrs.imeOptions})")
            return object : InputConnectionWrapper(target, false) {
                override fun beginBatchEdit(): Boolean = traced("beginBatchEdit") { super.beginBatchEdit() }
                override fun endBatchEdit(): Boolean = traced("endBatchEdit") { super.endBatchEdit() }
                override fun finishComposingText(): Boolean = traced("finishComposingText") { super.finishComposingText() }
                override fun commitText(text: CharSequence, newCursorPosition: Int): Boolean =
                    traced("commitText(${textShape(text)}, cursor=$newCursorPosition)") { super.commitText(text, newCursorPosition) }
                override fun commitText(text: CharSequence, newCursorPosition: Int, textAttribute: TextAttribute?): Boolean =
                    traced("commitText+attribute(${textShape(text)}, cursor=$newCursorPosition)") {
                        super.commitText(text, newCursorPosition, textAttribute)
                    }
                override fun setComposingText(text: CharSequence, newCursorPosition: Int): Boolean =
                    traced("setComposingText(${textShape(text)}, cursor=$newCursorPosition)") { super.setComposingText(text, newCursorPosition) }
                override fun setComposingText(text: CharSequence, newCursorPosition: Int, textAttribute: TextAttribute?): Boolean =
                    traced("setComposingText+attribute(${textShape(text)}, cursor=$newCursorPosition)") {
                        super.setComposingText(text, newCursorPosition, textAttribute)
                    }
                override fun replaceText(
                    start: Int,
                    end: Int,
                    text: CharSequence,
                    newCursorPosition: Int,
                    textAttribute: TextAttribute?,
                ): Boolean = traced(
                    "replaceText(range=$start..$end, ${textShape(text)}, cursor=$newCursorPosition)",
                ) { super.replaceText(start, end, text, newCursorPosition, textAttribute) }
                override fun setComposingRegion(start: Int, end: Int): Boolean =
                    traced("setComposingRegion($start, $end)") { super.setComposingRegion(start, end) }
                override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean =
                    traced("deleteSurroundingText(before=$beforeLength, after=$afterLength)") {
                        super.deleteSurroundingText(beforeLength, afterLength)
                    }
                override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int): Boolean =
                    traced("deleteSurroundingTextInCodePoints(before=$beforeLength, after=$afterLength)") {
                        super.deleteSurroundingTextInCodePoints(beforeLength, afterLength)
                    }
                override fun setSelection(start: Int, end: Int): Boolean =
                    traced("setSelection($start, $end)") { super.setSelection(start, end) }
                override fun getTextBeforeCursor(length: Int, flags: Int): CharSequence? {
                    val result = super.getTextBeforeCursor(length, flags)
                    emit("getTextBeforeCursor(request=$length, result=${result?.let(::textShape) ?: "null"})")
                    return result
                }
                override fun getTextAfterCursor(length: Int, flags: Int): CharSequence? {
                    val result = super.getTextAfterCursor(length, flags)
                    emit("getTextAfterCursor(request=$length, result=${result?.let(::textShape) ?: "null"})")
                    return result
                }
                override fun getSelectedText(flags: Int): CharSequence? {
                    val result = super.getSelectedText(flags)
                    emit("getSelectedText(result=${result?.let(::textShape) ?: "null"})")
                    return result
                }
                override fun getSurroundingText(beforeLength: Int, afterLength: Int, flags: Int): SurroundingText? {
                    val result = super.getSurroundingText(beforeLength, afterLength, flags)
                    val summary = result?.let {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            "${textShape(it.text)}, selection=${it.selectionStart}..${it.selectionEnd}, offset=${it.offset}"
                        } else "SurroundingText unavailable on this Android version"
                    } ?: "null"
                    emit("getSurroundingText(before=$beforeLength, after=$afterLength, result=$summary)")
                    return result
                }
                override fun sendKeyEvent(event: KeyEvent): Boolean =
                    traced("sendKeyEvent(action=${event.action}, keyCode=${event.keyCode})") { super.sendKeyEvent(event) }

                private fun traced(label: String, action: () -> Boolean): Boolean {
                    emit(label)
                    return action()
                }
            }
        }
    }

    companion object {
        private const val TAG = "AniCeImeProbe"
        private const val MAX_TRACE_LINES = 240
        private const val INVISIBLE_MARKER = '\u200B'
    }
}
