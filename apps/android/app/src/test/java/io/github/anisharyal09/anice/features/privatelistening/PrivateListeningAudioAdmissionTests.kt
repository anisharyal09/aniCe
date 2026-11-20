// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises worker receipt fencing against focus, retirement and coalesced LAN maintenance.
package io.github.anisharyal09.anice.features.privatelistening

import io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor
import io.github.anisharyal09.anice.infrastructure.connections.ChannelMaintenance
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.SessionMaintenanceSnapshot
import org.junit.Assert.*
import org.junit.Test

class PrivateListeningAudioAdmissionTests {
    @Test fun pauseMaintenanceAndRetirementPreserveReceiptWithoutRevivingAudibleWrites() {
        val descriptor = ChannelDescriptor("fixture", "lan", DeviceIdentity("id", "Mac", "macos", "key", "hash"))
        val id = "01234567-89ab-4cde-8fab-0123456789ab"
        var offers = 0
        val output = object : PrivateListeningOutput {
            override fun offer(message: PrivateListeningMessage): Boolean { offers++; return true }
            override fun pause() {}
            override suspend fun resume() {}
            override fun close() {}
        }
        val maintenance = ChannelMaintenance { 0 }
        val admission = PrivateListeningAudioAdmission(descriptor, id, output, maintenance)
        fun packet(sequence: Long) = PrivateListeningMessage.audio(id, sequence, ByteArray(3840))
        assertTrue(admission.receive(packet(1), 100))
        admission.pause()
        assertTrue(admission.receive(packet(2), 200))
        assertEquals(1, offers)
        admission.resume()
        maintenance.update(SessionMaintenanceSnapshot(elapsedMillis = 1000, revision = 2))
        assertTrue(admission.receive(packet(3), 1200))
        assertEquals(1, offers)
        admission.resume()
        assertTrue(admission.receive(packet(4), 1300))
        assertEquals(2, offers)
        assertEquals(4L, admission.receipt.sequence)
        assertEquals(100L, admission.receipt.firstAudioAt)
        admission.close()
        assertFalse(admission.receive(packet(5), 1400))
        assertEquals(2, offers)
    }
}
