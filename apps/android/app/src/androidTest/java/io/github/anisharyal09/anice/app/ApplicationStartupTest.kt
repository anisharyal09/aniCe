// SPDX-License-Identifier: GPL-3.0-or-later
// Rejects context-dependent feature initialization before Android attaches the Application base context.
package io.github.anisharyal09.anice.app

import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import org.junit.Assert.*
import org.junit.Test

class ApplicationStartupTest {
    @Test fun constructionBeforeContextAttachmentDoesNotAccessSystemServices() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val unattached = AniCeApplication()
            assertNull(unattached.baseContext)
            val running = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AniCeApplication
            assertSame(running.features, running.features)
            assertSame(running.findDevice, running.findDevice)
            assertNotNull(running.findDeviceNotification)
        }
    }
}
