// SPDX-License-Identifier: GPL-3.0-or-later
// Routes authenticated transfer messages and applies channel capacity policy.
package io.github.anisharyal09.anice.features.transfer

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.github.anisharyal09.anice.infrastructure.connections.ChannelDescriptor
import io.github.anisharyal09.anice.infrastructure.connections.DataHandling
import io.github.anisharyal09.anice.infrastructure.connections.FeatureHandler
import io.github.anisharyal09.anice.infrastructure.connections.SecuredChannel
import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionBackpressure
import io.github.anisharyal09.anice.infrastructure.session.SessionException
import io.github.anisharyal09.anice.infrastructure.session.SessionFailure
import kotlinx.coroutines.*
import kotlin.coroutines.coroutineContext
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.channels.Channel

internal fun TransferController.updateState(newState: TransferState) {
        val previous = state
        if (newState is TransferState.Transferring && previous is TransferState.Paused && newState.fileBytes > previous.fileBytes) { pauseExpiresAt = null; pauseDeadline = null }
        var published = newState
        if (newState is TransferState.Transferring) {
            val progress = newState
            if (progressJob?.isActive != true || progressEpoch != epoch) {
                progressJob?.cancel()
                progressEpoch = epoch
                progressSampleAt = clock()
                progressSpeed = 0.0
                progressRate = TransferRate().also { it.add(progress.totalBytes, progressSampleAt) }
                val operation = epoch
                progressJob = scope.launch(start = CoroutineStart.LAZY) {
                    while (isActive && operation == epoch) {
                        delay(250L)
                        val current = state as? TransferState.Transferring ?: break
                        val index = if (receiving) receiverCurrentFileIndex else senderFileIndex
                        val file = current.batch.files.getOrNull(index) ?: break
                        val written = if (receiving) receiverWrittenBytes else acknowledgedBytes
                        val completed = current.batch.files.take(index).sumOf { it.size }
                        updateState(current.copy(fileIndex = index + 1, fileName = file.name,
                            fileBytes = written, fileSize = file.size, totalBytes = completed + written))
                    }
                }.also { it.start() }
            }
            val now = clock()
            if (now - progressSampleAt >= 250L) {
                progressSpeed = progressRate.add(progress.totalBytes, now)
                progressSampleAt = now
            }
            published = progress.copy(speedBps = progressSpeed)
        } else {
            progressJob?.cancel(); progressJob = null
            progressEpoch = null
        }
        state = published
        checkpoint(force = newState is TransferState.IncomingOffer || newState is TransferState.WaitingForPeerApproval ||
            newState is TransferState.Transferring && (previous !is TransferState.Transferring || previous.fileIndex != newState.fileIndex))
        onStateChanged?.invoke(published)
    }

internal fun TransferController.selectPreferredChannel() {
        // A live batch remains bound to its channel generation. A paused batch, by contrast, must
        // adopt a newly secured channel so the retained prefix can continue there.
        val canRebind = !isBusy || state is TransferState.Connecting || state is TransferState.Paused
        if (activeChannel != null && !canRebind) return
        val preferred = listOf("lan", "ble").firstOrNull { channels[it] != null && capabilities[it] != null }
            ?.let { channels[it] } ?: channels["lan"] ?: channels["ble"]
        activeChannel = preferred
        peerConnected = preferred != null
        peerCompatible = false
        peerMaxChunkBytes = 3072
        peerMaxWindow = 64
        clearOfferAssembly()
        preferred?.let { channel ->
            capabilities[channel.descriptor.transport]?.let { applyCapability(it) }
        }
        onChannelChanged()
        if (resumeInterruptedOffer()) return
        refreshPausedCapability()
        if (state is TransferState.Paused && activeChannel != null && peerCompatible) {
            // The sender drives LAN auto-resume; the receiver only asks after an explicit opt-in.
            if (receiving) { if (allowBleResume) requestPeerContinuation() } else attemptResume()
        }
    }

internal fun TransferController.applyCapability(message: TransferMessage) {
        peerCompatible = true
        peerMaxChunkBytes = message.number(1).coerceAtMost(when (message.number(0)) {
            4L -> chunkLimit(activeChannel?.descriptor).toLong()
            3L -> minOf(262016L, chunkLimit(activeChannel?.descriptor).toLong())
            2L -> minOf(131072L, chunkLimit(activeChannel?.descriptor).toLong())
            else -> 3072L
        })
        peerMaxWindow = message.number(2).coerceAtMost(if (activeChannel?.descriptor?.transport == "ble") 4L else if (peerMaxChunkBytes > 3072) 8L else 64L)
        if (state is TransferState.Connecting && (!awaitingLan || activeChannel?.descriptor?.transport == "lan")) {
            awaitingLan = false
            connectTimeoutJob?.cancel(); connectTimeoutJob = null
            val send = pendingSend
            pendingSend = null
            updateState(TransferState.Idle)
            send?.invoke()
        }
    }

internal fun TransferController.clearCapacityWaiters() {
        capacityRevision++
        val pending = ArrayList<CompletableDeferred<Unit>>()
        while (true) {
            val waiter = capacityWaiters.poll() ?: break
            pending.add(waiter)
        }
        // Resumption can synchronously enqueue another waiter; it belongs to the next notification.
        pending.forEach { it.complete(Unit) }
    }

internal suspend fun TransferController.sendWithBackpressure(data: ByteArray, channel: SecuredChannel =
        activeChannel ?: throw SessionException(SessionFailure.CANCELLED), jobBound: Boolean = true) {
        val operation = epoch
        while (true) {
            coroutineContext.ensureActive()
            if (jobBound && epoch != operation || channels[channel.descriptor.transport] !== channel) throw SessionException(SessionFailure.CANCELLED)
            val revision = capacityRevision
            val waiter = CompletableDeferred<Unit>()
            capacityWaiters.add(waiter)
            try {
                // Admission stays cancellable; the session protects records only after nonce ownership.
                channel.sendData(data)
                return
            } catch (_: SessionBackpressure) {
                if (revision == capacityRevision) withTimeout(10000) { waiter.await() }
            } finally { capacityWaiters.remove(waiter) }
        }
    }

internal suspend fun TransferController.processMessage(message: TransferMessage, peerName: String, descriptor: ChannelDescriptor) {
        when (message.kind) {
            2L -> handleOffer(message, peerName, descriptor)
            3L -> handleAccept(message)
            4L -> handleReject(message)
            6L -> handleAck(message)
            7L -> {
                val batch = currentBatch ?: return
                val file = sendingFile ?: return
                if (message.string(0) != batch.id || message.string(1) != file.id ||
                    message.number(2) == 0L && (sentBytes != file.size || !message.bytes(3).contentEquals(file.sha256))) return
                if (message.number(2) == 0L) { pauseExpiresAt = null; pauseDeadline = null }
                val deferred = synchronized(fileResultLock) {
                    val waiting = fileResultDeferred
                    if (waiting != null) fileResultDeferred = null else receivedFileResult = message
                    waiting
                }
                deferred?.complete(message)
            }
            8L -> Unit // Verified per-file results determine completion.
            10L, 11L -> Unit // Routed before the active-channel guard so a new channel can take over.
            9L -> {
                val batch = currentBatch ?: return
                val fileId = message.string(1)
                if (message.string(0) != batch.id || fileId.isNotEmpty() && fileId != sendingFile?.id &&
                    fileId != batch.files.getOrNull(receiverCurrentFileIndex)?.id) return
                cancelTransfer(local = false)
            }
        }
    }
