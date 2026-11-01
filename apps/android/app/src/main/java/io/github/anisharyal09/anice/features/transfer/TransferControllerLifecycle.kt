// SPDX-License-Identifier: GPL-3.0-or-later
// Cancels transfer jobs and releases their owned resources.
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

internal fun TransferController.cancelTransferFlow(local: Boolean = true) {
        val current = state
        if (local) {
            val batchId = when (current) {
                is TransferState.WaitingForPeerApproval -> current.batch.id
                is TransferState.IncomingOffer -> current.batch.id
                is TransferState.Transferring -> current.batch.id
                is TransferState.Paused -> current.batch.id
                else -> ""
            }
            if (batchId.isNotEmpty()) {
                val cancelMsg = TransferMessage.cancel(batch = batchId, file = "", reason = 0L)
                val channel = activeChannel
                scope.launch { if (channel != null && channels[channel.descriptor.transport] === channel) runCatching { sendWithBackpressure(cancelMsg.encode(), channel, jobBound = false) } }
            }
        }
        retainedFileResult = null
        updateState(TransferState.Cancelled)
        cleanupTransfer()
    }

internal fun TransferController.dismissFlow() {
        receiving = false
        retainedFileResult = null
        updateState(TransferState.Idle)
        cleanupTransfer()
    }

internal fun TransferController.invalidateFlow() {
        val active = isBusy
        retainedFileResult = null
        updateState(if (active) TransferState.Failed("Trust or identity changed. Send the files again after pairing.") else TransferState.Idle)
        cleanupTransfer()
        val operation = epoch
        if (recoveryStore != null) scope.launch {
            try {
                val local = withContext(Dispatchers.IO) { recoveryIdentity() }
                if (operation == epoch) recoveryLocal = local
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { if (operation == epoch) recoveryLocal = null }
        }
    }

internal fun TransferController.failTransfer(reason: String) {
        if (state is TransferState.Completed || state is TransferState.Cancelled) return
        val batch = currentBatch
        val channel = activeChannel
        val file = batch?.files?.getOrNull(receiverCurrentFileIndex)
        if (state !is TransferState.Paused && (receiverPartFile != null || receiverPartDocument != null) &&
            batch != null && file != null && channel != null) {
            val result = TransferMessage.fileResult(batch.id, file.id, 2L, ByteArray(32))
            scope.launch { if (channels[channel.descriptor.transport] === channel) runCatching { sendWithBackpressure(result.encode(), channel, jobBound = false) } }
        }
        retainedFileResult = null
        updateState(TransferState.Failed(reason))
        cleanupTransfer()
    }

internal fun TransferController.cleanupTransfer(selectChannel: Boolean = true) {
        restoredSender = false
        retainedBatch = null; offerReplayed = false
        checkpointAt = 0; checkpointPosition = null
        finalizationRetired = null
        finalizationResumed = false
        receiptExpiry?.cancel(); receiptExpiry = null
        receiptDeadline = null
        val failed = failedRecovery
        failedRecovery = null
        val grants = (ownedSourceGrants + (failed?.batch?.files?.filter { it.ownsReadGrant }?.mapNotNull { it.sourceUri } ?: emptyList())).distinct()
        ownedSourceGrants.clear()
        interruptedOffer = null
        if (recoveryStore != null) recoveryWrites.trySend(TransferController.RecoveryWrite(null, null))
        pauseExpiresAt = null; pauseDeadline = null
        resumeAttemptChannel = null; nextResumeAttemptAt = 0
        recoveryPeer = null
        progressJob?.cancel(); progressJob = null
        progressEpoch = null
        connectTimeoutJob?.cancel()
        connectTimeoutJob = null
        pendingSend = null
        awaitingLan = false
        endPicker()
        destinationPreparation?.cancel(); destinationPreparation = null
        preparation?.cancel(); preparation = null; preparing = false
        clearOfferAssembly()
        pauseTimerJob?.cancel(); pauseTimerJob = null
        resumeJob?.cancel(); resumeJob = null
        upgradeJob?.cancel(); upgradeJob = null
        statusDeferred?.cancel(); statusDeferred = null
        allowBleResume = false
        pausedTransport = null
        pausedFileIndex = 0
        pausedFileOffset = 0L
        pausedCompletedBytes = 0L
        transferPeerDeviceId = null
        transferPeerFingerprint = null
        senderFileIndex = 0
        epoch = UUID.randomUUID()
        // Cancel unsealed work; SecureSession finishes nonce-owned submissions under the old epoch.
        transferJob?.cancel(); transferJob = null
        ackJob?.cancel(); ackJob = null
        synchronized(fileResultLock) {
            fileResultDeferred?.cancel()
            fileResultDeferred = null
            receivedFileResult = null
        }
        currentBatch?.let { retiredBatches.addLast(it.id); if (retiredBatches.size > 32) retiredBatches.removeFirst() }
        currentBatch = null
        destinationDirectory = null
        sendingFile = null
        sendWindow = null
        finalizing = false
        ackTimerJob?.cancel()
        ackTimerJob = null
        receiverCurrentFileIndex = 0
        receiverWrittenBytes = 0L
        lastAckedWrittenBytes = 0L
        val storage = receiverStorage
        val destination = documentDestination
        receiverStorage = null
        receiverPartFile = null
        receiverPartDocument = null
        documentDestination = null
        receiveCleanup = scope.launch(receiveDispatcher) {
            try {
                storage?.discard()
                if (failed?.receiving == true && (failed.stage == 0 || failed.stage == 4)) {
                    if (failed.tree.isEmpty()) TransferReceiveStorage.discardOwned(File(failed.folder), failed.partial,
                        failed.batch.id, failed.batch.files[failed.index].id)
                    else {
                        val target = TransferDestination(requireNotNull(context), Uri.parse(failed.tree),
                            android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION, failed.treeModes)
                        try {
                            val uri = Uri.parse(failed.document)
                            if (target.ownsPartial(uri, ".anice-${failed.batch.id}-${failed.batch.files[failed.index].id}-")) target.delete(uri)
                        } finally { target.close() }
                    }
                }
            }
            catch (error: Exception) { System.err.println("Transfer partial cleanup failed: ${error.javaClass.simpleName}") }
            finally {
                try { destination?.close() }
                catch (error: SecurityException) { System.err.println("Transfer destination grant cleanup failed: ${error.javaClass.simpleName}") }
                for (uri in grants) {
                    try { context?.contentResolver?.releasePersistableUriPermission(uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                    catch (error: SecurityException) { System.err.println("Transfer source grant cleanup failed: ${error.javaClass.simpleName}") }
                }
            }
        }
        resumeCredit()
        clearCapacityWaiters()
        receiverTotalTransferred = 0L
        onLeaseChanged?.invoke(false)
        if (selectChannel) selectPreferredChannel()
    }
