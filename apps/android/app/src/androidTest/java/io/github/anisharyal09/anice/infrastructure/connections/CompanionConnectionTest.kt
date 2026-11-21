// SPDX-License-Identifier: GPL-3.0-or-later
// Tests authenticated setup's connection handoff and cancellation without native scanning or stored state changes.
package io.github.anisharyal09.anice.infrastructure.connections

import android.content.BroadcastReceiver
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import androidx.compose.runtime.MutableState
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CompanionConnectionTest {
    private class Fixture {
        val peer = DeviceIdentity("fixture", "Verified Mac", "macos", "key", "fingerprint")
        val app = AniCeApplication()
        val controller: SessionController
        val presentation = Any()
        init {
            val base = InstrumentationRegistry.getInstrumentation().targetContext
            val context = object : ContextWrapper(base) {
                override fun getApplicationContext(): Context = app
                override fun checkPermission(permission: String, pid: Int, uid: Int) = PackageManager.PERMISSION_GRANTED
                override fun getSystemService(name: String): Any? =
                    if (name == Context.KEYGUARD_SERVICE) null else super.getSystemService(name)
            }
            ContextWrapper::class.java.getDeclaredMethod("attachBaseContext", Context::class.java)
                .apply { isAccessible = true }.invoke(app, context)
            controller = SessionController(app)
            controller.foreground(presentation)
            state<DeviceIdentity?>(controller, "selected").value = peer
        }
        @Suppress("UNCHECKED_CAST")
        fun <T> state(model: Any, name: String) = model.javaClass.getDeclaredField("$name\$delegate")
            .apply { isAccessible = true }.get(model) as MutableState<T>
        fun close() {
            val type = SessionController::class.java
            val scope = type.getDeclaredField("scope").apply { isAccessible = true }.get(controller) as CoroutineScope
            scope.cancel()
            val receiver = type.getDeclaredField("radio").apply { isAccessible = true }.get(controller) as BroadcastReceiver
            app.unregisterReceiver(receiver)
        }
    }

    @Test fun securedSetupReusesTheSameConnectionAndRejectsAnotherCredential() = runBlocking {
        withContext(Dispatchers.Main) {
            val fixture = Fixture()
            try {
                fixture.state<ConnectionState>(fixture.controller, "state").value = ConnectionState.SECURED
                val progress = fixture.controller.progress.value
                fixture.controller.connectForCompanionSetup(fixture.peer.copy(deviceName = "Renamed Mac"))
                assertSame(progress, fixture.controller.progress.value)
                for (changed in listOf(fixture.peer.copy(deviceId = "other"),
                    fixture.peer.copy(fingerprint = "other"), fixture.peer.copy(publicKey = "other"))) {
                    try { fixture.controller.connectForCompanionSetup(changed); fail("Another credential was accepted") }
                    catch (_: IllegalStateException) {}
                }
                assertEquals(ConnectionState.SECURED, fixture.controller.state)
                assertEquals(fixture.peer, fixture.controller.selected)
            } finally { fixture.close() }
        }
    }

    @Test fun replacingAnInFlightConnectionCannotCompleteAnOlderSetupWait() = runBlocking {
        withContext(Dispatchers.Main) {
            val fixture = Fixture()
            try {
                fixture.state<ConnectionState>(fixture.controller, "state").value = ConnectionState.CONNECTING
                val pending = async(start = CoroutineStart.UNDISPATCHED) {
                    runCatching { fixture.controller.connectForCompanionSetup(fixture.peer) }
                }
                assertFalse(pending.isCompleted)
                SessionController::class.java.getDeclaredField("operation").apply { isAccessible = true }
                    .setLong(fixture.controller, 1)
                fixture.controller.progress.value = SessionController.Progress(ConnectionState.CONNECTING, null, null, 0, 1)
                val result = withTimeout(1000) { pending.await() }
                assertTrue(result.exceptionOrNull() is IllegalStateException)
                assertEquals(ConnectionState.CONNECTING, fixture.controller.state)
            } finally { fixture.close() }
        }
    }

    @Test fun cancellingSetupDoesNotRetireAPreexistingConnectionAttempt() = runBlocking {
        withContext(Dispatchers.Main) {
            val fixture = Fixture()
            try {
                fixture.state<ConnectionState>(fixture.controller, "state").value = ConnectionState.CONNECTING
                val pending = launch(start = CoroutineStart.UNDISPATCHED) {
                    fixture.controller.connectForCompanionSetup(fixture.peer)
                }
                assertTrue(pending.isActive)
                pending.cancelAndJoin()
                assertEquals(ConnectionState.CONNECTING, fixture.controller.state)
            } finally { fixture.close() }
        }
    }

    @Test fun setupWaitsForExistingBoundedRecoveryInsteadOfStartingASecondScan() = runBlocking {
        withContext(Dispatchers.Main) {
            val fixture = Fixture()
            val release = CompletableDeferred<Unit>()
            try {
                fixture.state<ConnectionState>(fixture.controller, "state").value = ConnectionState.CONNECTING
                val recovery = launch(start = CoroutineStart.UNDISPATCHED) {
                    release.await()
                    fixture.state<ConnectionState>(fixture.controller, "state").value = ConnectionState.SECURED
                }
                SessionController::class.java.getDeclaredField("foregroundRecovery")
                    .apply { isAccessible = true }.set(fixture.controller, recovery)
                val progress = fixture.controller.progress.value
                val pending = async(start = CoroutineStart.UNDISPATCHED) {
                    fixture.controller.connectForCompanionSetup(fixture.peer)
                }
                assertFalse(pending.isCompleted)
                release.complete(Unit)
                withTimeout(1000) { pending.await() }
                assertSame("No second connection request was published", progress, fixture.controller.progress.value)
            } finally { release.complete(Unit); fixture.close() }
        }
    }
}
