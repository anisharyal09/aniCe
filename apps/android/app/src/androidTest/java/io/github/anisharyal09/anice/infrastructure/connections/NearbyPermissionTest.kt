// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises persisted discovery-permission decisions with disposable preferences and denied access, never changing OS grants.
package io.github.anisharyal09.anice.infrastructure.connections

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.os.Build
import androidx.lifecycle.ViewModelStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NearbyPermissionTest {
    private class PermissionApplication(base: Context) : Application() {
        init { attachBaseContext(base) }
    }

    @Test fun firstPromptIsPersistedAndDenialSurvivesAReplacementPresentation() {
        val runner = InstrumentationRegistry.getInstrumentation()
        val base = runner.targetContext.applicationContext
        assumeTrue(base.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE))
        val preferences = "nearby-permission-test.${UUID.randomUUID()}"
        val denied = object : ContextWrapper(base) {
            override fun getSharedPreferences(name: String, mode: Int) = base.getSharedPreferences(preferences, mode)
            override fun checkPermission(permission: String, pid: Int, uid: Int) = PackageManager.PERMISSION_DENIED
            override fun getSystemService(name: String): Any? =
                if (name == Context.KEYGUARD_SERVICE) null else super.getSystemService(name)
        }
        val store = ViewModelStore()
        runner.runOnMainSync {
            try {
                val app = PermissionApplication(denied)
                val model = NearbyDiscoveryViewModel(app)
                store.put("first", model)
                model.foreground(true)
                model.eligible(true)
                val missing = model.initialPermissionRequest(previouslyDenied = false)
                assertEquals(if (Build.VERSION.SDK_INT >= 31)
                    setOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
                    else setOf(Manifest.permission.ACCESS_FINE_LOCATION), missing.toSet())
                assertTrue(model.permissionRequired)
                assertFalse(model.scanning)
                assertTrue(model.initialPermissionRequest(previouslyDenied = false).isEmpty())
                model.permissionsReturned(permanent = true)
                assertTrue(model.permissionNeedsSettings)
                model.foreground(false)
                model.foreground(true)
                assertTrue(model.initialPermissionRequest(previouslyDenied = false).isEmpty())
                val replacement = NearbyDiscoveryViewModel(app)
                store.put("second", replacement)
                replacement.foreground(true)
                replacement.eligible(true)
                assertTrue(replacement.permissionNeedsSettings)
                assertTrue(replacement.initialPermissionRequest(previouslyDenied = false).isEmpty())
                assertFalse(replacement.scanning)
            } finally {
                store.clear()
                base.deleteSharedPreferences(preferences)
            }
        }
    }
}
