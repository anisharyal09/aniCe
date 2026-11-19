// SPDX-License-Identifier: GPL-3.0-or-later
// Checks automatic-setup routing uses the installed application ID without changing the compiled activity namespace.
package io.github.anisharyal09.anice.features.backgroundprobe

import android.content.ContextWrapper
import android.view.ContextThemeWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CompanionSetupIntentTest {
    @Test fun namespaceIsStableAcrossNormalAndPreviewApplicationIds() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val applications = listOf("io.github.anisharyal09.anice", "io.github.anisharyal09.anice.preview",
            "io.github.anisharyal09.anice.preview.transfer")
        assertEquals(3, applications.size)
        for (application in applications) {
            val scoped = object : ContextWrapper(context) {
                override fun getPackageName() = application
            }
            for (enable in listOf(false, true)) {
                val intent = companionSetupIntent(scoped, "selected-peer", enable)
                assertEquals(application, intent.component?.packageName)
                assertEquals(CompanionProbeActivity::class.java.name, intent.component?.className)
                assertEquals("selected-peer", intent.getStringExtra("peer"))
                assertEquals(enable, intent.getBooleanExtra("enable", !enable))
            }
            assertEquals(application, quickCompanionSetupIntent(scoped, "selected-peer").component?.packageName)
            assertEquals(CompanionQuickSetupActivity::class.java.name,
                quickCompanionSetupIntent(scoped, "selected-peer").component?.className)
        }
    }

    @Test fun automaticSetupResolvesInsideTheInstalledApplication() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val resolved = context.packageManager.resolveActivity(companionSetupIntent(context, "selected-peer"), 0)
        assertNotNull("Automatic setup must resolve in normal and isolated preview builds", resolved)
        assertEquals(context.packageName, resolved?.activityInfo?.packageName)
        assertEquals(CompanionProbeActivity::class.java.name, resolved?.activityInfo?.name)
    }
    @Test fun quickSetupIsExplicitWithoutSendingALocatorInTheIntent() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val intent = quickCompanionSetupIntent(context, "selected-peer")
        assertEquals(context.packageName, intent.component?.packageName)
        assertEquals(CompanionQuickSetupActivity::class.java.name, intent.component?.className)
        assertEquals("selected-peer", intent.getStringExtra("peer"))
        assertFalse("The native component owns its presentation, not a redundant flag", intent.hasExtra("quick"))
        assertTrue(intent.getBooleanExtra("enable", false))
        assertFalse(intent.hasExtra("address"))
        assertFalse(intent.hasExtra("channel"))
        val resolved = requireNotNull(context.packageManager.resolveActivity(intent, 0))
        assertEquals(CompanionQuickSetupActivity::class.java.name, resolved.activityInfo.name)
        val attributes = ContextThemeWrapper(context, resolved.activityInfo.theme).obtainStyledAttributes(
            intArrayOf(android.R.attr.windowIsFloating, android.R.attr.windowDisablePreview))
        try {
            assertTrue("Quick setup must be floating before Android launches it", attributes.getBoolean(0, false))
            assertTrue("Quick setup must not flash a starting window", attributes.getBoolean(1, false))
        } finally { attributes.recycle() }
    }
}
