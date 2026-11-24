// SPDX-License-Identifier: GPL-3.0-or-later
// Aggregates opt-in timing/count evidence without retaining PCM, peer identity or an event queue.
package io.github.anisharyal09.anice.features.privatelistening

internal data class PhoneAudioDiagnosticContext(
    val state: Long,
    val queuedPackets: Int,
    val inFlight: Boolean,
    val maintenance: Boolean,
    val captureAvailable: Boolean?,
    val activityStarted: Boolean? = null,
    val activityResumed: Boolean? = null,
    val screenInteractive: Boolean? = null,
)

internal data class PhoneAudioDiagnosticReport(val fields: Map<String, Any?>)

/** A run keeps constant-size counters and emits at most 600 ordinary reports plus one terminal report. */
internal class PhoneAudioDiagnostics(
    private val run: Long,
    private val nanoTime: () -> Long,
) {
    private class Timing {
        var samples = 0L
        var maximum: Long? = null
        var windowMaximum: Long? = null
        var over40ms = 0L
        var under5ms = 0L
        fun record(duration: Long) {
            if (duration < 0) return
            samples++
            maximum = maxOf(maximum ?: 0, duration)
            windowMaximum = maxOf(windowMaximum ?: 0, duration)
            if (duration > 40_000_000) over40ms++
            if (duration < 5_000_000) under5ms++
        }
        fun fields(prefix: String): Map<String, Long?> {
            val result = mapOf(
                "${prefix}_samples" to samples,
                "${prefix}_max_us" to maximum?.div(1000),
                "${prefix}_window_max_us" to windowMaximum?.div(1000),
                "${prefix}_over_40ms" to over40ms,
                "${prefix}_under_5ms" to under5ms,
            )
            windowMaximum = null
            return result
        }
    }

    private val startedAt = nanoTime()
    private var lastReportAt: Long? = null
    private var lastWindowStartedAt = 0L
    private var reports = 0
    private var finalReported = false
    @Volatile var enabled = true
        private set
    private val read = Timing()
    private val captureIntervals = Timing()
    private val presentationWait = Timing()
    private val queueAge = Timing()
    private val encode = Timing()
    private val send = Timing()
    private var previousCaptureAt: Long? = null
    private var reads = 0L
    private var readFrames = 0L
    private var emptyReads = 0L
    private var readErrors = 0L
    private var capturedPackets = 0L
    private var emissionFailures = 0L
    private var sentPackets = 0L
    private var queueDrops = 0L
    private var maintenanceDrops = 0L
    private var backpressureDrops = 0L
    private var cancelledSends = 0L
    private var maximumQueue = 0
    private var requestedCaptureFrames: Int? = null
    private var effectiveCaptureFrames: Int? = null

    fun timestamp(): Long? = if (enabled) nanoTime() else null

    @Synchronized fun prepared(requestedFrames: Int, effectiveFrames: Int?) {
        if (!enabled) return
        requestedCaptureFrames = requestedFrames
        effectiveCaptureFrames = effectiveFrames
    }

    @Synchronized fun readFinished(start: Long?, count: Int, stopRequested: Boolean) {
        if (!enabled || start == null) return
        reads++
        read.record(nanoTime() - start)
        when {
            count > 0 && count % 4 == 0 -> readFrames += count / 4
            !stopRequested && count == 0 -> emptyReads++
            !stopRequested -> readErrors++
        }
    }

    @Synchronized fun captured(): Long? {
        if (!enabled) return null
        val time = nanoTime()
        previousCaptureAt?.let { captureIntervals.record(time - it) }
        previousCaptureAt = time
        capturedPackets++
        return time
    }

    @Synchronized fun emissionFailed() { if (enabled) emissionFailures++ }
    @Synchronized fun queued(depth: Int, replaced: Long) {
        if (!enabled) return
        maximumQueue = maxOf(maximumQueue, depth)
        queueDrops += replaced
    }
    @Synchronized fun maintenanceDiscarded(count: Int) { if (enabled) maintenanceDrops += count }
    @Synchronized fun presentationReady(scheduledAt: Long?) {
        if (enabled && scheduledAt != null) presentationWait.record(nanoTime() - scheduledAt)
    }
    @Synchronized fun dequeued(capturedAt: Long?) {
        if (enabled && capturedAt != null) queueAge.record(nanoTime() - capturedAt)
    }
    @Synchronized fun encoded(start: Long?) {
        if (enabled && start != null) encode.record(nanoTime() - start)
    }
    @Synchronized fun submitted(start: Long?, succeeded: Boolean) {
        if (!enabled || start == null) return
        send.record(nanoTime() - start)
        if (succeeded) sentPackets++
    }
    @Synchronized fun backpressured() { if (enabled) backpressureDrops++ }
    @Synchronized fun sendCancelled() { if (enabled) cancelledSends++ }

    @Synchronized fun report(
        context: PhoneAudioDiagnosticContext,
        terminal: Boolean = false,
    ): PhoneAudioDiagnosticReport? {
        if (finalReported) return null
        val time = nanoTime()
        val elapsed = (time - startedAt).coerceAtLeast(0)
        if (!terminal && (reports >= MAX_REPORTS || elapsed > MAX_DURATION_NS)) {
            enabled = false
            return null
        }
        if (!terminal && lastReportAt?.let { time - it < REPORT_INTERVAL_NS } == true) return null
        val windowStarted = lastWindowStartedAt
        lastWindowStartedAt = elapsed
        if (terminal) { finalReported = true; enabled = false } else reports++
        lastReportAt = time
        return PhoneAudioDiagnosticReport(buildMap {
            put("version", 1)
            put("side", "android")
            put("run", run)
            put("elapsed_ms", elapsed / 1_000_000)
            put("window_start_elapsed_ms", windowStarted / 1_000_000)
            put("terminal", terminal)
            put("state", context.state)
            put("queued_packets", context.queuedPackets)
            put("in_flight", context.inFlight)
            put("maintenance", context.maintenance)
            put("capture_available", context.captureAvailable)
            put("activity_started", context.activityStarted)
            put("activity_resumed", context.activityResumed)
            put("screen_interactive", context.screenInteractive)
            put("capture_requested_frames", requestedCaptureFrames)
            put("capture_effective_frames", effectiveCaptureFrames)
            put("read_calls", reads)
            put("read_frames", readFrames)
            put("empty_reads", emptyReads)
            put("read_errors", readErrors)
            put("captured_packets", capturedPackets)
            put("emission_failures", emissionFailures)
            put("submitted_packets", sentPackets)
            put("queue_replaced_packets", queueDrops)
            put("maintenance_dropped_packets", maintenanceDrops)
            put("backpressure_dropped_packets", backpressureDrops)
            put("cancelled_send_attempts", cancelledSends)
            put("maximum_queued_packets", maximumQueue)
            putAll(read.fields("read"))
            putAll(captureIntervals.fields("capture_interval"))
            putAll(presentationWait.fields("presentation_wait"))
            putAll(queueAge.fields("queue_age"))
            putAll(encode.fields("encode"))
            putAll(send.fields("submission"))
        })
    }

    internal companion object {
        const val TAG = "aniCePhoneAudioDiag"
        const val PREFIX = "phone_audio_diag "
        const val MAX_REPORTS = 600
        const val REPORT_INTERVAL_NS = 1_000_000_000L
        const val MAX_DURATION_NS = 600_000_000_000L
        fun allowed(debuggable: Boolean, packageName: String, requested: Boolean): Boolean =
            debuggable && packageName == "io.github.anisharyal09.anice.preview.transfer" && requested
    }
}
