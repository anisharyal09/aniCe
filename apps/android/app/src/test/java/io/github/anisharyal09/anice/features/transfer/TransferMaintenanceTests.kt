// SPDX-License-Identifier: GPL-3.0-or-later
// Checks bounded channel maintenance cannot expire transport waits, retain cancelled waiters or revive a retired channel.
package io.github.anisharyal09.anice.features.transfer

import io.github.anisharyal09.anice.infrastructure.connections.*
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.atomic.AtomicLong

class TransferMaintenanceTests {
    private class Channel(clock: () -> Long) : SecuredChannel {
        override val descriptor = ChannelDescriptor("test", "lan", DeviceIdentity("peer", "Fixture", "macos", "key", "fingerprint"))
        override val maintenance = ChannelMaintenance(clock)
        override suspend fun sendData(bytes: ByteArray) {}
    }

    @Test fun renewalBeyondTheOrdinaryWaitBudgetPreservesNullableResults() = runBlocking {
        val clock = AtomicLong()
        val channel = Channel(clock::get)
        val result = CompletableDeferred<String?>()
        channel.maintenance.update(SessionMaintenanceSnapshot(0, 0, 1))
        val wait = async { awaitTransferResult(channel, 10) { result.await() } }
        yield()
        clock.set(100)
        delay(25)
        assertFalse("Maintenance consumed the ordinary wait budget", wait.isCompleted)
        channel.maintenance.update(SessionMaintenanceSnapshot(elapsedMillis = 100, revision = 2))
        result.complete(null)
        assertNull(withTimeout(1000) { wait.await() })
    }

    @Test fun completedAndStaleSnapshotsDoNotLoseOrReopenAPause() = runBlocking {
        val channel = Channel { 100 }
        channel.maintenance.update(SessionMaintenanceSnapshot(elapsedMillis = 100, revision = 2))
        channel.maintenance.update(SessionMaintenanceSnapshot(0, 0, 1))
        assertFalse(channel.maintenance.active)
        assertEquals(100L, channel.maintenance.elapsedMillis)
        withTimeout(1000) { channel.maintenance.awaitAvailable() }
    }

    @Test fun cancellationAndChannelRetirementReleaseMaintenanceWaiters() = runBlocking {
        val clock = AtomicLong()
        val channel = Channel(clock::get)
        channel.maintenance.update(SessionMaintenanceSnapshot(0, 0, 1))
        val cancelled = launch { awaitTransferResult(channel, 5) { awaitCancellation() } }
        delay(15)
        withTimeout(1000) { cancelled.cancelAndJoin() }
        assertTrue(cancelled.isCancelled)
        val retired = async {
            try { awaitTransferResult(channel, 5) { awaitCancellation() }; null }
            catch (error: SessionException) { error.reason }
        }
        delay(15)
        channel.maintenance.close()
        assertEquals(SessionFailure.CANCELLED, withTimeout(1000) { retired.await() })
    }

    @Test fun ordinaryTimeoutIsNotExtendedWithoutMaintenance() = runBlocking {
        val clock = AtomicLong()
        val channel = Channel(clock::get)
        val wait = async {
            try { awaitTransferResult(channel, 5) { awaitCancellation() }; false }
            catch (_: TimeoutCancellationException) { true }
        }
        yield(); clock.set(10)
        assertTrue(withTimeout(1000) { wait.await() })
    }
}
