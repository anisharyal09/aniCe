// SPDX-License-Identifier: GPL-3.0-or-later
// Suppresses unrelated first-launch prompts only during isolated emulator presentation fixtures.
package io.github.anisharyal09.anice.ui

import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.MainActivity
import org.junit.Assume.assumeTrue
import org.junit.rules.ExternalResource

internal class PresentationFixture : AutoCloseable {
    private val runner = InstrumentationRegistry.getInstrumentation()
    private val preferences = runner.targetContext.getSharedPreferences("nearby_permission", Context.MODE_PRIVATE)
    private val hadRequested = preferences.contains("requested")
    private val requested = preferences.getBoolean("requested", false)
    init {
        assumeTrue("Only isolated emulator UI fixtures", Build.HARDWARE in setOf("ranchu", "goldfish"))
        assumeTrue("Use the isolated UI preview", runner.targetContext.packageName == "io.github.anisharyal09.anice.preview")
        check(preferences.edit().putBoolean("requested", true).commit())
    }
    fun intent() = Intent(runner.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    override fun close() {
        val edit = preferences.edit()
        if (hadRequested) edit.putBoolean("requested", requested) else edit.remove("requested")
        check(edit.commit())
    }
}

/** Suppress first-launch prompts before a fixture Activity exists; real-device tests stay unchanged. */
internal class EmulatorPresentationRule : ExternalResource() {
    private var fixture: PresentationFixture? = null
    override fun before() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        if (Build.HARDWARE in setOf("ranchu", "goldfish") &&
            context.packageName == "io.github.anisharyal09.anice.preview") fixture = PresentationFixture()
    }
    override fun after() { fixture?.close(); fixture = null }
}
