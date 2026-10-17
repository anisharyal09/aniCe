// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies retired-channel rejection, bounded submissions and explicit DATA fallback without replay.
package io.github.anisharyal09.anice.infrastructure.connections

import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class FeatureDispatchTests {
    private class Handler : FeatureHandler {
        lateinit var channel: SecuredChannel
        var retired = 0
        var capacity = 0
        var handled = 0
        var result = DataHandling.UNRECOGNIZED
        var receive: (suspend () -> Unit)? = null
        override fun available(channel: SecuredChannel) { this.channel=channel }
        override fun retired(descriptor: ChannelDescriptor) { retired++ }
        override fun capacityAvailable(descriptor: ChannelDescriptor) { capacity++ }
        override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling { handled++; receive?.invoke(); return result }
    }
    private fun descriptor(id: String) = ChannelDescriptor(id,"ble",DeviceIdentity("fixture","Mac","macos","fixture-key","fixture-fingerprint"))
    @Test fun activityRequiresSuccessfulLiveSubmissionOrHandledReception() = runBlocking {
        val dispatch = FeatureDispatch(); val handler = Handler(); dispatch.register(handler)
        val activity = mutableListOf<Byte>()
        dispatch.applicationActivity = { descriptor, bytes -> assertEquals("live", descriptor.instance); activity.add(bytes.single()) }
        dispatch.available(descriptor("live")) {}
        handler.channel.sendData(byteArrayOf(1))
        handler.result = DataHandling.HANDLED
        assertEquals(DataHandling.HANDLED, dispatch.handle("ble", "live", byteArrayOf(2)))
        handler.result = DataHandling.DISCARDED
        dispatch.handle("ble", "live", byteArrayOf(3))
        handler.result = DataHandling.UNRECOGNIZED
        dispatch.handle("ble", "live", byteArrayOf(4))
        dispatch.handle("ble", "stale", byteArrayOf(5))
        assertEquals(listOf(1.toByte(), 2.toByte()), activity)
        dispatch.available(descriptor("failed")) { throw SessionBackpressure() }
        try { handler.channel.sendData(byteArrayOf(6)); fail("Refused send succeeded") } catch (_: SessionBackpressure) {}
        assertEquals(2, activity.size)
    }
    @Test fun retiresInstancesAndPreservesUnrecognizedFallback() = runBlocking {
        val dispatch=FeatureDispatch(); val handler=Handler(); dispatch.register(handler)
        var sends=0
        dispatch.available(descriptor("first")) { sends++ }
        val old=handler.channel
        assertEquals(DataHandling.UNRECOGNIZED,dispatch.handle("ble","first",byteArrayOf(1)))
        handler.result=DataHandling.DISCARDED
        assertEquals(DataHandling.DISCARDED,dispatch.handle("ble","first",byteArrayOf(1)))
        dispatch.capacityAvailable("ble"); assertEquals(1,handler.capacity)
        dispatch.available(descriptor("second")) { sends++ }
        assertEquals(1,handler.retired)
        assertEquals(DataHandling.DISCARDED,dispatch.handle("ble","first",byteArrayOf(1)))
        assertEquals(2,handler.handled)
        try { old.sendData(byteArrayOf(1)); fail("Retired channel submitted DATA") } catch(error: SessionException) { assertEquals(SessionFailure.CANCELLED,error.reason) }
        assertEquals(0,sends)
        handler.channel.sendData(ByteArray(4000)); assertEquals(1,sends)
        try { handler.channel.sendData(ByteArray(4001)); fail("Oversized DATA submitted") } catch(_: IllegalArgumentException) {}
        assertEquals(1,sends)
        dispatch.retired("ble"); dispatch.capacityAvailable("ble"); assertEquals(1,handler.capacity)
    }
    @Test fun suspendedDeliveryReleasesUiAndCannotFallThroughAfterReplacement() = runBlocking {
        val dispatch = FeatureDispatch()
        val first = Handler(); val next = Handler()
        dispatch.register(first); dispatch.register(next)
        dispatch.available(descriptor("old")) {}
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        first.receive = { entered.complete(Unit); release.await() }
        val delivery = async { dispatch.handle("ble", "old", byteArrayOf(1)) }
        withTimeout(1000) { entered.await() }
        var heartbeat = false
        launch { heartbeat = true }.join()
        assertTrue(heartbeat)
        dispatch.available(descriptor("new")) {}
        release.complete(Unit)
        assertEquals(DataHandling.DISCARDED, withTimeout(1000) { delivery.await() })
        assertEquals(0, next.handled)
    }

    @Test fun retirementDuringSubmissionDoesNotReplayUncertainData() = runBlocking {
        val dispatch=FeatureDispatch(); val handler=Handler(); dispatch.register(handler)
        var activities = 0
        dispatch.applicationActivity = { _, _ -> activities++ }
        val entered=CompletableDeferred<Unit>(); val release=CompletableDeferred<Unit>(); var sends=0
        dispatch.available(descriptor("first")) { sends++; entered.complete(Unit); release.await() }
        val old=handler.channel
        val work=async { try { old.sendData(byteArrayOf(1)); false } catch(error: SessionException) { error.reason==SessionFailure.CANCELLED } }
        entered.await(); dispatch.available(descriptor("second")) { sends++ }; release.complete(Unit)
        assertTrue(work.await()); assertEquals(1,sends); assertEquals(0,activities)
    }
}
