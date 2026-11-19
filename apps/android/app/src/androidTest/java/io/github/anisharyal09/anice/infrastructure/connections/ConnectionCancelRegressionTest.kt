// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises the real connection policy with disposable preferences and held jobs, never a native association or radio attempt.
package io.github.anisharyal09.anice.infrastructure.connections

import android.content.BroadcastReceiver
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import java.util.UUID
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ConnectionCancelRegressionTest {
    // Native policy/owner methods run on Main; hold their asynchronous work before it can access the radio.
    private class HeldDispatcher : CoroutineDispatcher() {
        private val tasks = ArrayDeque<Runnable>()
        override fun dispatch(context: CoroutineContext, block: Runnable) { tasks.addLast(block) }
        fun drain() {
            var count = 0
            while (tasks.isNotEmpty()) {
                check(count++ < 100) { "Unexpected unbounded policy work" }
                tasks.removeFirst().run()
            }
        }
    }

    private class Fixture(val app: AniCeApplication, armed: Boolean) {
        val controller = app.sessionController
        val name = "connection-cancel-regression.${UUID.randomUUID()}"
        val preferences = app.getSharedPreferences(name, Context.MODE_PRIVATE)
        val dispatcher = HeldDispatcher()
        val scope = CoroutineScope(SupervisorJob() + dispatcher)
        val peer = DeviceIdentity("cancel-fixture", "Isolated Mac", "macos", "fixture-key", "fixture-fingerprint")
        val presentation = Any()
        val nativeOwner = Any()
        private val beforeDisconnect = controller.beforeDisconnect
        private val beforeRequest = controller.beforeRequest
        private val beforeCancel = controller.beforeCancelAttempt
        private val radioChanged = controller.radioChanged
        private val foregroundChanged = controller.foregroundChanged
        private val recoveryReserved = controller.automaticRecoveryReserved
        val policy: CompanionProbe

        init {
            check(preferences.edit().putBoolean("automatic", true).putBoolean("armed", armed)
                .putBoolean("paused", !armed).putString("peer", peer.deviceId)
                .putString("fingerprint", peer.fingerprint).putString("address", "02:00:00:00:00:01")
                .putInt("association", Int.MAX_VALUE).commit())
            val constructor = CompanionProbe::class.java.getDeclaredConstructor(
                AniCeApplication::class.java, SharedPreferences::class.java, CoroutineScope::class.java)
                .apply { isAccessible = true }
            policy = constructor.newInstance(app, preferences, scope)
        }

        fun field(name: String): Any? = CompanionProbe::class.java.getDeclaredField(name)
            .apply { isAccessible = true }.get(policy)

        /** The `events` diagnostic log legitimately grows on presence callbacks; policy keys must not move. */
        fun assertPolicyUnchanged(saved: Map<String, *>) {
            assertEquals(saved - "events", preferences.all - "events")
        }

        fun close() {
            scope.cancel()
            dispatcher.drain()
            app.unregisterReceiver(field("pauseEvents") as BroadcastReceiver)
            controller.background(presentation)
            controller.releaseCompanion(nativeOwner)
            controller.beforeDisconnect = beforeDisconnect
            controller.beforeRequest = beforeRequest
            controller.beforeCancelAttempt = beforeCancel
            controller.radioChanged = radioChanged
            controller.foregroundChanged = foregroundChanged
            controller.automaticRecoveryReserved = recoveryReserved
            app.deleteSharedPreferences(name)
        }
    }

    private suspend fun fixture(armed: Boolean = false): Fixture = withContext(Dispatchers.Main) {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as AniCeApplication
        assumeTrue("Run only against an isolated preview package",
            app.packageName in setOf("io.github.anisharyal09.anice.preview", "io.github.anisharyal09.anice.preview.transfer",
                "io.github.anisharyal09.anice.preview.transfer.regression"))
        assumeTrue("Requires native companion support", Build.VERSION.SDK_INT >= 31 &&
            app.resources.getBoolean(R.bool.companion_probe_supported) &&
            app.packageManager.hasSystemFeature(PackageManager.FEATURE_COMPANION_DEVICE_SETUP))
        val controller = app.sessionController
        // Instrumentation replaces the preview process, never the production installation.
        controller.cancel()
        Fixture(app, armed)
    }

    @Test fun cancelFencesASuspendedResumeEvenIfLookupIgnoresCancellation() = runBlocking {
        val fixture = fixture()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val resumeScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        val pending = resumeScope.async {
            fixture.policy.resume {
                entered.complete(Unit)
                withContext(NonCancellable) { release.await() }
                fixture.peer
            }
        }
        try {
            withTimeout(2000) { entered.await() }
            withContext(Dispatchers.Main) {
                fixture.controller.cancelAttempt()
                assertTrue(fixture.policy.automaticEnabled)
                assertFalse(fixture.policy.waiting)
            }
            release.complete(Unit)
            withTimeout(2000) { pending.join() }
            try { pending.await(); fail("Cancelled Resume reached arming") }
            catch (_: CancellationException) { assertTrue(pending.isCancelled) }
            withContext(Dispatchers.Main) {
                assertFalse(fixture.policy.armed)
                assertTrue(fixture.preferences.getBoolean("paused", false))
                assertNull(fixture.field("monitor"))
                assertEquals("02:00:00:00:00:01", fixture.policy.address)
            }
        } finally {
            release.complete(Unit)
            resumeScope.cancel()
            withContext(NonCancellable + Dispatchers.Main) { fixture.close() }
        }
    }

    @Test fun repeatedConnectCoalescesAndCancelRetiresAQueuedResumeWithoutChangingPreferences() = runBlocking {
        val fixture = fixture()
        try {
            withContext(Dispatchers.Main) {
                assumeTrue("Preview needs its own Bluetooth permissions", fixture.controller.missingPermissions().isEmpty())
                val saved = fixture.preferences.all
                fixture.controller.beforeRequest(fixture.peer)
                val pending = fixture.field("connectResume") as Job
                repeat(10) { fixture.controller.beforeRequest(fixture.peer) }
                assertSame(pending, fixture.field("connectResume"))
                fixture.controller.cancelAttempt()
                assertTrue(pending.isCancelled)
                assertNull(fixture.field("connectResume"))
                fixture.dispatcher.drain()
                fixture.assertPolicyUnchanged(saved)
                assertFalse(fixture.policy.armed)
                fixture.controller.beforeRequest(fixture.peer)
                assertNotSame(pending, fixture.field("connectResume"))
                assertTrue((fixture.field("connectResume") as Job).isActive)
            }
        } finally { withContext(NonCancellable + Dispatchers.Main) { fixture.close() } }
    }

    @Test fun newerSetupSupersedesAQueuedConnectResumeBeforeItCanOverwritePolicy() = runBlocking {
        val fixture = fixture()
        try {
            withContext(Dispatchers.Main) {
                assumeTrue("Preview needs its own Bluetooth permissions", fixture.controller.missingPermissions().isEmpty())
                fixture.controller.beforeRequest(fixture.peer)
                val pending = fixture.field("connectResume") as Job
                fixture.policy.beginSetup()
                val saved = fixture.preferences.all
                fixture.dispatcher.drain()
                assertTrue(pending.isCompleted)
                assertNull(fixture.field("connectResume"))
                fixture.assertPolicyUnchanged(saved)
                assertFalse(fixture.policy.armed)
            }
        } finally { withContext(NonCancellable + Dispatchers.Main) { fixture.close() } }
    }

    @Test fun cancelledChooserCannotInvalidateItsReplacementOrReachArming() = runBlocking {
        val fixture = fixture()
        try {
            withContext(Dispatchers.Main) {
                val first = fixture.policy.beginSetup()
                val next = fixture.policy.beginSetup()
                fixture.policy.cancelSetup(first)
                assertEquals(next, fixture.field("setupGeneration"))
                fixture.policy.cancelSetup(next)
                val saved = fixture.preferences.all
                runBlocking {
                    try {
                        fixture.policy.arm(fixture.peer, "02:00:00:00:00:01", -1, next)
                        fail("A cancelled chooser reached trust reads or native observation")
                    } catch (error: IllegalStateException) { assertEquals("Setup was cancelled.", error.message) }
                }
                fixture.assertPolicyUnchanged(saved)
                assertFalse(fixture.policy.armed)
            }
        } finally { withContext(NonCancellable + Dispatchers.Main) { fixture.close() } }
    }

    @Test fun foregroundReturnRestartsRetainedOwnerButDuplicatePresenceCannotUndoCancel() = runBlocking {
        val fixture = fixture(armed = true)
        try {
            withContext(Dispatchers.Main) {
                val saved = fixture.preferences.all
                fixture.policy.appeared(fixture.nativeOwner)
                fixture.controller.acquireCompanion(fixture.nativeOwner)
                val original = fixture.field("monitor") as Job
                fixture.controller.cancelAttempt()
                assertTrue(original.isCancelled)
                repeat(10) { fixture.policy.appeared(fixture.nativeOwner) }
                assertNull(fixture.field("monitor"))
                assertFalse(fixture.policy.waiting)
                assertTrue(fixture.controller.hasCompanionOwner)
                fixture.controller.foreground(fixture.presentation)
                val replacement = fixture.field("monitor") as Job
                assertTrue(replacement.isActive)
                assertNotSame(original, replacement)
                assertTrue(fixture.policy.waiting)
                repeat(10) {
                    fixture.controller.foreground(fixture.presentation)
                    fixture.policy.appeared(fixture.nativeOwner)
                }
                assertSame(replacement, fixture.field("monitor"))
                fixture.assertPolicyUnchanged(saved)
            }
        } finally { withContext(NonCancellable + Dispatchers.Main) { fixture.close() } }
    }
}
