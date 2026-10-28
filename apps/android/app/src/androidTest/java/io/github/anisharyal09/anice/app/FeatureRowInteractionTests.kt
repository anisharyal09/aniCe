// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies feature rows open once and the nested favourite action stays independent.
package io.github.anisharyal09.anice.app

import android.os.Build
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FeatureRowInteractionTests {
    @Test
    fun openingRowAndChangingFavouriteAreIndependentSingleActions() {
        assumeTrue("Feature interaction fixture runs only on an isolated emulator", Build.HARDWARE in setOf("ranchu", "goldfish"))
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            android.content.Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        ) as MainActivity
        val openEvents = AtomicInteger()
        val favouriteEvents = AtomicInteger()

        try {
            instrumentation.runOnMainSync {
                activity.setContent {
                    AniCeTheme {
                        Surface(Modifier.fillMaxSize()) {
                            FeatureEntry(
                                feature = AppFeature.Files,
                                favourite = false,
                                status = "Ready to send",
                                onFavourite = { favouriteEvents.incrementAndGet() },
                                onClick = { openEvents.incrementAndGet() },
                            )
                        }
                    }
                }
            }
            instrumentation.waitForIdleSync()
            instrumentation.uiAutomation.waitForIdle(250, 5_000)

            val row = findClickableText(instrumentation.uiAutomation.rootInActiveWindow, "Send files")
            assertNotNull("Feature label should expose the row action", row)
            assertTrue("Feature row click should be available to assistive technology", row!!.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            instrumentation.waitForIdleSync()
            assertEquals("Opening the row should fire one navigation action", 1, openEvents.get())
            assertEquals("Opening the row must not also favourite it", 0, favouriteEvents.get())

            val star = findClickableDescription(instrumentation.uiAutomation.rootInActiveWindow, "Add Send files to favourites")
            assertNotNull("Favourite control should remain separately accessible", star)
            assertTrue("Favourite action should be available to assistive technology", star!!.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            instrumentation.waitForIdleSync()
            assertEquals("Starring should not open the feature", 1, openEvents.get())
            assertEquals("Starring the row should fire once", 1, favouriteEvents.get())
        } finally {
            instrumentation.runOnMainSync { activity.finish() }
        }
    }

    private fun findClickableText(node: AccessibilityNodeInfo?, text: String): AccessibilityNodeInfo? {
        if (node == null) return null
        if (node.isClickable && node.text?.toString()?.contains(text) == true) return node
        for (index in 0 until node.childCount) {
            findClickableText(node.getChild(index), text)?.let { return it }
        }
        return null
    }

    private fun findClickableDescription(node: AccessibilityNodeInfo?, description: String): AccessibilityNodeInfo? {
        if (node == null) return null
        if (node.isClickable && node.contentDescription?.toString() == description) return node
        for (index in 0 until node.childCount) {
            findClickableDescription(node.getChild(index), description)?.let { return it }
        }
        return null
    }
}
