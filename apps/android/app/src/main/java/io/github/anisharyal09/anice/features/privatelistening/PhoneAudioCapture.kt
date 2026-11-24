// SPDX-License-Identifier: GPL-3.0-or-later
// Captures only eligible app playback using an externally user-authorized, foreground-owned projection.
package io.github.anisharyal09.anice.features.privatelistening

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import java.util.concurrent.atomic.AtomicBoolean

internal enum class PhoneAudioStopCause { LOCAL, REVOKED, FAILURE }

internal enum class PhoneAudioReadDecision { CONTINUE, END, RETRY, FAIL }

/** Pure read policy so normal Stop/close races are testable without a native record. */
internal object PhoneAudioReadPolicy {
    private const val BYTES_PER_STEREO_FRAME = 4
    fun decide(stopRequested: Boolean, count: Int): PhoneAudioReadDecision = when {
        stopRequested -> PhoneAudioReadDecision.END
        count > 0 && count % BYTES_PER_STEREO_FRAME == 0 -> PhoneAudioReadDecision.CONTINUE
        count == 0 -> PhoneAudioReadDecision.RETRY
        else -> PhoneAudioReadDecision.FAIL
    }
}

internal data class PhoneAudioCaptureResult(
    val packets: Long,
    val emissionFailures: Long,
    val readErrors: Long,
    val discardedPartialBytes: Int,
    val stopCause: PhoneAudioStopCause,
)

/** The caller must own the mediaProjection foreground service and RECORD_AUDIO grant.
 * This primitive never requests permissions, acquires a projection token, creates a display,
 * persists PCM, or changes the phone's volume/output. Its emit callback must not block on LAN. */
internal class PhoneAudioCapture(
    private val context: Context,
    private val projection: MediaProjection,
    private val onStopped: (PhoneAudioStopCause) -> Unit = {},
) : AutoCloseable {
    private val stopped = AtomicBoolean(false)
    private val notified = AtomicBoolean(false)
    private val main = Handler(Looper.getMainLooper())
    private var cause: PhoneAudioStopCause? = null
    private var record: AudioRecord? = null
    private val callback = object : MediaProjection.Callback() {
        override fun onStop() {
            finish(PhoneAudioStopCause.REVOKED)
        }
    }

    init {
        projection.registerCallback(callback, Handler(Looper.getMainLooper()))
    }

    val available: Boolean get() = !stopped.get()

    @Synchronized fun prepare() {
        check(!stopped.get()) { "Capture is already stopped" }
        check(record == null) { "Capture is already prepared" }
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED) {
            finishLocked(PhoneAudioStopCause.FAILURE)
            throw SecurityException("Playback capture permission is not granted")
        }
        val minimum = AudioRecord.getMinBufferSize(48000, AudioFormat.CHANNEL_IN_STEREO,
            AudioFormat.ENCODING_PCM_16BIT)
        check(minimum in 1..153600) { "Native capture buffer unsupported" }
        val configuration = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN).build()
        val native = try {
            AudioRecord.Builder()
                .setAudioFormat(AudioFormat.Builder().setSampleRate(48000)
                    .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setAudioPlaybackCaptureConfig(configuration)
                .setBufferSizeInBytes(maxOf(minimum, 15360)).build()
        } catch (error: Exception) {
            finishLocked(PhoneAudioStopCause.FAILURE)
            throw error
        }
        try {
            check(native.state == AudioRecord.STATE_INITIALIZED)
            native.startRecording()
            check(native.recordingState == AudioRecord.RECORDSTATE_RECORDING)
            record = native
        } catch (error: Exception) {
            native.release()
            finishLocked(PhoneAudioStopCause.FAILURE)
            throw error
        }
    }

    /** Owned capture worker. Stop/close unblocks reads and is reported as a normal end, not a crash. */
    fun run(emit: (Long, ByteArray) -> Unit): PhoneAudioCaptureResult {
        val native = synchronized(this) { checkNotNull(record) { "Capture is not prepared" } }
        val scratch = ByteArray(PrivateListeningMessage.PCM_BYTES)
        val packetizer = PhoneAudioPacketizer()
        var packets = 0L
        var emissionFailures = 0L
        var readErrors = 0L
        var emptyReads = 0
        var consecutiveErrors = 0
        try {
            while (true) {
                val count = try {
                    native.read(scratch, 0, scratch.size, AudioRecord.READ_BLOCKING)
                } catch (_: IllegalStateException) {
                    if (!stopped.get()) readErrors++
                    break
                }
                when (PhoneAudioReadPolicy.decide(stopped.get(), count)) {
                    PhoneAudioReadDecision.CONTINUE -> {
                        emptyReads = 0
                        consecutiveErrors = 0
                        packetizer.accept(scratch, count) { sequence, pcm ->
                            if (!stopped.get()) {
                                try {
                                    emit(sequence, pcm)
                                    packets++
                                } catch (_: Exception) {
                                    emissionFailures++
                                }
                            }
                        }
                    }
                    PhoneAudioReadDecision.END -> break
                    PhoneAudioReadDecision.RETRY -> {
                        if (++emptyReads >= MAX_EMPTY_READS) {
                            readErrors++
                            break
                        }
                    }
                    PhoneAudioReadDecision.FAIL -> {
                        readErrors++
                        if (++consecutiveErrors >= MAX_CONSECUTIVE_ERRORS) break
                    }
                }
            }
        } finally {
            scratch.fill(0)
            packetizer.discardPartial()
            finish(if (readErrors > 0 && synchronizeCause() == null) {
                PhoneAudioStopCause.FAILURE
            } else {
                PhoneAudioStopCause.LOCAL
            })
        }
        return PhoneAudioCaptureResult(packets, emissionFailures, readErrors,
            packetizer.discardedPartialBytes, synchronizeCause() ?: PhoneAudioStopCause.LOCAL)
    }

    @Synchronized override fun close() {
        finishLocked(PhoneAudioStopCause.LOCAL)
    }

    @Synchronized private fun finish(next: PhoneAudioStopCause) {
        finishLocked(next)
    }

    private fun synchronizeCause(): PhoneAudioStopCause? = synchronized(this) { cause }

    private fun finishLocked(next: PhoneAudioStopCause) {
        cause = cause ?: next
        stopped.set(true)
        releaseLocked()
        val result = cause!!
        if (notified.compareAndSet(false, true)) main.post { onStopped(result) }
    }

    private fun releaseLocked() {
        val native = record
        record = null
        try {
            try {
                native?.stop()
            } finally {
                native?.release()
            }
        } catch (_: Exception) {
        }
        try {
            projection.unregisterCallback(callback)
        } catch (_: Exception) {
        }
        try {
            projection.stop()
        } catch (_: Exception) {
        }
    }

    private companion object {
        const val MAX_EMPTY_READS = 10
        const val MAX_CONSECUTIVE_ERRORS = 3
    }
}
