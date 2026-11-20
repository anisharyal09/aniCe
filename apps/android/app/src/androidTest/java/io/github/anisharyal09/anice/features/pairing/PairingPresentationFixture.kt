// SPDX-License-Identifier: GPL-3.0-or-later
// Injects typed presentation into one isolated emulator model without reflecting compiler-generated fields.
package io.github.anisharyal09.anice.features.pairing

import android.os.Build
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import org.junit.Assume.assumeTrue

internal class PairingPresentationFixture : AutoCloseable {
    private val runner = InstrumentationRegistry.getInstrumentation()
    val presentation = PairingPresentationState()
    val model: PairingViewModel
    private val store = ViewModelStore()

    init {
        check(Build.HARDWARE in setOf("ranchu", "goldfish"))
        check(runner.targetContext.packageName == "io.github.anisharyal09.anice.preview")
        model = PairingViewModel(runner.targetContext.applicationContext as AniCeApplication, presentation)
        store.put("comparison", model)
        model.beforePairing = {}
        model.cancel()
    }

    fun present(update: PairingPresentationState.() -> Unit) {
        check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
        presentation.update()
    }

    override fun close() { model.cancel(); store.clear() }

    companion object {
        /** JUnit assumptions belong on the runner thread, never inside runOnMainSync. */
        fun assumeIsolated() {
            assumeTrue("Only isolated emulator presentation fixtures", Build.HARDWARE in setOf("ranchu", "goldfish"))
            assumeTrue("Use the UI preview",
                InstrumentationRegistry.getInstrumentation().targetContext.packageName == "io.github.anisharyal09.anice.preview")
        }
    }
}
