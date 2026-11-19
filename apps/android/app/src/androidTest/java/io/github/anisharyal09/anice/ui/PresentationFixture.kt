// SPDX-License-Identifier: GPL-3.0-or-later
// Suppresses unrelated first-launch prompts only during isolated emulator presentation fixtures.
package io.github.anisharyal09.anice.ui

import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.MainActivity
import org.junit.Assume.assumeTrue

internal class PresentationFixture : AutoCloseable {
    private val runner = InstrumentationRegistry.getInstrumentation()
    private val preferences = runner.targetContext.getSharedPreferences("nearby_permission", Context.MODE_PRIVATE)
    private val hadRequested = preferences.contains("requested")
    private val requested = preferences.getBoolean("requested", false)
    init {
        assumeTrue("Only isolated emulator UI fixtures", Build.HARDWARE in setOf("ranchu", "goldfish"))
        assumeTrue(runner.targetContext.packageName.contains(".preview"))
        check(preferences.edit().putBoolean("requested", true).commit())
    }
    fun intent() = Intent(runner.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    override fun close() {
        val edit = preferences.edit()
        if (hadRequested) edit.putBoolean("requested", requested) else edit.remove("requested")
        check(edit.commit())
    }
}
