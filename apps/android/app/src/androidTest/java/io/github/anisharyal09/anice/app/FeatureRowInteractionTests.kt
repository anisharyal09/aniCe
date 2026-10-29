// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies accessible destination return and independent feature-row actions.
package io.github.anisharyal09.anice.app

import android.os.Build
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.lifecycle.ViewModelProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.MainActivity
import io.github.anisharyal09.anice.features.deviceidentity.DeviceIdentityViewModel
import io.github.anisharyal09.anice.features.discovery.DiscoveryViewModel
import io.github.anisharyal09.anice.features.pairing.PairingViewModel
import io.github.anisharyal09.anice.features.session.SessionViewModel
import io.github.anisharyal09.anice.ui.theme.AniCeTheme
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FeatureRowInteractionTests {
    @Test
    fun largeTextNavigationRevealsSelectedDestinationAfterBack() {
        assumeTrue("Navigation fixture runs only on an isolated emulator", Build.HARDWARE in setOf("ranchu", "goldfish"))
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.uiAutomation
        val activity = instrumentation.startActivitySync(
            android.content.Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        ) as MainActivity
        val drawn = CountDownLatch(1)
        try {
            instrumentation.runOnMainSync {
                val models = ViewModelProvider(activity)
                val identity = models[DeviceIdentityViewModel::class.java]
                val discovery = models[DiscoveryViewModel::class.java]
                val pairing = models[PairingViewModel::class.java]
                val session = models[SessionViewModel::class.java]
                activity.setContent {
                    val density = LocalDensity.current
                    CompositionLocalProvider(LocalDensity provides Density(density.density, 2f)) {
                        key("large-text-navigation") {
                            AniCeTheme { AppRoot(identity, discovery, pairing, session) }
                        }
                    }
                    SideEffect {
                        activity.window.decorView.postOnAnimation {
                            activity.window.decorView.postOnAnimation { drawn.countDown() }
                        }
                    }
                }
            }
            assertTrue("Navigation fixture did not draw", drawn.await(10, TimeUnit.SECONDS))
            instrumentation.waitForIdleSync()
            instrumentation.uiAutomation.waitForIdle(300, 5_000)
            val more = awaitControl(instrumentation, "More destinations")
            assertNotNull("Missing navigation scroll control:\n" + describe(instrumentation.uiAutomation.rootInActiveWindow), more)
            assertTrue(more!!.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            instrumentation.uiAutomation.waitForIdle(500, 5_000)
            val settings = awaitControl(instrumentation, "Settings")
            assertNotNull(settings)
            assertTrue(settings!!.isVisibleToUser)
            assertTrue(settings.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            assertNotNull("Settings must be selected before Back:\n" + describe(instrumentation.uiAutomation.rootInActiveWindow),
                awaitControl(instrumentation, "Settings", selected = true))
            instrumentation.runOnMainSync { activity.onBackPressedDispatcher.onBackPressed() }
            instrumentation.waitForIdleSync()
            instrumentation.uiAutomation.waitForIdle(500, 5_000)
            val home = awaitControl(instrumentation, "Home", selected = true)
            assertNotNull("Home destination after Back:\n" + describe(instrumentation.uiAutomation.rootInActiveWindow), home)
            assertTrue("Back must reveal the selected Home destination", home!!.isVisibleToUser)
            assertTrue(home.isSelected)
            val bounds = android.graphics.Rect()
            home.getBoundsInScreen(bounds)
            assertTrue("Selected destination must fit the viewport", bounds.left >= 0 &&
                bounds.right <= activity.resources.displayMetrics.widthPixels && bounds.width() > 0)
        } finally {
            instrumentation.runOnMainSync { activity.finish() }
        }
    }

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
        val drawn = CountDownLatch(1)

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
                    SideEffect {
                        activity.window.decorView.postOnAnimation {
                            activity.window.decorView.postOnAnimation { drawn.countDown() }
                        }
                    }
                }
            }
            assertTrue("Feature fixture did not draw", drawn.await(10, TimeUnit.SECONDS))
            instrumentation.waitForIdleSync()
            instrumentation.uiAutomation.waitForIdle(250, 5_000)

            val row = findLabeledControl(instrumentation.uiAutomation.rootInActiveWindow, "Send files")
            assertNotNull("Feature label should expose the row action:\n" + describe(instrumentation.uiAutomation.rootInActiveWindow), row)
            assertTrue("Feature row click should be available to assistive technology", row!!.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            instrumentation.waitForIdleSync()
            assertEquals("Opening the row should fire one navigation action", 1, openEvents.get())
            assertEquals("Opening the row must not also favourite it", 0, favouriteEvents.get())

            val star = findLabeledControl(instrumentation.uiAutomation.rootInActiveWindow, "Add Send files to favourites")
            assertNotNull("Favourite control should remain separately accessible", star)
            assertTrue("Favourite action should be available to assistive technology", star!!.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            instrumentation.waitForIdleSync()
            assertEquals("Starring should not open the feature", 1, openEvents.get())
            assertEquals("Starring the row should fire once", 1, favouriteEvents.get())
        } finally {
            instrumentation.runOnMainSync { activity.finish() }
        }
    }

    private fun awaitControl(runner: android.app.Instrumentation, label: String, selected: Boolean = false): AccessibilityNodeInfo? {
        val deadline = android.os.SystemClock.uptimeMillis() + 5_000
        do {
            if (Build.VERSION.SDK_INT >= 34) runner.uiAutomation.clearCache()
            val control = findLabeledControl(runner.uiAutomation.rootInActiveWindow, label)
            if (control?.isVisibleToUser == true && (!selected || control.isSelected)) return control
            Thread.sleep(50)
        } while (android.os.SystemClock.uptimeMillis() < deadline)
        return null
    }

    private fun findLabeledControl(node: AccessibilityNodeInfo?, text: String): AccessibilityNodeInfo? {
        if (node == null) return null
        if (node.text?.toString()?.contains(text) == true || node.contentDescription?.toString()?.contains(text) == true) {
            var target: AccessibilityNodeInfo? = node
            while (target != null) {
                if (target.isClickable || target.isSelected) return target
                target = target.parent
            }
        }
        for (index in 0 until node.childCount) {
            findLabeledControl(node.getChild(index), text)?.let { return it }
        }
        return null
    }

    private fun describe(node: AccessibilityNodeInfo?, depth: Int = 0): String {
        if (node == null || depth > 24) return ""
        return "  ".repeat(depth) + "${node.className} text=${node.text} description=${node.contentDescription} clickable=${node.isClickable} selected=${node.isSelected}\n" +
            (0 until node.childCount).joinToString("") { describe(node.getChild(it), depth + 1) }
    }

}
