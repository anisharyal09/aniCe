// SPDX-License-Identifier: GPL-3.0-or-later
// Prepares and streams outgoing batches under correlated peer credit.

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

internal fun TransferController.sendUrisFlow(uris: List<Uri>, reviewedPeerDeviceId: String? = null, reviewedPeerFingerprint: String? = null) {
        val resolver = context?.contentResolver ?: run {
            updateState(TransferState.Failed("No context available to resolve files"))
            return
        }
        if ((reviewedPeerDeviceId == null) != (reviewedPeerFingerprint == null)) {
            updateState(TransferState.Failed("The reviewed device identity is incomplete. Review the files again."))
            return
        }
        val reviewedPeer = if (reviewedPeerDeviceId != null && reviewedPeerFingerprint != null)
            reviewedPeerDeviceId to reviewedPeerFingerprint else null
        val operation = epoch
        prepareSources(uris, reviewedPeer = reviewedPeer) { uri ->
            var ownsGrant = false
            if (resolver.persistedUriPermissions.none { it.uri == uri && it.isReadPermission }) {
                try {
                    resolver.takePersistableUriPermission(uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    ownsGrant = true
                } catch (_: SecurityException) {
                    // A provider may grant only this launch; immediate sending still uses that access.
                }
            }
            withContext(dispatcher) {
                if (operation != epoch) {
                    if (ownsGrant) withContext(NonCancellable + Dispatchers.IO) {
                        resolver.releasePersistableUriPermission(uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    throw CancellationException("File selection was cancelled")
                }
                if (ownsGrant) ownedSourceGrants.add(uri)
            }
            var name = ""
            var size = -1L
            resolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    val sizeIndex = cursor.getColumnIndex(android.provider.OpenableColumns.SIZE)
                    if (nameIndex != -1) name = cursor.getString(nameIndex) ?: ""
                    if (sizeIndex != -1 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
                }
            }
            if (name.isEmpty()) name = uri.lastPathSegment ?: "file_${System.currentTimeMillis()}"
            prepareFile(name, size, sourceUri = uri) { resolver.openInputStream(uri) }.copy(ownsReadGrant = ownsGrant)
        }
    }

internal fun <T> TransferController.prepareSources(
        sources: List<T>,
        awaitLan: Boolean = true,
        reviewedPeer: Pair<String, String>? = null,
        prepare: suspend (T) -> TransferFile
    ) {
        if (isBusy) return
        if (state !is TransferState.Connecting) selectPreferredChannel()
        if (sources.isEmpty() || sources.size > 128) {
            updateState(TransferState.Failed("Transfer batch must contain 1 to 128 files"))
            return
        }
        val channel = activeChannel
        if (reviewedPeer != null && (channel?.descriptor?.peer?.deviceId != reviewedPeer.first ||
                channel?.descriptor?.peer?.fingerprint != reviewedPeer.second)) {
            updateState(TransferState.Failed("The connected device changed. Review the selected files before sending."))
            return
        }
        val requestedLan = awaitLan && channel?.descriptor?.transport != "lan" && onDemandLanConnection?.invoke() == true
        // A requested LAN route gets a bounded rendezvous before a ready BLE fallback is used.
        if (requestedLan || channel == null || !peerConnected || !peerCompatible) {
            if (!requestedLan && channel == null) {
                updateState(TransferState.Failed("No secured local-network or Bluetooth connection"))
                return
            }
            awaitingLan = requestedLan
            pendingSend = { prepareSources(sources, awaitLan = false, reviewedPeer = reviewedPeer, prepare = prepare) }
            updateState(TransferState.Connecting("your Mac"))
            onLeaseChanged?.invoke(true)
            connectTimeoutJob?.cancel()
            connectTimeoutJob = scope.launch {
                // A missing LAN-only route keeps the discovery window; a BLE fallback is bounded.
                delay(if (requestedLan && channel == null) 30_000L else 3_000L)
                if (state is TransferState.Connecting) {
                    onLanUnavailable(if (requestedLan) "Could not connect to your Mac over local network. Check Wi-Fi and Allow Connections on your Mac."
                        else "This peer has not advertised file transfer support")
                }
            }
            return
        }
        awaitingLan = false
        if (preparation?.isActive == true || transferJob?.isActive == true) return
        val operation = epoch
        preparing = true
        transferPeerDeviceId = channel.descriptor.peer.deviceId
        transferPeerFingerprint = channel.descriptor.peer.fingerprint
        recoveryPeer = channel.descriptor
        onLeaseChanged?.invoke(true)
        val cleanup = receiveCleanup
        preparation = scope.launch(Dispatchers.IO) {
            try {
                cleanup?.join()
                coroutineContext.ensureActive()
                if (recoveryStore != null) {
                    val local = recoveryIdentity()
                    withContext(dispatcher) {
                        if (operation != epoch) throw CancellationException("Transfer preparation was cancelled")
                        recoveryLocal = local
                    }
                }
                val files = sources.map { coroutineContext.ensureActive(); prepare(it) }
                val totalBytes = files.fold(0L) { total, file -> Math.addExact(total, file.size) }
                withContext(dispatcher) {
                    if (operation == epoch) {
                        preparing = false; preparation = null
                        // Hashing can outlast the rendezvous wait; adopt a LAN channel that became capable meanwhile.
                        if (channels["lan"] != null && capabilities["lan"] != null) selectPreferredChannel()
                        // File preparation may finish after the selected connection has changed.
                        if (reviewedPeer != null && (activeChannel?.descriptor?.peer?.deviceId != reviewedPeer.first ||
                                activeChannel?.descriptor?.peer?.fingerprint != reviewedPeer.second)) {
                            failTransfer("The connected device changed. Review the selected files before sending.")
                            return@withContext
                        }
                        startOfferBatch(files, totalBytes, activeChannel?.takeIf {
                            it.descriptor.peer.deviceId == channel.descriptor.peer.deviceId &&
                                it.descriptor.peer.fingerprint == channel.descriptor.peer.fingerprint
                        } ?: channel)
                    }
                }
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                withContext(dispatcher) { if (operation == epoch) failTransfer("File preparation failed: ${error.message}") }
            } finally {
                withContext(NonCancellable + dispatcher) { if (operation == epoch) { preparing = false; preparation = null } }
            }
        }
    }

internal suspend fun TransferController.prepareFile(name: String, size: Long, sourceFile: File? = null, sourceUri: Uri? = null,
                                    open: () -> java.io.InputStream?): TransferFile {
        if (name.isEmpty() || name.toByteArray(Charsets.UTF_8).size > 255 ||
            '/' in name || '\\' in name || '\u0000' in name || name == "." || name == "..") {
            throw java.io.IOException("Invalid filename: $name")
        }
        if (size < 0) throw java.io.IOException("The provider must supply a known file size: $name")
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(262144)
        var readSize = 0L
        (open() ?: throw java.io.IOException("Cannot read file: $name")).use { stream ->
            while (true) {
                coroutineContext.ensureActive()
                val count = stream.read(buffer)
                if (count < 0) break
                if (count == 0) throw java.io.IOException("Source stream made no progress: $name")
                readSize = Math.addExact(readSize, count.toLong())
                if (readSize > size) throw java.io.IOException("Source size changed: $name")
                digest.update(buffer, 0, count)
            }
        }
        if (readSize != size) throw java.io.IOException("Source size changed: $name")
        return TransferFile(UUID.randomUUID().toString(), name, size, digest.digest(), sourceFile, sourceUri)
    }

internal fun TransferController.startOfferBatch(files: List<TransferFile>, totalBytes: Long, channel: SecuredChannel) {
        val batchId = UUID.randomUUID().toString()
        val batch = TransferBatch(batchId, files, totalBytes, channel.descriptor.peer.deviceName)
        currentBatch = batch
        receiving = false
        transferPeerDeviceId = channel.descriptor.peer.deviceId
        transferPeerFingerprint = channel.descriptor.peer.fingerprint
        retainedFileResult = null
        updateState(TransferState.WaitingForPeerApproval(batch))
        onLeaseChanged?.invoke(true)

        if (activeChannel !== channel) {
            pauseOffer(channel.descriptor, TransferState.WaitingForPeerApproval(batch))
            selectPreferredChannel()
        } else sendOfferBatch(batch, channel)
    }

internal fun TransferController.sendOfferBatch(batch: TransferBatch, channel: SecuredChannel) {
        val files = batch.files
        val batchId = batch.id
        val totalBytes = batch.totalBytes

        val operation = epoch
        // Send offer slices (up to 8 files per slice)
        val totalFiles = files.size.toLong()
        val totalSlices = ((files.size + 7) / 8).toLong()

        scope.launch {
            for (sliceIdx in 0 until totalSlices.toInt()) {
                if (operation != epoch || activeChannel !== channel) return@launch
                val start = sliceIdx * 8
                val end = (start + 8).coerceAtMost(files.size)
                val sliceCbor = files.subList(start, end).map { f ->
                    Cbor.Array(
                        listOf(
                            Cbor.Text(f.id),
                            Cbor.Text(f.name),
                            Cbor.Integer(f.size),
                            Cbor.Bytes(f.sha256)
                        )
                    )
                }
                val offerMsg = TransferMessage.offer(
                    batch = batchId,
                    sliceIndex = sliceIdx.toLong(),
                    totalSlices = totalSlices,
                    totalFiles = totalFiles,
                    totalBytes = totalBytes,
                    files = sliceCbor
                )
                try {
                    sendWithBackpressure(offerMsg.encode())
                } catch (e: Exception) {
                    if (operation == epoch) failTransfer("Failed sending offer: ${e.message}")
                    return@launch
                }
            }
        }
    }

internal fun TransferController.handleAccept(message: TransferMessage) {
        val current = state
        if (current !is TransferState.WaitingForPeerApproval || message.string(0) != current.batch.id) return

        if (transferJob?.isActive == true) return
        val operation = epoch
        val channel = activeChannel ?: return
        if (offerReplayed) {
            offerReplayed = false
            senderFileIndex = 0; acknowledgedBytes = 0; sendingFile = current.batch.files.first()
            val file = current.batch.files.first()
            pauseTransfer(channel.descriptor, TransferState.Transferring(current.batch, 1, file.name, 0, file.size, 0, 0.0))
            selectPreferredChannel()
            return
        }
        transferJob = scope.launch {
            if (operation != epoch || activeChannel !== channel) return@launch
            try { streamAcceptedBatch(current.batch) }
            catch (error: TimeoutCancellationException) { if (operation == epoch) pauseOnConfirmationTimeout() }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) { if (operation == epoch) failTransfer("Source read failed: ${error.message}") }
        }
    }

internal suspend fun TransferController.streamAcceptedBatch(batch: TransferBatch) =
        streamBatchFrom(batch, startFileIndex = 0, startOffset = 0L, completedBefore = 0L)

internal suspend fun TransferController.streamBatchFrom(
        batch: TransferBatch,
        startFileIndex: Int,
        startOffset: Long,
        completedBefore: Long,
        recovered: Boolean = false
    ) {
        if (activeChannel == null) return
        val operation = epoch
        var totalTransferred = completedBefore + startOffset
        var lastUiUpdate = 0L

        for (fileIndex in startFileIndex until batch.files.size) {
            if (operation != epoch) return
            restoredSender = false
            val file = batch.files[fileIndex]
            var initial = if (fileIndex == startFileIndex) startOffset.coerceIn(0L, file.size) else 0L
            senderFileIndex = fileIndex
            sendingFile = file
            sentBytes = initial
            acknowledgedBytes = initial
            updateState(TransferState.Transferring(batch, fileIndex + 1, file.name, initial, file.size,
                totalTransferred, 0.0))
            if ((recovered || file.size == 0L) && fileIndex > startFileIndex) {
                val channel = activeChannel ?: return
                val result = requestStatus(channel, TransferMessage.resume(batch.id, file.id, 0,
                    MessageDigest.getInstance("SHA-256").digest(ByteArray(0))).encode(chunkLimit(channel.descriptor)))
                if (operation != epoch) return
                if (result == null || result.number(3) != 0L || result.number(2) !in 0..file.size) {
                    (state as? TransferState.Transferring)?.let { pauseTransfer(channel.descriptor, it) }
                    return
                }
                initial = result.number(2)
                acknowledgedBytes = initial; sentBytes = initial
                totalTransferred = batch.files.take(fileIndex).sumOf { it.size } + initial
                updateState(TransferState.Transferring(batch, fileIndex + 1, file.name, initial, file.size, totalTransferred, 0.0))
            }
            checkpoint(force = true)?.await()
            if (operation != epoch) return
            val opened = java.util.concurrent.atomic.AtomicReference<java.io.InputStream?>()
            val inputStream = try {
                withContext(Dispatchers.IO) {
                    openSource(file).also { stream ->
                        opened.set(stream)
                        if (initial > 0) skipFully(stream, initial)
                    }
                }
            } catch (error: Exception) {
                withContext(NonCancellable + Dispatchers.IO) { opened.getAndSet(null)?.close() }
                if (error is CancellationException) throw error
                if (operation == epoch) failTransfer("Cannot open ${file.name}: ${error.message}")
                return
            }

            // Opening a provider can suspend across cancellation or replacement of this batch.
            if (operation != epoch) {
                withContext(NonCancellable + Dispatchers.IO) { opened.getAndSet(null)?.close() }
                return
            }
            sendingFile = file
            senderFileIndex = fileIndex
            // A result that arrived just before this file was re-entered belongs to this file.
            synchronized(fileResultLock) {
                val pending = receivedFileResult
                if (pending != null && (pending.string(0) != batch.id || pending.string(1) != file.id)) {
                    receivedFileResult = null
                }
            }
            sentBytes = initial
            acknowledgedBytes = initial
            lastAckAtMillis = null
            val startedAt = clock()
            streamStartedAtMillis = startedAt
            sendWindow = TransferSendWindow(peerMaxChunkBytes, peerMaxWindow,
                activeChannel?.descriptor?.transport == "lan", startedAt)
            if (context != null) android.util.Log.i("aniCe-transfer", "source transport=${activeChannel?.descriptor?.transport} chunk=$senderChunkBytes credit=$sendCreditBytes maxChunk=$peerMaxChunkBytes window=$peerMaxWindow")
            var fileBytesSent = initial
            // A LAN capability that arrived while the previous file was finalizing is retried here,
            // at the new file's start, where the stream is no longer waiting on a file result.
            if (!receiving) channels["lan"]?.let { maybeUpgradeToLan(it.descriptor) }
            var upgradeChecked = false

            try {
                val fis = inputStream
                val buffer = ByteArray(peerMaxChunkBytes.toInt())

                while (fileBytesSent < file.size) {
                    while (true) {
                        val previousChunk = senderChunkBytes
                        val previousCredit = sendCreditBytes
                        sendWindow?.advance()
                        if (context != null && (previousChunk != senderChunkBytes || previousCredit != sendCreditBytes))
                            android.util.Log.i("aniCe-transfer", "send window chunk=$senderChunkBytes credit=$sendCreditBytes")
                        if (hasSendCredit) break
                        val deferred = CompletableDeferred<Unit>().also { creditDeferred = it }
                        if (hasSendCredit) {
                            creditDeferred = null
                        } else {
                            deferred.await()
                        }
                    }

                    if (!coroutineContext.isActive || operation != epoch || activeChannel == null) return

                    val chunkSize = (file.size - fileBytesSent).coerceAtMost(senderChunkBytes).toInt()
                    val limit = chunkLimit(activeChannel?.descriptor)
                    val encoded = try { withContext(Dispatchers.IO) {
                        var filled = 0
                        while (filled < chunkSize) {
                            val count = fis.read(buffer, filled, chunkSize - filled)
                            if (count < 0) break
                            if (count == 0) throw java.io.IOException("Source stream made no progress")
                            filled += count
                        }
                        if (filled != chunkSize) throw java.io.IOException("Source ended before its manifest length")
                        TransferMessage.chunkFrom(batch.id, file.id, fileBytesSent, buffer, chunkSize).encode(limit)
                    } } catch (error: Exception) {
                        if (error is CancellationException) throw error
                        if (operation == epoch) failTransfer("Source read failed: ${error.message}")
                        return
                    }
                    if (operation != epoch) return
                    try {
                        sendWindow?.beginSubmission(clock(), windowEmpty = sentBytes == acknowledgedBytes)
                        sentBytes += chunkSize
                        sendWithBackpressure(encoded)
                        if (operation != epoch) return
                        fileBytesSent += chunkSize
                        totalTransferred += chunkSize

                        val now = clock()
                        if (now - lastUiUpdate >= 100L || fileBytesSent == file.size) {
                            lastUiUpdate = now
                            val confirmed = totalTransferred - fileBytesSent + acknowledgedBytes

                            withContext(dispatcher) {
                                updateState(
                                    TransferState.Transferring(
                                        batch = batch,
                                        fileIndex = fileIndex + 1,
                                        fileName = file.name,
                                        fileBytes = acknowledgedBytes,
                                        fileSize = file.size,
                                        totalBytes = confirmed,
                                        speedBps = 0.0
                                    )
                                )
                            }
                        }
                        if (!upgradeChecked) {
                            upgradeChecked = true
                            if (!receiving) channels["lan"]?.let { maybeUpgradeToLan(it.descriptor) }
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        if (operation == epoch) failTransfer("Failed sending chunk: ${e.message}")
                        return
                    }
                }
            } finally {
                withContext(NonCancellable + Dispatchers.IO) { opened.getAndSet(null)?.close() }
            }

            if (operation != epoch) return
            // Wait for file-result from receiver. Install the waiter in the same critical section
            // that consumes a result which already arrived, so neither ordering can lose it.
            val resultWaiter = CompletableDeferred<TransferMessage>()
            val pendingResult = synchronized(fileResultLock) {
                val pending = receivedFileResult
                receivedFileResult = null
                // A consumed early result must not leave a completed waiter attached to the next file.
                fileResultDeferred = if (pending == null) resultWaiter else null
                pending
            }
            if (pendingResult != null) resultWaiter.complete(pendingResult)
            val fileResult = withTimeout(confirmationTimeoutMillis) { resultWaiter.await() }
            if (operation != epoch) return
            if (fileResult.number(2) != 0L) {
                failTransfer("Receiver reported error for file ${file.name}")
                return
            }
        }

        // All files sent successfully
        val batchResult = TransferMessage.batchResult(batch = batch.id, result = 0L)
        runCatching { sendWithBackpressure(batchResult.encode()) }
        withContext(dispatcher) {
            if (operation != epoch) return@withContext
            updateState(TransferState.Completed(batch.id, batch.files.size, batch.totalBytes))
            cleanupTransfer()
        }
    }

internal fun TransferController.handleAck(message: TransferMessage) {
        val batch = currentBatch ?: return
        val file = sendingFile ?: return
        if (message.string(0) != batch.id || message.string(1) != file.id) return
        val written = message.number(2)
        if (written < acknowledgedBytes || written > sentBytes || written > file.size) return
        if (written > acknowledgedBytes) {
            pauseExpiresAt = null; pauseDeadline = null
            sendWindow?.acknowledged(clock(), fullyConfirmed = written == sentBytes)
        }
        acknowledgedBytes = written
        lastAckAtMillis = clock()
        checkCreditAndResume()
    }

internal fun TransferController.resumeCredit() {
        // Detach before waking: an immediate dispatcher can register the next waiter inline.
        val waiting = creditDeferred
        creditDeferred = null
        waiting?.complete(Unit)
    }

internal fun TransferController.checkCreditAndResume() {
        if (hasSendCredit) resumeCredit()
    }

internal fun TransferController.handleReject(message: TransferMessage) {
        val current = state
        if (current !is TransferState.WaitingForPeerApproval || message.string(0) != current.batch.id) return
        updateState(TransferState.Rejected(current.batch.id, message.number(1)))
        cleanupTransfer()
    }

// MARK: - Credit window

// Reduced LAN chunks need immediate credit to keep the sender's smaller pipeline supplied.
internal fun transferAckThreshold(maximumChunk: Long, maximumWindow: Long, chunkBytes: Long): Long {
    if (maximumChunk <= 3072) return maximumChunk * minOf(8L, maxOf(1L, maximumWindow / 2))
    val chunk = minOf(maximumChunk, chunkBytes)
    return chunk * if (maximumChunk > 4096 && chunk < maximumChunk) 1L else maxOf(1L, maximumWindow / 4)
}

// Bounds unacknowledged LAN bytes before allowing the negotiated high-throughput window.
internal class TransferSendWindow(private val maximumChunk: Long, private val maximumWindow: Long,
    private val lan: Boolean, started: Long) {
    private var probing = lan && maximumChunk > 4096
    private var probeSubmitted = false
    private var constrained = false
    private var lastAcknowledgedAt = started
    private var probeStartedAt = started
    private var reprobe = false
    private var drainRequested = false
    private var draining = false
    private var decision: Boolean? = null
    private var timelySince: Long? = null
    // Sustained fallback amortizes live per-record validation under a 128-KiB fallback backlog cap.
    val chunkBytes get() = when {
        probing -> minOf(4096L, maximumChunk)
        constrained -> minOf(65536L, maximumChunk)
        else -> maximumChunk
    }
    val creditBytes get() = chunkBytes * when {
        probing || draining -> 1L
        constrained -> minOf(2L, maximumWindow)
        else -> maximumWindow
    }
    // Source IO and encoding precede submission and cannot measure the path's acknowledgement delay.
    fun beginSubmission(now: Long, windowEmpty: Boolean = false) {
        if (probing && !probeSubmitted) {
            lastAcknowledgedAt = now
            probeStartedAt = now
            probeSubmitted = true
        } else if (!probing && windowEmpty) {
            if (now - lastAcknowledgedAt > 100) timelySince = null
            lastAcknowledgedAt = now
        }
    }
    // Only advancing, correlated ACKs reach this method; duplicates cannot qualify a fast path.
    fun acknowledged(now: Long, fullyConfirmed: Boolean) {
        if (probing && !fullyConfirmed) return
        val elapsed = now - lastAcknowledgedAt
        if (probing) { if (decision == null) decision = elapsed > 100 }
        else if (constrained) {
            if (elapsed > 100) timelySince = null else if (timelySince == null) timelySince = lastAcknowledgedAt
            // Batched ACK arrivals cannot qualify recovery without a full second of steady progress.
            val stable = timelySince?.let { now - it >= 1000 } == true
            if (draining && fullyConfirmed || stable && now - probeStartedAt >= 5000) {
                if (fullyConfirmed) reprobe = true else drainRequested = true
            }
        }
        else if (lan && maximumChunk > 4096 && elapsed > 1000) decision = true
        lastAcknowledgedAt = now
    }
    // Apply shrinkage between records, never while a previously admitted source read is suspended.
    fun advance() {
        decision?.let { constrained = it; probing = false; timelySince = null }
        decision = null
        // A one-chunk budget drains a continuously replenished two-chunk pipeline before probing.
        if (drainRequested) { draining = true; drainRequested = false }
        if (reprobe) { probing = true; probeSubmitted = false; draining = false; probeStartedAt = lastAcknowledgedAt; reprobe = false }
    }
}

// MARK: - Throughput measurement

/**
 * Reports the rate across the most recent [samples] observations rather than across the whole
 * transfer.
 *
 * A lifetime average (`total / elapsed`) cannot answer "how fast is it going now": it hides a ramp
 * up, keeps reporting a healthy number while the link has stalled, and drags a genuinely fast
 * second file down behind a slow first one. A bounded window decays toward zero when the link
 * stops delivering and reflects the current link again as soon as bytes resume.
 *
 * Samples are cumulative byte counts, so the caller passes the running total it already keeps.
 */
// Twenty intervals at the 250-ms publication cadence span five seconds, including bursty LAN ACKs.
internal class TransferRate(private val samples: Int = 21) {
    init {
        require(samples >= 2) { "A rate needs two observations." }
    }

    private val counts = LongArray(samples)
    private val times = LongArray(samples)
    private var size = 0
    private var next = 0

    /**
     * Records [totalBytes] observed at [at] and returns the rate in bytes per second.
     * Returns `0.0` until two observations exist and whenever the window covers no progress, which
     * callers present as "no rate available" rather than as a measured zero.
     */
    fun add(totalBytes: Long, at: Long): Double {
        counts[next] = totalBytes
        times[next] = at
        next = (next + 1) % samples
        if (size < samples) size++
        if (size < 2) return 0.0
        val oldest = if (size < samples) 0 else next
        val newest = (next - 1 + samples) % samples
        val span = times[newest] - times[oldest]
        val delta = counts[newest] - counts[oldest]
        if (span <= 0L || delta <= 0L) return 0.0
        return delta * 1000.0 / span
    }
}
