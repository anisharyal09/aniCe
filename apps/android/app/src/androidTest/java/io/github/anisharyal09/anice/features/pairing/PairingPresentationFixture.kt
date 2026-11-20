// SPDX-License-Identifier: GPL-3.0-or-later
// Keeps synthetic presentation mutation in emulator test code, bound to compiled property references.
package io.github.anisharyal09.anice.features.pairing

import android.os.Build
import androidx.compose.runtime.MutableState
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import kotlin.reflect.KProperty1
import org.junit.Assume.assumeTrue

internal class PairingPresentationFixture : AutoCloseable {
    private val runner = InstrumentationRegistry.getInstrumentation()
    val model: PairingViewModel
    private val store = ViewModelStore()

    init {
        check(Build.HARDWARE in setOf("ranchu", "goldfish"))
        check(runner.targetContext.packageName == "io.github.anisharyal09.anice.preview")
        model = PairingViewModel(runner.targetContext.applicationContext as AniCeApplication)
        store.put("comparison", model)
        model.beforePairing = {}
        model.cancel()
    }

    /** A renamed/non-observable property fails compilation or the fixture, not silently changed coverage. */
    @Suppress("UNCHECKED_CAST")
    fun <T> present(property: KProperty1<PairingViewModel, T>, value: T) {
        check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
        val field = PairingViewModel::class.java.getDeclaredField("${property.name}\$delegate")
            .apply { isAccessible = true }
        val state = field.get(model) as MutableState<T>
        state.value = value
        check(property.get(model) == value)
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
