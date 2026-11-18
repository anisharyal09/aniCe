// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies BLE ingress reservation ordering, bounded startup bursts and retirement fencing.
package io.github.anisharyal09.anice.infrastructure.connections

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class SessionInputQueueTests {
    @Test fun oneActiveEnvelopeDoesNotSpendOneOfTheEightQueuedSlots() = runBlocking {
        val queue = SessionInputQueue()
        assertTrue(queue.offer(ByteArray(4096)))
        assertNotNull(queue.next())
        assertEquals(0, queue.count)
        repeat(8) { assertTrue(queue.offer(ByteArray(4096))) }
        assertEquals(8, queue.count)
        assertEquals(32768, queue.bytes)
        assertFalse(queue.offer(ByteArray(1)))
        repeat(8) { assertNotNull(queue.next()) }
        assertEquals(0, queue.count)
        queue.close()
    }

    @Test fun immediateConsumerCannotReleaseBeforeOfferReserves() = runBlocking {
        val queue = SessionInputQueue()
        val consumer = async(Dispatchers.Unconfined) { queue.next() }
        assertTrue(queue.offer(ByteArray(23)))
        assertNotNull(consumer.await())
        assertEquals(0, queue.count)
        assertEquals(0, queue.bytes)
        queue.close()
    }

    @Test fun closeDiscardsQueuedEnvelopesAndCannotReviveTheConsumer() = runBlocking {
        val queue = SessionInputQueue()
        repeat(8) { assertTrue(queue.offer(ByteArray(8))) }
        queue.close()
        assertEquals(0, queue.count)
        assertNull(queue.next())
        assertFalse(queue.offer(ByteArray(8)))
        queue.close()
    }

    @Test fun malformedSizesAreRefusedBeforeQueueAdmission() {
        val queue = SessionInputQueue()
        assertFalse(queue.offer(ByteArray(0)))
        assertFalse(queue.offer(ByteArray(4097)))
        assertEquals(0, queue.count)
        queue.close()
    }
}
