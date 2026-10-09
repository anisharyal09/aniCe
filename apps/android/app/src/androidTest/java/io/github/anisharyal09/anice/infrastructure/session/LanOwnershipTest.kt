// SPDX-License-Identifier: GPL-3.0-or-later
// Injects native network callbacks to verify coroutine teardown retires the LAN owner.
package io.github.anisharyal09.anice.infrastructure.session

import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.NetworkCapabilities
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.lan.LanSessionController
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LanOwnershipTest {
    @Test fun lostNetworkRetiresOwnerAndIgnoresStaleCallbacks() = exercise("lost")

    @Test fun changedInterfaceRetiresOwnerAndIgnoresStaleCallbacks() = exercise("changed")

    @Test fun disconnectCancelsDiscoveryAndReleasesReservation() = exercise("disconnect")

    @Test fun anotherStartedPresentationKeepsLanUntilFinalStop() = exercise("background")

    private fun exercise(action: String): Unit = runBlocking {
        val app =
            InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
                as AniCeApplication
        val manager = app.getSystemService(ConnectivityManager::class.java)
        val network =
            requireNotNull(
                manager.allNetworks.firstOrNull {
                    manager
                        .getNetworkCapabilities(it)
                        ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                }
            ) {
                "Wi-Fi is required for the native owner regression"
            }
        val local =
            withContext(Dispatchers.IO) { app.identityService.getOrCreateIdentity().identity }
        val peer = local.copy(platform = "macos")
        val foreign =
            peer.copy(
                deviceId =
                    io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity.newId()
            )
        val controller = withContext(Dispatchers.Main) { LanSessionController(app) }
        val token = Any()
        fun field(name: String): Any? =
            LanSessionController::class
                .java
                .getDeclaredField(name)
                .apply { isAccessible = true }
                .get(controller)
        try {
            withContext(Dispatchers.Main) {
                controller.foreground(token)
                controller.connect(peer)
            }
            val callback =
                withTimeout(5000) {
                    withContext(Dispatchers.Main) {
                        while (field("watching") == null) delay(10)
                        field("watching") as ConnectivityManager.NetworkCallback
                    }
                }
            val worker = withContext(Dispatchers.Main) { field("worker") as Job }
            assertFalse(app.sessionPeers.permits(foreign))
            when (action) {
                "lost" -> callback.onLost(network)
                "changed" -> callback.onLinkPropertiesChanged(network, LinkProperties())
                "background" ->
                    withContext(Dispatchers.Main) {
                        val other = Any()
                        controller.foreground(other)
                        controller.background(token, false)
                        assertEquals(ConnectionState.CONNECTING, controller.state)
                        assertTrue(worker.isActive)
                        assertFalse(app.sessionPeers.permits(foreign))
                        controller.background(other, false)
                        assertTrue(controller.status.contains("foreground"))
                    }
                else -> withContext(Dispatchers.Main) { controller.disconnect() }
            }
            withTimeout(3000) { while (!app.sessionPeers.permits(foreign)) delay(10) }
            assertTrue(worker.isCancelled)
            withContext(Dispatchers.Main) {
                assertEquals(ConnectionState.DISCONNECTED, controller.state)
                assertNull(field("watching"))
                assertNull(field("worker"))
                controller.foreground(token)
                controller.connect(peer)
            }
            withTimeout(5000) { while (app.sessionPeers.permits(foreign)) delay(10) }
            callback.onLost(network)
            delay(100)
            withContext(Dispatchers.Main) {
                assertEquals(ConnectionState.CONNECTING, controller.state)
            }
            assertFalse(app.sessionPeers.permits(foreign))
        } finally {
            withContext(NonCancellable + Dispatchers.Main) {
                controller.cancel()
                controller.background(token, false)
            }
        }
    }
}
