// SPDX-License-Identifier: GPL-3.0-or-later
// Keeps playback scheduling separate from UI, file decoding and the shared Default coroutine pool.
package io.github.anisharyal09.anice.features.privatelistening

import android.os.Process
import kotlinx.coroutines.asCoroutineDispatcher
import java.util.concurrent.ScheduledThreadPoolExecutor

internal class PrivateListeningAudioWorker : AutoCloseable {
    private val executor = ScheduledThreadPoolExecutor(1) { task ->
        Thread({
            try { Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO) }
            catch (_: SecurityException) { /* A denied scheduling hint must not authorize or abort playback. */ }
            task.run()
        }, "aniCe headphone playback")
    }.apply { removeOnCancelPolicy = true }
    val dispatcher = executor.asCoroutineDispatcher()
    override fun close() { dispatcher.close() }
}
