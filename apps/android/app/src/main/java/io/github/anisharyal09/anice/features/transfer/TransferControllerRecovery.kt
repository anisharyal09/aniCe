// SPDX-License-Identifier: GPL-3.0-or-later
// Coordinates checkpoint persistence and interrupted transfer restoration.
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

internal fun TransferController.restoreOnLaunchFlow() {
        if (recoveryStarted || context == null) return
        recoveryStore = TransferRecoveryStore(File(context.noBackupFilesDir, "transfer/checkpoint.bin"))
        recoveryReady = CompletableDeferred()
        startRecoveryWorkers()
    }

internal fun TransferController.startRecoveryWorkers() {
        if (recoveryStarted) return
        val store = recoveryStore ?: return
        recoveryStarted = true
        scope.launch {
            val operation = epoch
            try {
                val (local, saved) = withContext(Dispatchers.IO) { recoveryIdentity() to store.load() }
                recoveryLocal = local
                if (operation == epoch && saved != null) {
                    failedRecovery = saved
                    restoreRecovery(saved, local)
                    failedRecovery = null
                }
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) { updateState(TransferState.Failed("Cannot recover the pending transfer: ${error.message}")) }
            finally { recoveryReady.complete(Unit); selectPreferredChannel() }
        }
        scope.launch(receiveDispatcher) {
            for (write in recoveryWrites) {
                try {
                    if (write.snapshot == null) store.clear()
                    else {
                        write.storage?.flush()
                        store.save(write.snapshot)
                    }
                    write.done?.complete(Unit)
                } catch (error: CancellationException) { throw error }
                catch (error: Exception) {
                    write.done?.completeExceptionally(error)
                    withContext(dispatcher) {
                        if (write.snapshot?.batch?.id == currentBatch?.id) failTransfer("Cannot save transfer recovery: ${error.message}")
                        else System.err.println("Transfer recovery cleanup failed: ${error.javaClass.simpleName}")
                    }
                }
            }
        }
    }

internal fun TransferController.checkpoint(force: Boolean = false, publishingIdentity: String? = null): CompletableDeferred<Unit>? {
        if (finalizing && publishingIdentity == null) return null
        if (recoveryStore == null || !recoveryReady.isCompleted) return null
        val local = recoveryLocal ?: return null
        val batch = currentBatch ?: return null
        if (state !is TransferState.Transferring && state !is TransferState.Paused &&
            state !is TransferState.IncomingOffer && state !is TransferState.WaitingForPeerApproval) return null
        val now = clock()
        // Flushing a provider and its journal on every progress second can serialize the receive path.
        if (!force && now - checkpointAt < 5000) return null
        val peer = activeChannel?.descriptor ?: recoveryPeer ?: return null
        recoveryPeer = peer
        // Publication recovery needs its receipt; never replace the last safe partial checkpoint here.
        val stage = if (publishingIdentity != null) 4 else when (interruptedOffer ?: state) {
            is TransferState.WaitingForPeerApproval -> 1
            is TransferState.IncomingOffer -> 2
            else -> 0
        }
        val index = if (stage == 1 || stage == 2) 0 else if (receiving) receiverCurrentFileIndex else senderFileIndex
        if (index !in batch.files.indices) return null
        if (receiving && receiverStorage == null && stage == 0) return null
        val offset = if (stage == 1 || stage == 2) 0 else if (receiving) receiverWrittenBytes else acknowledgedBytes
        val position = "${batch.id}:$index:$offset:$stage"
        if (!force && checkpointPosition == position) return null
        checkpointPosition = position
        checkpointAt = now
        val expires = pauseExpiresAt ?: (System.currentTimeMillis() + pauseTimeoutMillis)
        val snapshot = TransferCheckpoint(local, peer.peer.deviceId, peer.peer.fingerprint, batch, receiving || stage == 2,
            index, offset,
            destinationDirectory?.absolutePath ?: "", documentDestination?.tree?.toString() ?: "",
            receiverPartFile?.absolutePath ?: "", receiverPartDocument?.toString() ?: "",
            pausedTransport ?: peer.transport, expires, stage, publishingIdentity ?: "", documentDestination?.ownedModes ?: 0)
        val done = if (force) CompletableDeferred<Unit>() else null
        recoveryWrites.trySend(TransferController.RecoveryWrite(snapshot, if (receiving) receiverStorage else null, done))
        return done
    }

internal suspend fun TransferController.restoreRecovery(snapshot: TransferCheckpoint, local: String) {
        var saved = snapshot
        val operation = epoch
        val remaining = saved.expiresAt - System.currentTimeMillis()
        if (local != saved.localFingerprint || remaining !in 1..pauseTimeoutMillis) {
            withContext(receiveDispatcher) {
                if (saved.receiving && (saved.stage == 0 || saved.stage == 4)) {
                    val destination = if (saved.tree.isNotEmpty()) TransferDestination(requireNotNull(context), Uri.parse(saved.tree),
                        android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION, saved.treeModes) else null
                    try {
                        if (destination == null) TransferReceiveStorage.discardOwned(File(saved.folder), saved.partial,
                            saved.batch.id, saved.batch.files[saved.index].id)
                        else {
                            val uri = Uri.parse(saved.document)
                            if (destination.ownsPartial(uri, ".anice-${saved.batch.id}-${saved.batch.files[saved.index].id}-")) destination.delete(uri)
                        }
                    } finally { destination?.close() }
                }
                for (file in saved.batch.files.filter { it.ownsReadGrant }) {
                    file.sourceUri?.let { context?.contentResolver?.releasePersistableUriPermission(it,
                        android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                }
                recoveryStore?.clear()
            }
            updateState(TransferState.Failed(if (local != saved.localFingerprint) "Local identity changed. Send the files again."
                else "Transfer paused for too long without a connection. Send the files again."))
            return
        }
        if (saved.stage == 4 && saved.tree.isEmpty()) {
            val file = saved.batch.files[saved.index]
            val published = withContext(receiveDispatcher) { TransferReceiveStorage.published(File(saved.folder), file, saved.fileIdentity) }
            if (published) {
                withContext(receiveDispatcher) { TransferReceiveStorage.discardOwned(File(saved.folder), saved.partial, saved.batch.id, file.id) }
                if (saved.index == saved.batch.files.lastIndex) saved = saved.copy(stage = 3)
                else {
                    val storage = TransferReceiveStorage(File(saved.folder), null, ioDispatcher = receiveDispatcher)
                    val next = saved.index + 1
                    val paths = storage.create(saved.batch.id, saved.batch.files[next].id)
                    if (operation != epoch) { storage.discard(); return }
                    receiverStorage = storage; receiverPartFile = paths.first; receiverPartDocument = paths.second
                    destinationDirectory = File(saved.folder)
                    saved = saved.copy(index = next, offset = 0, stage = 0, partial = paths.first?.absolutePath ?: "")
                }
                withContext(receiveDispatcher) { recoveryStore?.save(saved) }
            }
        }
        if (operation != epoch) return
        val batch = saved.batch
        if (saved.stage == 3) {
            val file = batch.files.last()
            retainedFileResult = TransferController.RetainedResult(batch.id, file.id, file.size,
                TransferMessage.fileResult(batch.id, file.id, 0, file.sha256), saved.peerId, saved.peerFingerprint)
            receiving = true
            retainedBatch = batch
            updateState(TransferState.Completed(batch.id, batch.files.size, batch.totalBytes))
            expireReceipt(batch.id, remaining)
            return
        }
        if (saved.receiving && (saved.stage == 0 || saved.stage == 4) && receiverStorage == null) {
            val folder = File(saved.folder)
            val destination = if (saved.tree.isNotEmpty()) TransferDestination(requireNotNull(context), Uri.parse(saved.tree),
                android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION, saved.treeModes) else null
            val storage = TransferReceiveStorage(folder, destination, ioDispatcher = receiveDispatcher)
            try {
                val paths = storage.restore(batch.id, batch.files[saved.index].id, saved.partial, saved.document, saved.offset)
                receiverStorage = storage; receiverPartFile = paths.first; receiverPartDocument = paths.second
                destinationDirectory = folder; documentDestination = destination
            } catch (error: Exception) { destination?.close(); throw error }
        }
        if (operation != epoch) {
            withContext(NonCancellable + receiveDispatcher) { receiverStorage?.discard(); documentDestination?.close() }
            receiverStorage = null; documentDestination = null
            return
        }
        currentBatch = batch; receiving = saved.receiving
        restoredSender = !saved.receiving
        batch.files.filter { it.ownsReadGrant }.mapNotNullTo(ownedSourceGrants) { it.sourceUri }
        interruptedOffer = when (saved.stage) {
            1 -> TransferState.WaitingForPeerApproval(batch)
            2 -> TransferState.IncomingOffer(batch)
            else -> null
        }
        transferPeerDeviceId = saved.peerId; transferPeerFingerprint = saved.peerFingerprint
        senderFileIndex = saved.index; receiverCurrentFileIndex = saved.index
        acknowledgedBytes = saved.offset; receiverWrittenBytes = saved.offset; sentBytes = saved.offset
        if (saved.receiving && saved.index > 0) {
            val file = batch.files[saved.index - 1]
            retainedFileResult = TransferController.RetainedResult(batch.id, file.id, file.size,
                TransferMessage.fileResult(batch.id, file.id, 0, file.sha256), saved.peerId, saved.peerFingerprint)
        }
        pausedFileIndex = saved.index; pausedFileOffset = saved.offset
        pausedCompletedBytes = batch.files.take(saved.index).sumOf { it.size }
        receiverTotalTransferred = pausedCompletedBytes + saved.offset
        pausedTransport = saved.transport; pauseExpiresAt = saved.expiresAt; pauseDeadline = clock() + remaining
        val file = batch.files[saved.index]
        updateState(TransferState.Paused(batch, saved.index + 1, file.name, saved.offset, file.size,
            pausedCompletedBytes + saved.offset, "Waiting to reconnect", false))
        startPauseTimer()
    }
