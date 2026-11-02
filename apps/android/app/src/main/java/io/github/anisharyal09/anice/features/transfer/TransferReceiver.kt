// SPDX-License-Identifier: GPL-3.0-or-later
// Admits bounded incoming data, writes chunks and publishes verified files.

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
import io.github.anisharyal09.anice.infrastructure.session.SessionTiming
import java.util.ArrayDeque

internal fun TransferController.handleOffer(message: TransferMessage, peerName: String, descriptor: ChannelDescriptor) {
        val sourceChannel = channels[descriptor.transport]?.takeIf { it.descriptor == descriptor } ?: return
        val batchId = message.string(0)
        if (!canonicalTransferUuid(batchId)) return
        if (batchId in retiredBatches && retainedBatch?.id != batchId) return
        val sliceIdx = message.number(1)
        val totalSlices = message.number(2)
        val totalFiles = message.number(3)
        val totalBytes = message.number(4)
        if (totalSlices !in 1L..16L || totalFiles !in 1L..128L || totalBytes < 0L ||
            sliceIdx !in 0 until totalSlices) { clearOfferAssembly(); return }

        val filesCbor = (message.fields.getOrNull(5) as? Cbor.Array)?.value ?: return
        val sliceFiles = mutableListOf<TransferFile>()
        for (f in filesCbor) {
            val row = (f as? Cbor.Array)?.value ?: continue
            if (row.size != 4) continue
            val id = (row[0] as? Cbor.Text)?.value ?: continue
            if (!canonicalTransferUuid(id)) continue
            val name = (row[1] as? Cbor.Text)?.value ?: continue
            val sz = (row[2] as? Cbor.Integer)?.value ?: continue
            val hash = (row[3] as? Cbor.Bytes)?.value ?: continue
            sliceFiles.add(TransferFile(id, name, sz, hash))
        }
        if (sliceFiles.size !in 1..8) { clearOfferAssembly(); return }

        if (offerAssembly?.let { it.batch != batchId } == true) return
        val assembly = offerAssembly ?: TransferController.OfferAssembly(batchId, descriptor.peer.deviceId,
            descriptor.peer.fingerprint, totalSlices, totalFiles, totalBytes).also {
            offerAssembly = it
            offerTimeout = scope.launch { delay(10000); clearOfferAssembly(); selectPreferredChannel() }
        }
        if (assembly.totalSlices != totalSlices || assembly.totalFiles != totalFiles ||
            assembly.totalBytes != totalBytes) { clearOfferAssembly(); return }
        if (assembly.peerId != descriptor.peer.deviceId || assembly.peerFingerprint != descriptor.peer.fingerprint) {
            clearOfferAssembly()
            rejectInvalidOffer(batchId, descriptor)
            return
        }
        val sliceMap = assembly.slices
        sliceMap[sliceIdx]?.let { previous ->
            if (previous != sliceFiles) clearOfferAssembly()
            return
        }
        sliceMap[sliceIdx] = sliceFiles

        if (sliceMap.size.toLong() == totalSlices) {
            val allFiles = mutableListOf<TransferFile>()
            for (i in 0 until totalSlices) {
                allFiles.addAll(sliceMap[i] ?: emptyList())
            }

            var sum = 0L
            for (file in allFiles) {
                if (file.size > Long.MAX_VALUE - sum) { clearOfferAssembly(); return }
                sum += file.size
            }
            if (allFiles.size.toLong() != totalFiles || sum != totalBytes ||
                allFiles.map { it.id }.toSet().size != allFiles.size ||
                allFiles.any { it.size < 0L || it.sha256.size != 32 || !validTransferName(it.name) }) {
                rejectInvalidOffer(batchId, descriptor)
                clearOfferAssembly()
                return
            }
            clearOfferAssembly()
            val batch = TransferBatch(batchId, allFiles, totalBytes, peerName)

            val remembered = currentBatch?.takeIf { it.id == batchId } ?: retainedBatch?.takeIf { it.id == batchId }
            if (remembered != null) {
                if (remembered.files != allFiles || remembered.totalBytes != totalBytes) return
                if (state is TransferState.IncomingOffer || interruptedOffer is TransferState.IncomingOffer) return
                if (receiving && (currentBatch?.id == batchId || retainedBatch?.id == batchId)) {
                    val channel = channels[descriptor.transport] ?: return
                    scope.launch { runCatching { sendWithBackpressure(TransferMessage.accept(batchId, emptyList()).encode(), channel, jobBound = false) } }
                    return
                }
            }

            val isBusy = this.isBusy

            if (isBusy) {
                scope.launch {
                    val reject = TransferMessage.reject(batch = batchId, reason = 3L) // Busy
                    runCatching { sendWithBackpressure(reject.encode(), sourceChannel, jobBound = false) }
                }
                return
            }

            cleanupTransfer(selectChannel = false)
            activeChannel = sourceChannel
            transferPeerDeviceId = descriptor.peer.deviceId
            transferPeerFingerprint = descriptor.peer.fingerprint
            peerConnected = true
            peerCompatible = capabilities[descriptor.transport] != null
            capabilities[descriptor.transport]?.let { applyCapability(it) }
            currentBatch = batch
            updateState(TransferState.IncomingOffer(batch))
            captureAutomaticReceive(batch, descriptor)
        }
    }

private fun validTransferName(name: String): Boolean = name.toByteArray(Charsets.UTF_8).size in 1..255 &&
    name == name.trim() && name != "." && name != ".." && '/' !in name && '\\' !in name &&
    name.none { Character.isISOControl(it) }

private fun canonicalTransferUuid(value: String): Boolean = value.length == 36 &&
    runCatching { UUID.fromString(value).toString().equals(value, ignoreCase = true) }.getOrDefault(false)

private fun TransferController.rejectInvalidOffer(batchId: String, descriptor: ChannelDescriptor) {
    val channel = channels[descriptor.transport]?.takeIf { it.descriptor == descriptor } ?: return
    scope.launch {
        runCatching { sendWithBackpressure(TransferMessage.reject(batchId, 4L).encode(), channel, jobBound = false) }
    }
}

private fun TransferController.captureAutomaticReceive(batch: TransferBatch, descriptor: ChannelDescriptor) {
    val peer = descriptor.peer
    if (peer.platform != "macos" || !autoReceivePreferences.enabled(peer)) {
        pendingAutomaticReceive = null
        automaticReceiveNeedsApp = false
        return
    }
    // Freeze consent and destination when the complete, sender-pinned offer is admitted; edits apply to later offers.
    pendingAutomaticReceive = PendingAutomaticReceive(
        batchId = batch.id,
        peer = peer,
        destination = destinationPreferences?.selection() ?: TransferReceiveDestinationSelection(null, 0),
    )
    automaticReceiveNeedsApp = !canAutomaticallyReceive() || context == null || destinationPreferences == null
    if (automaticReceiveNeedsApp) onStateChanged?.invoke(state)
    else startAutomaticReceiveIfEligible()
}

internal fun TransferController.startAutomaticReceiveIfEligible() {
    val pending = pendingAutomaticReceive ?: return
    val incoming = state as? TransferState.IncomingOffer ?: return
    if (incoming.batch.id != pending.batchId) return
    // Incoming offers alone cannot start Android background work; retain them until existing app ownership allows receipt.
    if (!canAutomaticallyReceive()) {
        automaticReceiveNeedsApp = true
        onStateChanged?.invoke(state)
        return
    }
    val activePeer = activeChannel?.descriptor?.peer
    if (activePeer?.deviceId != pending.peer.deviceId || activePeer.fingerprint != pending.peer.fingerprint) {
        automaticReceiveNeedsApp = true
        onStateChanged?.invoke(state)
        return
    }
    if (destinationPreparation?.isActive == true) return

    val ctx = context
    val preferences = destinationPreferences
    if (ctx == null || preferences == null) {
        automaticReceiveNeedsApp = true
        onStateChanged?.invoke(state)
        return
    }
    automaticReceiveNeedsApp = false
    destinationMessage = "Preparing receive folder…"
    val operation = epoch
    destinationPreparation = scope.launch {
        var destination: TransferReceiveDestination? = null
        try {
            destination = withContext(receiveDispatcher) {
                preferences.create(pending.destination).also { target ->
                    try { target.preflight(incoming.batch.totalBytes) }
                    catch (error: Exception) { target.close(); throw error }
                }
            }
            if (operation != epoch || (state as? TransferState.IncomingOffer)?.batch?.id != pending.batchId ||
                !canAutomaticallyReceive()) {
                withContext(NonCancellable + receiveDispatcher) { destination?.close() }
                if (operation == epoch && pendingAutomaticReceive?.batchId == pending.batchId) {
                    automaticReceiveNeedsApp = true
                    destinationMessage = null
                    onStateChanged?.invoke(state)
                }
                return@launch
            }
            documentDestination = destination
            destination = null
            pendingAutomaticReceive = null
            automaticReceiveNeedsApp = false
            destinationMessage = null
            acceptIncomingOfferFlow(File(ctx.filesDir, "unused-document-destination"))
        } catch (error: CancellationException) {
            withContext(NonCancellable + receiveDispatcher) { destination?.close() }
            throw error
        } catch (error: Exception) {
            withContext(NonCancellable + receiveDispatcher) { destination?.close() }
            if (operation == epoch && (state as? TransferState.IncomingOffer)?.batch?.id == pending.batchId) {
                pendingAutomaticReceive = null
                automaticReceiveNeedsApp = false
                destinationMessage = error.message ?: "Choose another folder or reset to Downloads/aniCe."
                onStateChanged?.invoke(state)
            }
        }
    }
}

internal fun TransferController.deferAutomaticReceiveIfNeeded() {
    val pending = pendingAutomaticReceive ?: return
    if ((state as? TransferState.IncomingOffer)?.batch?.id != pending.batchId) return
    if (destinationPreparation?.isActive == true) {
        destinationPreparation?.cancel()
        destinationPreparation = null
        destinationMessage = null
    }
    automaticReceiveNeedsApp = true
    onStateChanged?.invoke(state)
}

internal fun TransferController.clearOfferAssembly() {
        offerTimeout?.cancel(); offerTimeout = null
        offerAssembly = null
    }

internal fun TransferController.acceptIncomingOfferFlow(tree: Uri, modes: Int) {
        val ctx = context ?: return
        val current = state as? TransferState.IncomingOffer ?: return
        if (destinationPreparation?.isActive == true) return
        pendingAutomaticReceive = null
        automaticReceiveNeedsApp = false
        val operation = epoch
        onLeaseChanged?.invoke(true)
        destinationPreparation = scope.launch {
            val owned = java.util.concurrent.atomic.AtomicReference<TransferDestination?>()
            var destination: TransferDestination? = null
            try {
                receiveCleanup?.join()
                if (operation != epoch) return@launch
                destination = withContext(receiveDispatcher) {
                    TransferDestination(ctx, tree, modes).also { target ->
                        owned.set(target)
                        try { target.preflight(current.batch.totalBytes) }
                        catch (error: Exception) { target.close(); throw error }
                    }
                }
                if (operation != epoch || activeChannel == null) { withContext(NonCancellable + receiveDispatcher) { destination.close() }; return@launch }
                documentDestination = destination
                owned.set(null)
                acceptIncomingOffer(File(ctx.filesDir, "unused-document-destination"))
            } catch (error: CancellationException) { withContext(NonCancellable + receiveDispatcher) { owned.getAndSet(null)?.close() }; throw error }
            catch (error: Exception) {
                withContext(NonCancellable + receiveDispatcher) { owned.getAndSet(null)?.close() }
                if (operation == epoch) failTransfer("Cannot use this folder: ${error.message}. Choose another local folder.")
            }
        }
    }

internal suspend fun TransferController.acceptIncomingOfferFlow(destinationDir: File) {
        val current = state
        val channel = activeChannel ?: return
        if (current !is TransferState.IncomingOffer) return
        pendingAutomaticReceive = null
        automaticReceiveNeedsApp = false
        val operation = epoch
        if (recoveryStore != null) {
            try {
                val local = withContext(Dispatchers.IO) { recoveryIdentity() }
                if (operation != epoch) return
                recoveryLocal = local
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) { if (operation == epoch) failTransfer("Cannot access transfer recovery identity: ${error.message}"); return }
        }

        destinationDirectory = destinationDir
        receiving = true
        transferPeerDeviceId = channel.descriptor.peer.deviceId
        transferPeerFingerprint = channel.descriptor.peer.fingerprint
        retainedFileResult = null
        receiveCleanup?.join()
        if (operation != epoch) return
        receiverCurrentFileIndex = 0
        receiverWrittenBytes = 0L
        receiverTotalTransferred = 0L
        lastAckedWrittenBytes = 0L
        lastReceiverUiUpdate = 0L

        try { prepareReceiverForFile(0, current.batch) }
        catch (error: java.io.IOException) { failTransfer("Cannot create destination: ${error.message}"); return }
        if (operation != epoch || activeChannel !== channel) return
        updateState(
            TransferState.Transferring(
                batch = current.batch,
                fileIndex = 1,
                fileName = current.batch.files[0].name,
                fileBytes = 0L,
                fileSize = current.batch.files[0].size,
                totalBytes = 0L,
                speedBps = 0.0
            )
        )

        onLeaseChanged?.invoke(true)
        scope.launch {
            if (operation != epoch || activeChannel !== channel) return@launch
            val accept = TransferMessage.accept(batch = current.batch.id, files = emptyList())
            try {
                sendWithBackpressure(accept.encode(), channel)
                if (operation == epoch && current.batch.files[0].size == 0L) finalizeReceiverFile(current.batch)
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) { if (operation == epoch) failTransfer("Failed accepting offer: ${error.message}") }
        }
    }

internal fun TransferController.rejectIncomingOfferFlow(reason: Long = 0L) {
        val current = state
        val channel = activeChannel ?: return
        if (current !is TransferState.IncomingOffer) return
        pendingAutomaticReceive = null
        automaticReceiveNeedsApp = false

        scope.launch {
            val reject = TransferMessage.reject(batch = current.batch.id, reason = reason)
            runCatching { sendWithBackpressure(reject.encode(), channel, jobBound = false) }
        }
        updateState(TransferState.Idle)
        cleanupTransfer()
    }

internal suspend fun TransferController.prepareReceiverForFile(index: Int, batch: TransferBatch) {
        val destDir = destinationDirectory ?: return
        if (index !in batch.files.indices) return
        val file = batch.files[index]

        receiverCurrentFileIndex = index
        receiverWrittenBytes = 0L
        lastAckedWrittenBytes = 0L
        receiverAckChunkBytes = 3072L
        val operation = epoch
        val storage = TransferReceiveStorage(destDir, documentDestination, ioDispatcher = receiveDispatcher)
        try {
            val (partial, document) = storage.create(batch.id, file.id)
            if (operation != epoch) { storage.discard(); throw SessionException(SessionFailure.CANCELLED) }
            receiverStorage = storage
            receiverPartFile = partial
            receiverPartDocument = document
        } catch (error: Exception) { withContext(NonCancellable) { storage.discard() }; throw error }
    }

internal fun TransferController.scheduleAckTimer() {
        if (ackTimerJob?.isActive == true) return
        ackTimerJob = scope.launch {
            delay(20)
            ackTimerJob = null
            flushAck()
        }
    }

internal fun TransferController.flushAck() {
        if (finalizing || ackJob?.isActive == true) return
        val current = state as? TransferState.Transferring ?: return
        val batch = current.batch
        val fileIndex = receiverCurrentFileIndex
        if (fileIndex !in batch.files.indices) return
        val currentFile = batch.files[fileIndex]
        val bytesToAck = receiverWrittenBytes
        if (bytesToAck <= lastAckedWrittenBytes && bytesToAck != currentFile.size) return

        val operation = epoch
        val channel = activeChannel ?: return
        ackJob = scope.launch {
            if (operation != epoch || activeChannel !== channel) return@launch
            var submitted = false
            try {
                val ack = TransferMessage.ack(batch = batch.id, file = currentFile.id, written = bytesToAck)
                sendWithBackpressure(ack.encode(), channel)
                submitted = true
                withContext(dispatcher) {
                    if (operation != epoch || receiverCurrentFileIndex != fileIndex) return@withContext
                    lastAckedWrittenBytes = maxOf(lastAckedWrittenBytes, bytesToAck)
                            }
            } catch (_: Exception) {
                // Retried on next flushAck or capacityAvailable
            } finally {
                withContext(dispatcher) {
                    if (operation != epoch || receiverCurrentFileIndex != fileIndex) return@withContext
                    ackJob = null
                    val unacked = receiverWrittenBytes - lastAckedWrittenBytes
                    val ackThreshold = transferAckThreshold(peerMaxChunkBytes, peerMaxWindow, receiverAckChunkBytes)
                    // Failure waits for an external event; only success may drain newer credit.
                    if (submitted && (unacked >= ackThreshold || (receiverWrittenBytes == currentFile.size && receiverWrittenBytes > lastAckedWrittenBytes))) {
                        flushAck()
                    } else if (submitted && unacked > 0) {
                        // A coalescing timer may have expired while this ACK was still submitting.
                        scheduleAckTimer()
                    }
                }
            }
        }
    }

internal suspend fun TransferController.handleChunk(message: TransferMessage): DataHandling {
        val current = state as? TransferState.Transferring ?: return DataHandling.DISCARDED
        if (destinationDirectory == null) return DataHandling.DISCARDED
        val storage = receiverStorage ?: return DataHandling.DISCARDED
        if (receiverPartFile == null && receiverPartDocument == null) return DataHandling.DISCARDED

        val fileId = message.string(1)
        val offset = message.number(2)
        val data = message.bytes(3)

        if (receiverCurrentFileIndex !in current.batch.files.indices) return DataHandling.DISCARDED
        val currentFile = current.batch.files[receiverCurrentFileIndex]
        if (currentFile.id != fileId || offset != receiverWrittenBytes) return DataHandling.DISCARDED

        if (message.string(0) != current.batch.id || data.size > chunkLimit(activeChannel?.descriptor) || data.size.toLong() > currentFile.size - receiverWrittenBytes) return DataHandling.DISCARDED
        val operation = epoch
        try { storage.write(data) }
        catch (error: java.io.IOException) { if (operation == epoch) failTransfer("Destination write failed: ${error.message}"); return DataHandling.DISCARDED }
        if (operation != epoch || receiverStorage !== storage) return DataHandling.DISCARDED
        pauseExpiresAt = null; pauseDeadline = null
        receiverWrittenBytes += data.size
        receiverTotalTransferred += data.size
        receiverAckChunkBytes = data.size.toLong()

        val now = clock()
        if (now - lastReceiverUiUpdate >= 100L || receiverWrittenBytes == currentFile.size) {
            lastReceiverUiUpdate = now

            updateState(
                TransferState.Transferring(
                    batch = current.batch,
                    fileIndex = receiverCurrentFileIndex + 1,
                    fileName = currentFile.name,
                    fileBytes = receiverWrittenBytes,
                    fileSize = currentFile.size,
                    totalBytes = receiverTotalTransferred,
                    speedBps = 0.0
                )
            )
        }

        val unacked = receiverWrittenBytes - lastAckedWrittenBytes
        val ackThreshold = transferAckThreshold(peerMaxChunkBytes, peerMaxWindow, receiverAckChunkBytes)
        if (unacked >= ackThreshold || receiverWrittenBytes == currentFile.size) {
            flushAck()
        } else if (receiverWrittenBytes > lastAckedWrittenBytes) {
            scheduleAckTimer()
        }

        if (receiverWrittenBytes == currentFile.size) finalizeReceiverFile(current.batch)
        return DataHandling.HANDLED
    }

internal suspend fun TransferController.finalizeReceiverFile(batch: TransferBatch) = withContext(NonCancellable) {
        finalizeReceiverFileOwned(batch)
    }

internal suspend fun TransferController.finalizeReceiverFileOwned(batch: TransferBatch) {
        if (finalizing) return
        val file = batch.files.getOrNull(receiverCurrentFileIndex) ?: return
        val storage = receiverStorage ?: return
        val partial = receiverPartFile
        val document = receiverPartDocument
        if (partial == null && document == null) return
        val destination = destinationDirectory ?: return
        finalizing = true
        finalizationResumed = false
        val operation = epoch
        ackTimerJob?.cancel(); ackTimerJob = null
        // Hashing and publication move no further bytes, so the last measured rate is stale. Both
        // receivers present a zero rate as "no rate available" while the file is being saved.
        (state as? TransferState.Transferring)?.let {
            updateState(
                TransferState.Transferring(
                    it.batch, it.fileIndex, it.fileName, it.fileBytes, it.fileSize, it.totalBytes, 0.0
                )
            )
        }
        val digest = try {
            checkpoint(force = true, publishingIdentity = storage.fileIdentity())?.await()
            if (operation != epoch || receiverStorage !== storage) return
            storage.finish(file.name, file.sha256)
        } catch (error: Exception) {
            if (operation == epoch) { finalizing = false; failTransfer("File verification or finalization failed: ${error.message}") }
            return
        }
        if (operation != epoch || receiverStorage !== storage) return
        val result = TransferMessage.fileResult(batch.id, file.id, 0L, digest)
        // Kept across completion so a resume that lands after the last chunk can still be answered.
        retainedFileResult = TransferController.RetainedResult(batch.id, file.id, file.size, result,
            requireNotNull(transferPeerDeviceId), requireNotNull(transferPeerFingerprint))
        receiverPartDocument = null
        receiverPartFile = null
        receiverStorage = null
        scope.launch {
            try {
                ackJob?.join()
                if (operation != epoch) return@launch
                val next = receiverCurrentFileIndex + 1
                if (next < batch.files.size) {
                    prepareReceiverForFile(next, batch)
                    updateState(TransferState.Transferring(batch, next + 1, batch.files[next].name, 0L,
                        batch.files[next].size, receiverTotalTransferred, 0.0))
                }
                val lost = finalizationRetired
                if (lost != null && (!finalizationResumed || activeChannel == null)) {
                    finalizationRetired = null; finalizing = false
                    if (next == batch.files.size) completeReceiver(batch)
                    else (state as? TransferState.Transferring)?.let { pauseTransfer(lost, it); selectPreferredChannel() }
                    return@launch
                }
                finalizationRetired = null
                sendWithBackpressure(result.encode())
                if (operation != epoch) return@launch
                finalizing = false
                if (next < batch.files.size) {
                    if (receiverWrittenBytes == batch.files[next].size) finalizeReceiverFile(batch)
                } else {
                    sendWithBackpressure(TransferMessage.batchResult(batch.id, 0L).encode())
                    if (operation != epoch) return@launch
                    completeReceiver(batch)
                }
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                if (operation != epoch) return@launch
                val lost = finalizationRetired
                if (lost != null && retainedFileResult?.fileId == batch.files.last().id) {
                    finalizationRetired = null; finalizing = false
                    completeReceiver(batch)
                } else if (lost != null && receiverStorage != null) {
                    finalizationRetired = null; finalizing = false
                    (state as? TransferState.Transferring)?.let { pauseTransfer(lost, it); selectPreferredChannel() }
                } else failTransfer("Completion delivery failed: ${error.message}")
            }
        }
    }

internal fun TransferController.completeReceiver(batch: TransferBatch) {
        val peer = activeChannel?.descriptor ?: recoveryPeer
        val saved = recoveryLocal?.let { local -> peer?.let {
            TransferCheckpoint(local, it.peer.deviceId, it.peer.fingerprint, batch, true,
                batch.files.lastIndex, batch.files.last().size, "", "", "", "", it.transport,
                System.currentTimeMillis() + pauseTimeoutMillis, 3)
        } }
        updateState(TransferState.Completed(batch.id, batch.files.size, batch.totalBytes))
        cleanupTransfer()
        retainedBatch = batch
        if (saved != null) recoveryWrites.trySend(TransferController.RecoveryWrite(saved, null))
        expireReceipt(batch.id, pauseTimeoutMillis)
    }

internal fun TransferController.expireReceipt(batchId: String, remaining: Long) {
        receiptExpiry?.cancel()
        receiptDeadline = clock() + remaining
        receiptExpiry = scope.launch {
            delay(remaining)
            if (retainedFileResult?.batchId == batchId && currentBatch == null) {
                retainedFileResult = null; retainedBatch = null; receiptDeadline = null
                if (recoveryStore != null) recoveryWrites.trySend(TransferController.RecoveryWrite(null, null))
            }
        }
    }

// MARK: - Bounded ingress

internal class TransferIngress(private val scope: CoroutineScope, private val consume: suspend (ChannelDescriptor, UUID, ByteArray) -> Unit) {
    private data class Entry(val descriptor: ChannelDescriptor, val epoch: UUID, val bytes: ByteArray)
    private val pending = ArrayDeque<Entry>()
    private val waiters = mutableListOf<CompletableDeferred<Unit>>()
    private var worker: Job? = null
    private var active: ChannelDescriptor? = null
    private var count = 0
    private var bytes = 0
    // Accounting includes the active write: removing it from FIFO does not release its capacity.
    suspend fun enqueue(descriptor: ChannelDescriptor, epoch: UUID, data: ByteArray, byteLimit: Int, recordLimit: Int, live: () -> Boolean): Boolean {
        if (data.size > byteLimit) return false
        val started = SessionTiming.start()
        while (live() && scope.isActive) {
            currentCoroutineContext().ensureActive()
            if (count < recordLimit && bytes <= byteLimit - data.size) {
                if (started != 0L) SessionTiming.end(this, "transfer_ingress_admission", started,
                    data.size, if (descriptor.maximumDataBytes > 4000) 3 else 1, "receive")
                pending.add(Entry(descriptor, epoch, data)); count++; bytes += data.size
                startWorker()
                return true
            }
            awaitChange()
        }
        return false
    }
    private fun startWorker() {
        if (worker != null || pending.isEmpty() || !scope.isActive) return
        worker = scope.launch(start = CoroutineStart.LAZY) { run() }
        worker!!.start()
    }
    private suspend fun run() {
        try {
            while (currentCoroutineContext().isActive && pending.isNotEmpty()) {
                val next = pending.removeFirst()
                active = next.descriptor
                val started = SessionTiming.start()
                try { consume(next.descriptor, next.epoch, next.bytes) }
                finally {
                    if (started != 0L) SessionTiming.end(this, "transfer_ingress_delivery", started,
                        next.bytes.size, if (next.descriptor.maximumDataBytes > 4000) 3 else 1, "receive")
                    active = null; count--; bytes -= next.bytes.size; wake()
                }
            }
        } finally { worker = null; startWorker(); wake() }
    }
    fun invalidate(descriptor: ChannelDescriptor? = null) {
        val iterator = pending.iterator()
        while (iterator.hasNext()) {
            val next = iterator.next()
            if (descriptor == null || next.descriptor == descriptor) {
                iterator.remove(); count--; bytes -= next.bytes.size
            }
        }
        // Cancel a storage dispatch that has not begun; an already-running blocking write may finish.
        if (active != null && (descriptor == null || active == descriptor)) worker?.cancel()
        wake()
    }
    suspend fun drain(descriptor: ChannelDescriptor? = null) {
        while (if (descriptor == null) count > 0 else active == descriptor || pending.any { it.descriptor == descriptor }) awaitChange()
    }
    private suspend fun awaitChange() {
        val waiter = CompletableDeferred<Unit>()
        waiters.add(waiter)
        try { waiter.await() } finally { waiters.remove(waiter) }
    }
    private fun wake() { waiters.toList().forEach { it.complete(Unit) } }
}

internal fun TransferController.acceptSavedIncomingOfferFlow() {
    val ctx = context ?: return
    val current = state as? TransferState.IncomingOffer ?: return
    if (destinationPreparation?.isActive == true) return
    pendingAutomaticReceive = null
    automaticReceiveNeedsApp = false
    val selection = destinationPreferences?.selection()
        ?: run { destinationMessage = "Receive settings are unavailable."; return }
    destinationMessage = "Preparing receive folder…"
    val operation = epoch
    onLeaseChanged?.invoke(true)
    destinationPreparation = scope.launch {
        var destination: TransferReceiveDestination? = null
        try {
            receiveCleanup?.join()
            if (operation != epoch) return@launch
            destination = withContext(receiveDispatcher) {
                val preferences = destinationPreferences ?: throw java.io.IOException("Receive settings are unavailable.")
                val target = preferences.create(selection)
                try { target.preflight(current.batch.totalBytes); target }
                catch (error: Exception) { target.close(); throw error }
            }
            if (operation != epoch || activeChannel == null || state !is TransferState.IncomingOffer) {
                withContext(NonCancellable + receiveDispatcher) { destination.close() }
                if (operation == epoch) onLeaseChanged?.invoke(false)
                return@launch
            }
            documentDestination = destination
            destinationMessage = null
            acceptIncomingOfferFlow(File(ctx.filesDir, "unused-document-destination"))
        } catch (error: CancellationException) {
            withContext(NonCancellable + receiveDispatcher) { destination?.close() }
            if (operation == epoch) onLeaseChanged?.invoke(false)
            throw error
        } catch (error: Exception) {
            withContext(NonCancellable + receiveDispatcher) { destination?.close() }
            if (operation == epoch) {
                destinationMessage = error.message ?: "Choose another folder or reset to Downloads/aniCe."
                onLeaseChanged?.invoke(false)
            }
        }
    }
}

internal fun TransferController.saveReceiveDestinationFlow(tree: Uri, modes: Int) {
    val ctx = context ?: return
    if (state is TransferState.Transferring || state is TransferState.Paused) {
        destinationMessage = "Finish the current transfer before changing its destination."
        return
    }
    val preferences = destinationPreferences ?: return
    val flags = modes and (android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
    if (flags != (android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION)) {
        destinationMessage = "The selected folder must grant read and write access."
        return
    }
    destinationMessage = "Checking folder…"
    destinationPreparation?.cancel()
    destinationPreparation = scope.launch {
        val resolver = ctx.contentResolver
        val oldTree = runCatching { preferences.storedTree() }.getOrNull()
        val oldModes = preferences.savedModes()
        val previous = resolver.persistedUriPermissions.firstOrNull { it.uri == tree }?.let {
            (if (it.isReadPermission) android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION else 0) or
                (if (it.isWritePermission) android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
        } ?: 0
        val newlyOwned = flags and previous.inv()
        var retained = false
        try {
            resolver.takePersistableUriPermission(tree, flags)
            withContext(receiveDispatcher) {
                val target = TransferDestination(ctx, tree, flags, restoredOwnedModes = 0)
                try { target.preflight(0) } finally { target.close() }
            }
            preferences.save(tree, flags)
            retained = true
            if (oldTree != null && oldTree != tree) {
                runCatching { resolver.releasePersistableUriPermission(oldTree, oldModes) }
            }
            destinationMessage = "Incoming files will be saved to the selected folder."
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) {
            destinationMessage = "Cannot use this folder: ${error.message ?: "choose another local folder."}"
        } finally {
            if (!retained && newlyOwned != 0) {
                runCatching { resolver.releasePersistableUriPermission(tree, newlyOwned) }
            }
        }
    }
}

internal fun TransferController.resetReceiveDestinationFlow() {
    val ctx = context ?: return
    if (state is TransferState.Transferring || state is TransferState.Paused) {
        destinationMessage = "Finish the current transfer before changing its destination."
        return
    }
    val preferences = destinationPreferences ?: return
    val modes = preferences.savedModes()
    val tree = preferences.reset()
    if (tree != null && modes != 0) runCatching { ctx.contentResolver.releasePersistableUriPermission(tree, modes) }
    destinationMessage = "Incoming files will be saved to Downloads/aniCe."
}
