// SPDX-License-Identifier: GPL-3.0-or-later
// Isolates native playback calls so worker pacing and route barriers can be tested without playing audio.
package io.github.anisharyal09.anice.features.audiosharing

import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRouting
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper

internal interface ListeningNativeTrack {
    val initialized: Boolean
    val bufferSizeInFrames: Int
    val startThresholdInFrames: Int?
    val performanceMode: Int
    val playing: Boolean
    val playbackHeadPosition: Int
    val underrunCount: Int
    val routes: List<ListeningRoute>
    fun setBufferSizeInFrames(frames: Int): Int
    fun setStartThresholdInFrames(frames: Int)
    fun setRoutingListener(changed: () -> Unit)
    fun setVolume(volume: Float): Boolean
    fun pause()
    fun flush()
    fun play()
    fun write(bytes: ByteArray, offset: Int, count: Int): Int
    fun release()
    fun preferBuiltInSpeaker(): Boolean = false
}

internal class AudioSharingNativeTrack private constructor(
    private val track: AudioTrack, private val audio: AudioManager,
) : ListeningNativeTrack {
    private var routing: AudioRouting.OnRoutingChangedListener? = null
    override val initialized get() = track.state == AudioTrack.STATE_INITIALIZED
    override val bufferSizeInFrames get() = track.bufferSizeInFrames
    override val startThresholdInFrames get() = if (Build.VERSION.SDK_INT >= 31) track.startThresholdInFrames else null
    override val performanceMode get() = track.performanceMode
    override val playing get() = track.playState == AudioTrack.PLAYSTATE_PLAYING
    override val playbackHeadPosition get() = track.playbackHeadPosition
    override val underrunCount get() = track.underrunCount
    override val routes: List<ListeningRoute> get() =
        (if (Build.VERSION.SDK_INT >= 36) track.routedDevices else listOfNotNull(track.routedDevice))
            .map { it.route() }

    override fun setBufferSizeInFrames(frames: Int) = track.setBufferSizeInFrames(frames)
    override fun setStartThresholdInFrames(frames: Int) {
        if (Build.VERSION.SDK_INT >= 31) track.setStartThresholdInFrames(frames)
    }
    override fun setRoutingListener(changed: () -> Unit) {
        routing?.let { track.removeOnRoutingChangedListener(it) }
        val listener = AudioRouting.OnRoutingChangedListener { changed() }
        routing = listener
        track.addOnRoutingChangedListener(listener, Handler(Looper.getMainLooper()))
    }
    override fun setVolume(volume: Float) = track.setVolume(volume) == AudioTrack.SUCCESS
    override fun pause() = track.pause()
    override fun flush() = track.flush()
    override fun play() = track.play()
    override fun preferBuiltInSpeaker(): Boolean {
        val speaker = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER } ?: return false
        return track.setPreferredDevice(speaker)
    }
    override fun write(bytes: ByteArray, offset: Int, count: Int) =
        track.write(bytes, offset, count, AudioTrack.WRITE_NON_BLOCKING)
    override fun release() {
        try { routing?.let { track.removeOnRoutingChangedListener(it) } }
        finally { routing = null; track.release() }
    }

    companion object {
        fun create(audio: AudioManager, confirmed: Set<String>, speakerFallback: Boolean = false): ListeningNativeTrack {
            val minimum = AudioTrack.getMinBufferSize(48000, AudioFormat.CHANNEL_OUT_STEREO,
                AudioFormat.ENCODING_PCM_16BIT)
            if (minimum <= 0 || minimum / 4 > AudioSharingNativeBufferPolicy.MAXIMUM_NATIVE_FRAMES) {
                throw AudioSharingPlaybackError(3, "Audio buffer unsupported")
            }
            val outputs = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            val candidate = outputs.firstOrNull {
                AudioSharingRoutes.privateOutput(it.route(), confirmed)
            } ?: outputs.firstOrNull { speakerFallback && it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                ?: throw AudioSharingPlaybackError(6, "Connect or confirm your headphones")
            fun create(mode: Int) = AudioTrack.Builder()
                .setAudioAttributes(AudioSharingPlayer.ATTRIBUTES)
                .setAudioFormat(AudioFormat.Builder().setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setTransferMode(AudioTrack.MODE_STREAM).setBufferSizeInBytes(maxOf(minimum, 15360))
                .setPerformanceMode(mode).build()
            val native = try { create(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY) }
                catch (_: IllegalArgumentException) { create(AudioTrack.PERFORMANCE_MODE_NONE) }
            try {
                if (native.state != AudioTrack.STATE_INITIALIZED) {
                    throw AudioSharingPlaybackError(3, "Native audio playback unsupported")
                }
                if (!native.setPreferredDevice(candidate)) {
                    throw AudioSharingPlaybackError(6, "Approved audio route unavailable")
                }
                return AudioSharingNativeTrack(native, audio)
            } catch (error: Exception) {
                native.release()
                throw error
            }
        }

        private fun AudioDeviceInfo.route() = ListeningRoute(type, address.orEmpty(), productName.toString())
    }
}
