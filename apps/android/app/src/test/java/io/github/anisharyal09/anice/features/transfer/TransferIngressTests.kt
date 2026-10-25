// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises bounded transfer admission, active-write accounting and epoch invalidation under a serial owner.
package io.github.anisharyal09.anice.features.transfer

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class TransferIngressTests {
    @Test fun byteAndRecordBoundsIncludeTheActiveConsumer() = runBlocking {
        for ((byteLimit, recordLimit) in listOf(4 to 8, 100 to 2)) {
            val channel = MockAndroidSecuredChannel().descriptor
            val gate = CompletableDeferred<Unit>()
            val started = CompletableDeferred<Unit>()
            val consumed = mutableListOf<Int>()
            val ingress = TransferIngress(this) { _, _, bytes ->
                if (bytes[0] == 1.toByte()) { started.complete(Unit); gate.await() }
                consumed.add(bytes[0].toInt())
            }
            val epoch = UUID.randomUUID()
            suspend fun send(value: Int) = ingress.enqueue(channel, epoch, byteArrayOf(value.toByte(), 0), byteLimit, recordLimit) { true }
            assertTrue(send(1)); started.await(); assertTrue(send(2))
            val blocked = async(start = CoroutineStart.UNDISPATCHED) { send(3) }
            yield(); assertFalse("Active data must still consume capacity", blocked.isCompleted)
            val cancelled = async(start = CoroutineStart.UNDISPATCHED) { send(4) }
            cancelled.cancelAndJoin()
            gate.complete(Unit)
            assertTrue(withTimeout(1000) { blocked.await() })
            withTimeout(1000) { ingress.drain() }
            assertEquals(listOf(1, 2, 3), consumed)
        }
    }

    @Test fun invalidationDropsQueuedEpochAndWakesBlockedProducer() = runBlocking {
        val descriptor = MockAndroidSecuredChannel().descriptor
        val gate = CompletableDeferred<Unit>()
        val started = CompletableDeferred<Unit>()
        val consumed = mutableListOf<Int>()
        var live = true
        val ingress = TransferIngress(this) { _, _, data ->
            if (data[0] == 1.toByte()) { started.complete(Unit); gate.await() }
            consumed.add(data[0].toInt())
        }
        val epoch = UUID.randomUUID()
        suspend fun send(value: Int) = ingress.enqueue(descriptor, epoch, byteArrayOf(value.toByte()), 2, 2) { live }
        assertTrue(send(1)); started.await(); assertTrue(send(2))
        val blocked = async(start = CoroutineStart.UNDISPATCHED) { send(3) }
        live = false; ingress.invalidate(descriptor)
        assertFalse(withTimeout(1000) { blocked.await() })
        val drain = async(start = CoroutineStart.UNDISPATCHED) { ingress.drain() }
        // Cancellation can stop a suspended consumer before its storage operation begins.
        gate.complete(Unit); withTimeout(1000) { drain.await() }
        assertEquals(emptyList<Int>(), consumed)
        live = true
        assertTrue(send(4)); withTimeout(1000) { ingress.drain() }
        assertEquals(listOf(4), consumed)
    }

    @Test fun successorEpochRunsInAFreshConsumerAfterAnUninterruptibleWrite() = runBlocking {
        val old = MockAndroidSecuredChannel(instance = "old").descriptor
        val fresh = MockAndroidSecuredChannel(instance = "fresh").descriptor
        val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val consumed = mutableListOf<Int>()
        val ingress = TransferIngress(this) { descriptor, _, data ->
            if (descriptor == old) withContext(NonCancellable) { started.complete(Unit); release.await() }
            else assertTrue("Successor must not inherit cancellation", currentCoroutineContext().isActive)
            consumed.add(data[0].toInt())
        }
        assertTrue(ingress.enqueue(old, UUID.randomUUID(), byteArrayOf(1), 2, 2) { true })
        started.await(); ingress.invalidate(old)
        assertTrue(ingress.enqueue(fresh, UUID.randomUUID(), byteArrayOf(2), 2, 2) { true })
        release.complete(Unit)
        withTimeout(1000) { ingress.drain() }
        assertEquals(listOf(1, 2), consumed)
    }

    @Test fun drainingAnotherChannelDoesNotWaitForOrCancelTheActiveWrite() = runBlocking {
        val active = MockAndroidSecuredChannel(instance = "active").descriptor
        val other = MockAndroidSecuredChannel(instance = "other").descriptor
        val gate = CompletableDeferred<Unit>(); val started = CompletableDeferred<Unit>()
        var completed = false
        val ingress = TransferIngress(this) { _, _, _ -> started.complete(Unit); gate.await(); completed = true }
        assertTrue(ingress.enqueue(active, UUID.randomUUID(), byteArrayOf(1), 1, 1) { true })
        started.await(); ingress.invalidate(other)
        withTimeout(1000) { ingress.drain(other) }
        assertFalse(completed)
        gate.complete(Unit); withTimeout(1000) { ingress.drain(active) }
        assertTrue(completed)
    }

    @Test fun canonicalClassificationRetainsFullValidation() {
        val batch = UUID.randomUUID().toString(); val file = UUID.randomUUID().toString()
        val encoded = TransferMessage.chunk(batch, file, 0, byteArrayOf(1)).encode()
        assertEquals(5, TransferMessage.peekKind(encoded))
        assertEquals(5L, TransferMessage.decode(encoded)!!.kind)
        assertNull(TransferMessage.peekKind(encoded.copyOf(10)))
        assertNull(TransferMessage.peekKind(encoded.copyOf().apply { this[1] = 0x6d }))
        val malformed = encoded.copyOf(18)
        assertEquals(5, TransferMessage.peekKind(malformed))
        try { TransferMessage.decode(malformed); fail("Header classification must not validate truncated chunks") }
        catch (_: io.github.anisharyal09.anice.infrastructure.session.SessionException) {}
    }
}
