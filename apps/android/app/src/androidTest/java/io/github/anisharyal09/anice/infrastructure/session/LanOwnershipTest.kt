// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies LAN presentation handoff, native network teardown and transfer-service ownership.
package io.github.anisharyal09.anice.infrastructure.session

import io.github.anisharyal09.anice.infrastructure.connections.ConnectionState
import androidx.lifecycle.ViewModelStore
import io.github.anisharyal09.anice.features.discovery.DiscoveryViewModel
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.NetworkCapabilities
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.features.session.SessionViewModel
import io.github.anisharyal09.anice.infrastructure.connections.LanSessionController
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LanOwnershipTest {
    @Test fun restoredAddressesRequestOneAttemptAndRespectBackgroundAndDisconnect() = runBlocking {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AniCeApplication
        val controller = withContext(Dispatchers.Main) { LanSessionController(app) }
        val manager = app.getSystemService(ConnectivityManager::class.java)
        val wifi = requireNotNull(manager.allNetworks.firstOrNull {
            manager.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        })
        val network = android.net.Network.fromNetworkHandle(wifi.networkHandle + (199999L shl 32))
        val sent = mutableListOf<Int?>()
        val channel = object : io.github.anisharyal09.anice.infrastructure.connections.SecuredChannel {
            override val descriptor = io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor(
                "address-restoration-test", "ble",
                io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity(
                    "00000000-0000-4000-8000-000000000001", "Test Mac", "macos", "mock-key", "mock-fingerprint"))
            override suspend fun sendData(bytes: ByteArray) { sent.add(io.github.anisharyal09.anice.infrastructure.connections.LanRendezvousWire.decode(bytes)) }
        }
        fun addresses(vararg values: String) = values.map { java.net.InetAddress.getByName(it) }.toSet()
        suspend fun changed(values: Set<java.net.InetAddress>) = withContext(Dispatchers.Main) {
            controller.wifiAddressesChanged(network, values)
        }
        fun requests() = sent.count { it == 4 }
        try {
            withContext(Dispatchers.Main) {
                org.junit.Assume.assumeTrue("Automatic LAN must be enabled", controller.automatic)
                controller.rendezvous.available(channel)
                controller.rendezvous.handle(channel.descriptor,
                    io.github.anisharyal09.anice.infrastructure.connections.LanRendezvousWire.encode(1))
                controller.updateWorkLease(approved = true, picking = false)
            }
            delay(100)
            val callback = controller.javaClass.getDeclaredField("automaticNetworkCallback").apply { isAccessible = true }
                .get(controller) as ConnectivityManager.NetworkCallback
            val both = addresses("192.0.2.10", "fe80::1")
            val ipv6Only = addresses("fe80::1")
            var before = withContext(Dispatchers.Main) { requests() }
            callback.onAvailable(network)
            changed(addresses("0.0.0.0"))
            delay(100)
            withContext(Dispatchers.Main) { assertEquals("No usable address means no demand", before, requests()) }
            changed(both)
            delay(100)
            withContext(Dispatchers.Main) { assertEquals(before + 1, requests()) }
            before++
            changed(ipv6Only)
            delay(50)
            repeat(20) { changed(both) }
            delay(100)
            withContext(Dispatchers.Main) {
                assertEquals("Restoring IPv4 on the same Network must request only once", before + 1, requests())
                assertEquals(ConnectionState.DISCONNECTED, controller.state)
                controller.updateWorkLease(approved = false, picking = false)
            }
            delay(100)
            before = withContext(Dispatchers.Main) { requests() }
            changed(ipv6Only)
            changed(both)
            delay(100)
            withContext(Dispatchers.Main) {
                assertEquals("Unleased background discovery stays disabled", before, requests())
                controller.updateWorkLease(approved = true, picking = false)
            }
            delay(100)
            before = withContext(Dispatchers.Main) { requests() }
            changed(ipv6Only)
            changed(both)
            delay(100)
            withContext(Dispatchers.Main) { assertEquals("Approved background work permits restoration", before + 1, requests()) }
            withContext(Dispatchers.Main) { controller.cancel() }
            delay(50)
            before = withContext(Dispatchers.Main) { requests() }
            changed(ipv6Only)
            changed(both)
            callback.onLost(network)
            callback.onLost(network)
            delay(100)
            withContext(Dispatchers.Main) {
                assertEquals("Restoration cannot override explicit Disconnect", before, requests())
                assertFalse(controller.requestAutomaticConnection())
            }
        } finally {
            withContext(NonCancellable + Dispatchers.Main) { controller.dispose() }
        }
    }

    @Test fun lostNetworkRetiresOwnerAndIgnoresStaleCallbacks() = exercise("lost")

    @Test fun changedInterfaceRetiresOwnerAndIgnoresStaleCallbacks() = exercise("changed")

    @Test fun disconnectCancelsDiscoveryAndReleasesReservation() = exercise("disconnect")

    @Test fun anotherStartedPresentationKeepsLanUntilFinalStop() = exercise("background")
    @Test fun approvedWorkSurvivesBackgroundUntilItsLeaseEnds() = exercise("work")
    @Test fun pickerSurvivesBackgroundUntilItsLeaseEnds() = exercise("picker")
    @Test fun serviceLossRetiresBackgroundWork() = exercise("service")
    @Test fun securityInvalidationRetiresLanOwner() = exercise("security")

    @Test fun discoveryOpeningIsIdleAndScanPreservesLanUntilDeviceCancellation() = exercise("discovery")

    @Test fun notificationDenialDoesNotPreventApprovedTransferService() = runBlocking {
        val runner = InstrumentationRegistry.getInstrumentation()
        val app = runner.targetContext.applicationContext as AniCeApplication
        org.junit.Assume.assumeFalse("Visible service start requires an unlocked phone",
            app.getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked)
        org.junit.Assume.assumeFalse("Exercise with notifications denied",
            androidx.core.app.NotificationManagerCompat.from(app).areNotificationsEnabled())
        val source = java.io.File(app.cacheDir, "service-test-" + java.util.UUID.randomUUID() + ".bin")
        var activity: android.app.Activity? = null
        var descriptor: io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor? = null
        val service = android.content.ComponentName(app,
            io.github.anisharyal09.anice.features.transfer.TransferService::class.java)
        @Suppress("DEPRECATION")
        fun runningService() = app.getSystemService(android.app.ActivityManager::class.java)
            .getRunningServices(100).firstOrNull { it.service == service }
        try {
            activity = runner.startActivitySync(android.content.Intent(app,
                io.github.anisharyal09.anice.MainActivity::class.java).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
            withContext(Dispatchers.Main) {
                org.junit.Assume.assumeFalse("Do not replace live LAN or transfer work",
                    app.transfer.isBusy || app.lanSessionController.state != ConnectionState.DISCONNECTED)
                val peer = app.transfer.activeChannel?.descriptor?.peer ?: app.sessionController.selected ?: io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity(
                    "00000000-0000-4000-8000-000000000001", "Test Mac", "macos", "mock-key",
                    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
                val channel = object : io.github.anisharyal09.anice.infrastructure.connections.SecuredChannel {
                    override val descriptor = io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor(
                        "service-test-" + java.util.UUID.randomUUID(), "lan", peer)
                    override suspend fun sendData(bytes: ByteArray) = Unit
                }
                descriptor = channel.descriptor
                app.transfer.available(channel)
                app.transfer.handle(channel.descriptor,
                    io.github.anisharyal09.anice.features.transfer.TransferMessage.capability().encode())
                source.writeBytes(ByteArray(65536))
                app.transfer.sendFiles(listOf(source))
                assertTrue(app.transfer.backgroundAllowed)
            }
            withTimeout(10000) { while (runningService()?.foreground != true) delay(20) }
            withContext(Dispatchers.Main) { activity!!.moveTaskToBack(true) }
            withTimeout(5000) { while (withContext(Dispatchers.Main) { app.lanSessionController.foreground }) delay(20) }
            delay(200)
            withContext(Dispatchers.Main) {
                assertTrue(app.transfer.isBusy)
                assertTrue(app.transfer.backgroundAllowed)
                assertEquals(descriptor, app.transfer.activeChannel?.descriptor)
                assertEquals(true, runningService()?.foreground)
                app.transfer.cancelTransfer(local = false)
            }
            withTimeout(5000) { while (runningService() != null) delay(20) }
            assertFalse(androidx.core.app.NotificationManagerCompat.from(app).areNotificationsEnabled())
        } finally {
            withContext(NonCancellable + Dispatchers.Main) {
                if (descriptor != null) {
                    app.transfer.cancelTransfer(local = false)
                    app.transfer.retired(descriptor!!)
                    app.transfer.dismiss()
                }
                activity?.finish()
            }
            source.delete()
        }
    }

    @Test fun approvedBleLeaseSurvivesScreenOffAndCompanionRelease() = exerciseBlePolicy(picking = false)
    @Test fun blePickerLeaseSurvivesScreenOffAndCompanionRelease() = exerciseBlePolicy(picking = true)
    @Test fun securityInvalidationRetiresBleOwner() = exerciseBlePolicy(picking = false, invalidate = true)

    private fun exerciseBlePolicy(picking: Boolean, invalidate: Boolean = false) = runBlocking {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AniCeApplication
        val policy = withContext(Dispatchers.Main) {
            io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe.get(app)
        }
        val controller = app.sessionController
        val presentation = Any()
        val companion = Any()
        try {
            withContext(Dispatchers.Main) {
                policy.suspend()
                controller.cancel()
                controller.foreground(presentation)
                @Suppress("UNCHECKED_CAST")
                val state = controller.javaClass.getDeclaredField("state\$delegate")
                    .apply { isAccessible = true }.get(controller) as androidx.compose.runtime.MutableState<ConnectionState>
                state.value = ConnectionState.SECURED
                controller.updateWorkLease(!picking, picking)
                controller.acquireCompanion(companion)
                controller.background(presentation, false)
                controller.releaseCompanion(companion)
                val radio = controller.javaClass.getDeclaredField("radio").apply { isAccessible = true }
                    .get(controller) as android.content.BroadcastReceiver
                radio.onReceive(app, android.content.Intent(android.content.Intent.ACTION_SCREEN_OFF))
                assertEquals(ConnectionState.SECURED, controller.state)
                if (invalidate) controller.securityInvalidated() else controller.updateWorkLease(false, false)
            }
            withTimeout(3000) {
                while (withContext(Dispatchers.Main) { controller.state != ConnectionState.DISCONNECTED }) delay(10)
            }
        } finally {
            withContext(NonCancellable + Dispatchers.Main) {
                controller.releaseCompanion(companion)
                controller.cancel()
                controller.background(presentation, false)
                policy.resumeAfterOperation()
            }
        }
    }

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
        val peer = withContext(Dispatchers.Main) { app.sessionController.selected }
            ?: local.copy(platform = "macos")
        val foreign =
            peer.copy(
                deviceId =
                    io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity.newId()
            )
        val controller = withContext(Dispatchers.Main) {
            if (action == "discovery") app.lanSessionController else LanSessionController(app, backgroundTimeoutMillis = { 50L })
        }
        val token = Any()
        val policy = withContext(Dispatchers.Main) {
            io.github.anisharyal09.anice.infrastructure.connections.CompanionProbe.get(app)
        }
        val previousSelection = withContext(Dispatchers.Main) { controller.selected }
        fun field(name: String): Any? =
            LanSessionController::class
                .java
                .getDeclaredField(name)
                .apply { isAccessible = true }
                .get(controller)
        try {
            withContext(Dispatchers.Main) {
                policy.suspend()
                app.sessionController.cancel()
                controller.foreground(token)
                controller.connect(peer)
                assertEquals(controller.status, ConnectionState.CONNECTING, controller.state)
            }
            val callback =
                withTimeout(5000) {
                    withContext(Dispatchers.Main) {
                        while (field("watching") == null && controller.state == ConnectionState.CONNECTING) delay(10)
                        assertNotNull(controller.status, field("watching"))
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
                        controller.foreground(token)
                        controller.background(other, false)
                        controller.background(other, false) // A late settings stop cannot release Home.
                        assertEquals(ConnectionState.CONNECTING, controller.state)
                        assertTrue(worker.isActive)
                        assertFalse(app.sessionPeers.permits(foreign))
                        controller.background(token, false)
                        assertNotNull(field("backgroundTimeoutJob"))
                    }
                "work", "picker", "service" -> {
                    withContext(Dispatchers.Main) {
                        controller.updateWorkLease(action != "picker", action == "picker")
                        controller.background(token, false)
                    }
                    delay(100)
                    withContext(Dispatchers.Main) {
                        assertEquals(ConnectionState.CONNECTING, controller.state)
                        assertTrue(worker.isActive)
                        assertNotNull(field("watching"))
                        if (action == "service") controller.onWorkServiceStopped()
                        else {
                            controller.updateWorkLease(false, false)
                            controller.onWorkIdle()
                        }
                    }
                }
                "discovery" -> withContext(Dispatchers.Main) {
                    val model = SessionViewModel(app)
                    val discovery = DiscoveryViewModel(app)
                    val models = ViewModelStore().apply { put("discovery", discovery) }
                    var starts = 0
                    val busy = mutableListOf<Boolean>()
                    discovery.beforeStart = { starts++; model.cancelBluetooth() }
                    discovery.onBusyChanged = { busy.add(it) }
                    try {
                        discovery.start() // A stopped presentation cannot acquire radio work.
                        discovery.foreground()
                        assertEquals(0, starts)
                        assertTrue(busy.isEmpty())
                        assertEquals(ConnectionState.CONNECTING, controller.state)
                        assertTrue(worker.isActive)
                        discovery.start()
                        discovery.cancel()
                        assertEquals(1, starts)
                        assertEquals(listOf(true, false), busy)
                        discovery.cancel()
                        assertEquals(listOf(true, false), busy)
                        assertEquals(ConnectionState.CONNECTING, controller.state)
                        assertTrue(worker.isActive)
                        assertFalse(app.sessionPeers.permits(foreign))
                    } finally { models.clear() }
                    model.cancel()
                }
                "security" -> withContext(Dispatchers.Main) { controller.securityInvalidated() }
                "disconnect" -> withContext(Dispatchers.Main) { controller.disconnect() }
                else -> error("Unknown native owner case: $action")
            }
            withTimeout(3000) {
                while (withContext(Dispatchers.Main) { controller.state != ConnectionState.DISCONNECTED }) delay(10)
            }
            assertTrue(worker.isCancelled)
            withContext(Dispatchers.Main) {
                assertEquals(ConnectionState.DISCONNECTED, controller.state)
                assertNull(field("watching"))
                assertNull(field("worker"))
                val bindings = SessionPeerReservation::class.java.getDeclaredField("owners")
                    .apply { isAccessible = true }.get(app.sessionPeers) as Map<*, *>
                assertFalse("LAN must release only its own reservation", bindings.containsKey(controller))
                policy.suspend()
                app.sessionController.cancel()
                controller.foreground(token)
                controller.connect(peer)
            }
            withTimeout(5000) { while (app.sessionPeers.permits(foreign)) delay(10) }
            callback.onLost(network)
            delay(100)
            withContext(Dispatchers.Main) {
                assertTrue(controller.state == ConnectionState.CONNECTING || controller.state == ConnectionState.SECURED)
            }
            assertFalse(app.sessionPeers.permits(foreign))
        } finally {
            withContext(NonCancellable + Dispatchers.Main) {
                if (controller === app.lanSessionController) {
                    controller.cancel()
                    controller.foreground(token)
                    @Suppress("UNCHECKED_CAST")
                    val selection = field("selected\$delegate") as androidx.compose.runtime.MutableState<io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity?>
                    selection.value = previousSelection
                    controller.background(token, false)
                } else controller.dispose()
                policy.resumeAfterOperation()
            }
        }
    }
}
