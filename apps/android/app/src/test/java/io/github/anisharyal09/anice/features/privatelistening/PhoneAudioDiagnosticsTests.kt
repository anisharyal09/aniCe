// SPDX-License-Identifier: GPL-3.0-or-later
// Checks timing attribution, bounded reporting and missing native data without capture or device access.
package io.github.anisharyal09.anice.features.privatelistening

import org.junit.Assert.*
import org.junit.Test

class PhoneAudioDiagnosticsTests {
    private class Clock(var nanos: Long = 0)
    private val context = PhoneAudioDiagnosticContext(2, 3, true, false, true)

    @Test fun diagnosticsRequireBothDebugAndTheExactOptInPreview() {
        val preview = "io.github.anisharyal09.anice.preview.transfer"
        assertTrue(PhoneAudioDiagnostics.allowed(true, preview, true))
        assertFalse(PhoneAudioDiagnostics.allowed(false, preview, true))
        assertFalse(PhoneAudioDiagnostics.allowed(true, preview, false))
        assertFalse(PhoneAudioDiagnostics.allowed(true, "io.github.anisharyal09.anice", true))
        assertFalse(PhoneAudioDiagnostics.allowed(true, "$preview.other", true))
    }

    @Test fun capturePresentationQueueAndSubmissionCostsAreKeptSeparate() {
        val clock = Clock()
        val probe = PhoneAudioDiagnostics(1) { clock.nanos }
        probe.prepared(3840, 4096)
        val readStart = probe.timestamp()
        clock.nanos = 80_000_000
        probe.readFinished(readStart, 3840, false)
        val packetAt = probe.captured()
        probe.queued(1, 0)
        clock.nanos = 180_000_000
        probe.presentationReady(packetAt)
        probe.dequeued(packetAt)
        val encode = probe.timestamp()
        clock.nanos += 1_000_000
        probe.encoded(encode)
        val send = probe.timestamp()
        clock.nanos += 50_000_000
        probe.submitted(send, true)
        probe.captured()
        probe.queued(3, 2)
        probe.maintenanceDiscarded(3)
        probe.backpressured()
        probe.sendCancelled()
        val fields = requireNotNull(probe.report(context)).fields
        assertEquals(1L, fields["read_calls"])
        assertEquals(960L, fields["read_frames"])
        assertEquals(80_000L, fields["read_max_us"])
        assertEquals(100_000L, fields["presentation_wait_max_us"])
        assertEquals(100_000L, fields["queue_age_max_us"])
        assertEquals(1000L, fields["encode_max_us"])
        assertEquals(50_000L, fields["submission_max_us"])
        assertEquals(151_000L, fields["capture_interval_max_us"])
        assertEquals(1L, fields["submitted_packets"])
        assertEquals(2L, fields["queue_replaced_packets"])
        assertEquals(3L, fields["maintenance_dropped_packets"])
        assertEquals(1L, fields["backpressure_dropped_packets"])
        assertEquals(1L, fields["cancelled_send_attempts"])
        assertEquals(3, fields["maximum_queued_packets"])
    }

    @Test fun unavailableDataIsNullAndStopReadDoesNotBecomeANativeFailure() {
        val clock = Clock()
        val probe = PhoneAudioDiagnostics(1) { clock.nanos }
        probe.readFinished(0, 0, false)
        probe.readFinished(0, -6, true)
        probe.readFinished(0, -6, false)
        probe.readFinished(0, 3, false)
        val fields = requireNotNull(probe.report(context.copy(captureAvailable = null))).fields
        assertEquals(1L, fields["empty_reads"])
        assertEquals(2L, fields["read_errors"])
        assertNull(fields["capture_effective_frames"])
        assertNull(fields["capture_available"])
        assertNull(fields["activity_resumed"])
        assertNull(fields["submission_max_us"])
        assertFalse(fields.keys.any { it.contains("peer") || it.contains("pcm") || it.contains("credential") })
    }

    @Test fun reportingIsRateLimitedAndEndsWithoutGrowingAnEventQueue() {
        val clock = Clock()
        val probe = PhoneAudioDiagnostics(1) { clock.nanos }
        for (index in 0 until PhoneAudioDiagnostics.MAX_REPORTS) {
            clock.nanos = index * PhoneAudioDiagnostics.REPORT_INTERVAL_NS
            assertNotNull(probe.report(context))
            assertNull(probe.report(context))
        }
        clock.nanos = PhoneAudioDiagnostics.MAX_DURATION_NS
        assertNull(probe.report(context))
        assertFalse(probe.enabled)
        assertNull(probe.captured())
        val terminal = requireNotNull(probe.report(context, terminal = true))
        assertEquals(true, terminal.fields["terminal"])
        assertNull(probe.report(context, terminal = true))
    }
}
