// SPDX-License-Identifier: GPL-3.0-or-later
// Coordinates bidirectional file transfer batches, cumulative flow control and lifecycle leases over authenticated LAN.
package io.github.anisharyal09.anice.features.transfer

import android.content.Context
import android.net.Uri
import android.os.SystemClock
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
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID

data class TransferFile(
    val id: String,
    val name: String,
    val size: Long,
    val sha256: ByteArray,
    val sourceFile: File? = null,
    val sourceUri: Uri? = null
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is TransferFile) return false
        return id == other.id && name == other.name && size == other.size && sha256.contentEquals(other.sha256)
    }

    override fun hashCode(): Int {
        var result = id.hashCode()
        result = 31 * result + name.hashCode()
        result = 31 * result + size.hashCode()
        result = 31 * result + sha256.contentHashCode()
        return result
    }
}

data class TransferBatch(
    val id: String,
    val files: List<TransferFile>,
    val totalBytes: Long,
    val peerName: String
)

sealed interface TransferState {
    data object Idle : TransferState
    data class Connecting(val peerName: String) : TransferState
    data class WaitingForPeerApproval(val batch: TransferBatch) : TransferState
    data class IncomingOffer(val batch: TransferBatch) : TransferState
    data class Transferring(
        val batch: TransferBatch,
        val fileIndex: Int,
        val fileName: String,
        val fileBytes: Long,
        val fileSize: Long,
        val totalBytes: Long,
        val speedBps: Double
    ) : TransferState
    data class Completed(val batchId: String, val fileCount: Int, val totalBytes: Long) : TransferState
    data class Rejected(val batchId: String, val reason: Long) : TransferState
    data class Failed(val reason: String) : TransferState
    data object Cancelled : TransferState
}

class TransferController(
    private val context: Context? = null,
    private val dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
    private val clock: () -> Long = { System.nanoTime() / 1_000_000L }
) : FeatureHandler {

    var state by mutableStateOf<TransferState>(TransferState.Idle); private set
    var peerConnected by mutableStateOf(false); private set
    var onLeaseChanged: ((Boolean) -> Unit)? = null
    var onStateChanged: ((TransferState) -> Unit)? = null

    val isBusy: Boolean
        get() = state is TransferState.Connecting ||
                state is TransferState.WaitingForPeerApproval ||
                state is TransferState.IncomingOffer ||
                state is TransferState.Transferring

    var onDemandLanConnection: (() -> Boolean)? = null
    private var pendingUrisToSend: List<Uri> = emptyList()
    private var pendingFilesToSend: List<File> = emptyList()
    private var connectTimeoutJob: Job? = null

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private var activeChannel: SecuredChannel? = null
    private var transferJob: Job? = null

    private var peerMaxChunkBytes: Long = 3072L
    private var peerMaxWindow: Long = 64L

    // Sender flow control & backpressure
    @Volatile private var sentBytes: Long = 0L
    @Volatile private var acknowledgedBytes: Long = 0L
    @Volatile private var creditDeferred: CompletableDeferred<Unit>? = null
    private val capacityWaiters = java.util.concurrent.ConcurrentLinkedQueue<CompletableDeferred<Unit>>()
    @Volatile private var fileResultDeferred: CompletableDeferred<TransferMessage>? = null
    @Volatile private var receivedFileResult: TransferMessage? = null

    // Receiver state
    private val bufferedOfferSlices = mutableMapOf<String, MutableMap<Long, List<TransferFile>>>()
    private val expectedSlices = mutableMapOf<String, Long>()
    private val totalBatchFiles = mutableMapOf<String, Long>()
    private val totalBatchBytes = mutableMapOf<String, Long>()
    private var destinationDirectory: File? = null
    private var receiverCurrentFileIndex = 0
    private var receiverPartFile: File? = null
    private var receiverFileOutputStream: FileOutputStream? = null
    private var receiverDigest: MessageDigest = MessageDigest.getInstance("SHA-256")
    private var receiverWrittenBytes: Long = 0L
    private var lastAckedWrittenBytes: Long = 0L
    private var unackedChunksCount = 0
    private var ackJob: Job? = null
    private var ackTimerJob: Job? = null
    private var receiverStartTime: Long = 0L
    private var lastReceiverUiUpdate: Long = 0L

    private fun updateState(newState: TransferState) {
        state = newState
        onStateChanged?.invoke(newState)
    }

    override fun available(channel: SecuredChannel) {
        if (channel.descriptor.transport != "lan") return
        activeChannel = channel
        peerConnected = true
        connectTimeoutJob?.cancel()
        connectTimeoutJob = null
        scope.launch {
            val cap = TransferMessage.capability()
            runCatching { sendWithBackpressure(cap.encode()) }
            if (pendingUrisToSend.isNotEmpty()) {
                val toSend = pendingUrisToSend
                pendingUrisToSend = emptyList()
                sendUris(toSend)
            } else if (pendingFilesToSend.isNotEmpty()) {
                val toSend = pendingFilesToSend
                pendingFilesToSend = emptyList()
                sendFiles(toSend)
            }
        }
    }

    override fun retired(descriptor: ChannelDescriptor) {
        if (descriptor.transport != "lan") return
        activeChannel = null
        peerConnected = false
        creditDeferred?.complete(Unit)
        creditDeferred = null
        clearCapacityWaiters()
        ackJob?.cancel()
        ackJob = null
        ackTimerJob?.cancel()
        ackTimerJob = null
        if (state is TransferState.Connecting) {
            connectTimeoutJob?.cancel()
            connectTimeoutJob = null
            pendingUrisToSend = emptyList()
            pendingFilesToSend = emptyList()
            updateState(TransferState.Failed("Local-network connection cancelled or unavailable"))
        } else when (state) {
            is TransferState.Transferring -> failTransfer("LAN connection closed during transfer")
            is TransferState.WaitingForPeerApproval -> {
                updateState(TransferState.Failed("LAN connection closed while waiting for peer approval"))
                cleanupTransfer()
            }
            else -> {}
        }
    }

    private fun clearCapacityWaiters() {
        while (true) {
            val waiter = capacityWaiters.poll() ?: break
            waiter.complete(Unit)
        }
    }

    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        if (descriptor.transport != "lan") return
        clearCapacityWaiters()
        checkCreditAndResume()
        flushAck()
    }

    private suspend fun sendWithBackpressure(data: ByteArray) {
        val channel = activeChannel ?: throw SessionException(SessionFailure.CANCELLED)
        while (coroutineContext.isActive && activeChannel != null) {
            try {
                channel.sendData(data)
                return
            } catch (_: SessionBackpressure) {
                val deferred = CompletableDeferred<Unit>()
                capacityWaiters.add(deferred)
                withTimeoutOrNull(5) { deferred.await() }
                capacityWaiters.remove(deferred)
                yield()
            }
        }
        if (!coroutineContext.isActive || activeChannel == null) {
            throw SessionException(SessionFailure.CANCELLED)
        }
    }

    override fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        if (descriptor.transport != "lan") return DataHandling.UNRECOGNIZED
        val message = runCatching { TransferMessage.decode(bytes) }.getOrNull() ?: return DataHandling.UNRECOGNIZED
        processMessage(message, descriptor.peer.deviceName)
        return DataHandling.HANDLED
    }

    private fun processMessage(message: TransferMessage, peerName: String) {
        when (message.kind) {
            1L -> { // capability
                peerMaxChunkBytes = message.number(1).coerceAtMost(3072L)
                peerMaxWindow = message.number(2).coerceAtMost(64L)
            }
            2L -> handleOffer(message, peerName)
            3L -> handleAccept(message)
            4L -> handleReject(message)
            5L -> handleChunk(message)
            6L -> handleAck(message)
            7L -> { // file-result
                val deferred = fileResultDeferred
                if (deferred != null) {
                    deferred.complete(message)
                    fileResultDeferred = null
                } else {
                    receivedFileResult = message
                }
            }
            8L -> { // batch-result
                val current = state
                if (current is TransferState.Transferring) {
                    state = TransferState.Completed(current.batch.id, current.batch.files.size, current.batch.totalBytes)
                    cleanupTransfer()
                }
            }
            9L -> cancelTransfer(local = false)
        }
    }

    // MARK: - Sender Flow

    fun sendFiles(filesToSend: List<File>) {
        if (filesToSend.isEmpty() || filesToSend.size > 128) {
            updateState(TransferState.Failed("Transfer batch must contain 1 to 128 files"))
            return
        }
        val channel = activeChannel
        if (channel == null || !peerConnected) {
            val initiated = onDemandLanConnection?.invoke() == true
            if (initiated) {
                pendingFilesToSend = filesToSend
                updateState(TransferState.Connecting("your Mac"))
                connectTimeoutJob?.cancel()
                connectTimeoutJob = scope.launch {
                    delay(30_000L)
                    if (state is TransferState.Connecting) {
                        pendingFilesToSend = emptyList()
                        updateState(TransferState.Failed("Could not connect to your Mac over local network. Check Wi-Fi and Allow Connections on your Mac."))
                    }
                }
                return
            }
            updateState(TransferState.Failed("No active LAN session"))
            return
        }

        val files = mutableListOf<TransferFile>()
        var totalBytes = 0L

        for (file in filesToSend) {
            val name = file.name
            if (name.isEmpty() || name.toByteArray(Charsets.UTF_8).size > 255 ||
                '/' in name || '\\' in name || '\u0000' in name || name == "." || name == ".."
            ) {
                updateState(TransferState.Failed("Invalid filename: $name"))
                return
            }
            val size = file.length()
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(8192)
            FileInputStream(file).use { fis ->
                var r: Int
                while (fis.read(buffer).also { r = it } != -1) {
                    digest.update(buffer, 0, r)
                }
            }
            files.add(TransferFile(UUID.randomUUID().toString(), name, size, digest.digest(), sourceFile = file))
            totalBytes += size
        }

        startOfferBatch(files, totalBytes, channel)
    }

    fun sendUris(uris: List<Uri>) {
        val ctx = context ?: run {
            updateState(TransferState.Failed("No context available to resolve files"))
            return
        }
        if (uris.isEmpty() || uris.size > 128) {
            updateState(TransferState.Failed("Transfer batch must contain 1 to 128 files"))
            return
        }
        val channel = activeChannel
        if (channel == null || !peerConnected) {
            val initiated = onDemandLanConnection?.invoke() == true
            if (initiated) {
                pendingUrisToSend = uris
                updateState(TransferState.Connecting("your Mac"))
                connectTimeoutJob?.cancel()
                connectTimeoutJob = scope.launch {
                    delay(30_000L)
                    if (state is TransferState.Connecting) {
                        pendingUrisToSend = emptyList()
                        updateState(TransferState.Failed("Could not connect to your Mac over local network. Check Wi-Fi and Allow Connections on your Mac."))
                    }
                }
                return
            }
            updateState(TransferState.Failed("No active LAN session"))
            return
        }

        scope.launch(Dispatchers.IO) {
            val files = mutableListOf<TransferFile>()
            var totalBytes = 0L

            for (uri in uris) {
                var name = ""
                var size = -1L
                ctx.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                    val nameIndex = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    val sizeIndex = cursor.getColumnIndex(android.provider.OpenableColumns.SIZE)
                    if (cursor.moveToFirst()) {
                        if (nameIndex != -1) name = cursor.getString(nameIndex) ?: ""
                        if (sizeIndex != -1) size = cursor.getLong(sizeIndex)
                    }
                }
                if (name.isEmpty()) {
                    name = uri.lastPathSegment ?: "file_${System.currentTimeMillis()}"
                }
                if (name.isEmpty() || name.toByteArray(Charsets.UTF_8).size > 255 ||
                    '/' in name || '\\' in name || '\u0000' in name || name == "." || name == ".."
                ) {
                    withContext(dispatcher) { state = TransferState.Failed("Invalid filename: $name") }
                    return@launch
                }
                val digest = MessageDigest.getInstance("SHA-256")
                val buffer = ByteArray(8192)
                var calculatedSize = 0L
                val stream = ctx.contentResolver.openInputStream(uri)
                if (stream == null) {
                    withContext(dispatcher) { state = TransferState.Failed("Cannot read file: $name") }
                    return@launch
                }
                stream.use { s ->
                    var r: Int
                    while (s.read(buffer).also { r = it } != -1) {
                        digest.update(buffer, 0, r)
                        calculatedSize += r
                    }
                }
                val finalSize = if (size >= 0) size else calculatedSize
                files.add(TransferFile(UUID.randomUUID().toString(), name, finalSize, digest.digest(), sourceUri = uri))
                totalBytes += finalSize
            }

            withContext(dispatcher) {
                startOfferBatch(files, totalBytes, channel)
            }
        }
    }

    private fun startOfferBatch(files: List<TransferFile>, totalBytes: Long, channel: SecuredChannel) {
        val batchId = UUID.randomUUID().toString()
        val batch = TransferBatch(batchId, files, totalBytes, channel.descriptor.peer.deviceName)
        updateState(TransferState.WaitingForPeerApproval(batch))
        onLeaseChanged?.invoke(true)

        // Send offer slices (up to 8 files per slice)
        val totalFiles = files.size.toLong()
        val totalSlices = ((files.size + 7) / 8).toLong()

        scope.launch {
            for (sliceIdx in 0 until totalSlices.toInt()) {
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
                    failTransfer("Failed sending offer: ${e.message}")
                    return@launch
                }
            }
        }
    }

    private fun handleAccept(message: TransferMessage) {
        val current = state
        if (current !is TransferState.WaitingForPeerApproval || message.string(0) != current.batch.id) return

        transferJob = scope.launch(Dispatchers.IO) {
            streamAcceptedBatch(current.batch)
        }
    }

    private suspend fun streamAcceptedBatch(batch: TransferBatch) {
        if (activeChannel == null) return
        var totalTransferred = 0L
        val startTime = clock()
        var lastUiUpdate = 0L

        for ((fileIndex, file) in batch.files.withIndex()) {
            val inputStream = if (file.sourceFile != null) {
                FileInputStream(file.sourceFile)
            } else if (file.sourceUri != null && context != null) {
                context.contentResolver.openInputStream(file.sourceUri) ?: run {
                    failTransfer("Cannot open stream for ${file.name}")
                    return
                }
            } else {
                failTransfer("Cannot find local source file for ${file.name}")
                return
            }

            sentBytes = 0L
            acknowledgedBytes = 0L
            var fileBytesSent = 0L

            inputStream.use { fis ->
                val buffer = ByteArray(peerMaxChunkBytes.toInt())

                while (fileBytesSent < file.size) {
                    val inFlight = sentBytes - acknowledgedBytes
                    if (inFlight >= peerMaxWindow * peerMaxChunkBytes) {
                        val deferred = CompletableDeferred<Unit>().also { creditDeferred = it }
                        if (sentBytes - acknowledgedBytes < peerMaxWindow * peerMaxChunkBytes) {
                            creditDeferred = null
                        } else {
                            deferred.await()
                        }
                    }

                    if (!coroutineContext.isActive || activeChannel == null) return

                    val chunkSize = (file.size - fileBytesSent).coerceAtMost(peerMaxChunkBytes).toInt()
                    val readBytes = fis.read(buffer, 0, chunkSize)
                    if (readBytes != chunkSize) {
                        failTransfer("I/O error reading ${file.name}")
                        return
                    }

                    val chunkData = buffer.copyOf(chunkSize)
                    val chunkMsg = TransferMessage.chunk(
                        batch = batch.id,
                        file = file.id,
                        offset = fileBytesSent,
                        data = chunkData
                    )

                    try {
                        sendWithBackpressure(chunkMsg.encode())
                        fileBytesSent += chunkSize
                        sentBytes += chunkSize
                        totalTransferred += chunkSize

                        val now = clock()
                        if (now - lastUiUpdate >= 100L || fileBytesSent == file.size) {
                            lastUiUpdate = now
                            val elapsed = (now - startTime).coerceAtLeast(1L)
                            val speed = (totalTransferred * 1000.0) / elapsed

                            withContext(dispatcher) {
                                updateState(
                                    TransferState.Transferring(
                                        batch = batch,
                                        fileIndex = fileIndex + 1,
                                        fileName = file.name,
                                        fileBytes = fileBytesSent,
                                        fileSize = file.size,
                                        totalBytes = totalTransferred,
                                        speedBps = speed
                                    )
                                )
                            }
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        failTransfer("Failed sending chunk: ${e.message}")
                        return
                    }
                }
            }

            // Wait for file-result from receiver
            val fileResult = receivedFileResult ?: run {
                val deferred = CompletableDeferred<TransferMessage>().also { fileResultDeferred = it }
                deferred.await()
            }
            receivedFileResult = null
            if (fileResult.number(2) != 0L) {
                failTransfer("Receiver reported error for file ${file.name}")
                return
            }
        }

        // All files sent successfully
        val batchResult = TransferMessage.batchResult(batch = batch.id, result = 0L)
        runCatching { sendWithBackpressure(batchResult.encode()) }
        withContext(dispatcher) {
            updateState(TransferState.Completed(batch.id, batch.files.size, batch.totalBytes))
            cleanupTransfer()
        }
    }

    private fun handleAck(message: TransferMessage) {
        val written = message.number(2)
        acknowledgedBytes = written
        checkCreditAndResume()
    }

    private fun checkCreditAndResume() {
        val inFlight = sentBytes - acknowledgedBytes
        if (inFlight < peerMaxWindow * peerMaxChunkBytes) {
            creditDeferred?.complete(Unit)
            creditDeferred = null
        }
    }

    private fun handleReject(message: TransferMessage) {
        val current = state
        if (current !is TransferState.WaitingForPeerApproval || message.string(0) != current.batch.id) return
        updateState(TransferState.Rejected(current.batch.id, message.number(1)))
        cleanupTransfer()
    }

    // MARK: - Receiver Flow

    private fun handleOffer(message: TransferMessage, peerName: String) {
        val batchId = message.string(0)
        val sliceIdx = message.number(1)
        val totalSlices = message.number(2)
        val totalFiles = message.number(3)
        val totalBytes = message.number(4)

        val filesCbor = (message.fields.getOrNull(5) as? Cbor.Array)?.value ?: return
        val sliceFiles = mutableListOf<TransferFile>()
        for (f in filesCbor) {
            val row = (f as? Cbor.Array)?.value ?: continue
            if (row.size != 4) continue
            val id = (row[0] as? Cbor.Text)?.value ?: continue
            val name = (row[1] as? Cbor.Text)?.value ?: continue
            val sz = (row[2] as? Cbor.Integer)?.value ?: continue
            val hash = (row[3] as? Cbor.Bytes)?.value ?: continue
            sliceFiles.add(TransferFile(id, name, sz, hash))
        }

        val sliceMap = bufferedOfferSlices.getOrPut(batchId) { mutableMapOf() }
        sliceMap[sliceIdx] = sliceFiles
        expectedSlices[batchId] = totalSlices
        totalBatchFiles[batchId] = totalFiles
        totalBatchBytes[batchId] = totalBytes

        if (sliceMap.size.toLong() == totalSlices) {
            val allFiles = mutableListOf<TransferFile>()
            for (i in 0 until totalSlices) {
                allFiles.addAll(sliceMap[i] ?: emptyList())
            }

            val batch = TransferBatch(batchId, allFiles, totalBytes, peerName)
            bufferedOfferSlices.remove(batchId)
            expectedSlices.remove(batchId)
            totalBatchFiles.remove(batchId)
            totalBatchBytes.remove(batchId)

            val isBusy = state is TransferState.WaitingForPeerApproval ||
                         state is TransferState.IncomingOffer ||
                         state is TransferState.Transferring

            if (isBusy) {
                scope.launch {
                    val reject = TransferMessage.reject(batch = batchId, reason = 3L) // Busy
                    runCatching { sendWithBackpressure(reject.encode()) }
                }
                return
            }

            cleanupTransfer()
            updateState(TransferState.IncomingOffer(batch))
            onLeaseChanged?.invoke(true)
        }
    }

    fun acceptIncomingOffer(destinationDir: File) {
        val current = state
        if (activeChannel == null) return
        if (current !is TransferState.IncomingOffer) return

        destinationDirectory = destinationDir
        destinationDir.mkdirs()
        receiverCurrentFileIndex = 0
        receiverWrittenBytes = 0L
        lastAckedWrittenBytes = 0L
        unackedChunksCount = 0
        receiverStartTime = clock()
        lastReceiverUiUpdate = 0L

        prepareReceiverForFile(0, current.batch)
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

        scope.launch {
            val accept = TransferMessage.accept(batch = current.batch.id, files = emptyList())
            runCatching { sendWithBackpressure(accept.encode()) }
        }
    }

    fun rejectIncomingOffer(reason: Long = 0L) {
        val current = state
        if (activeChannel == null) return
        if (current !is TransferState.IncomingOffer) return

        scope.launch {
            val reject = TransferMessage.reject(batch = current.batch.id, reason = reason)
            runCatching { sendWithBackpressure(reject.encode()) }
        }
        updateState(TransferState.Idle)
        cleanupTransfer()
    }

    private fun prepareReceiverForFile(index: Int, batch: TransferBatch) {
        val destDir = destinationDirectory ?: return
        if (index !in batch.files.indices) return
        val file = batch.files[index]

        receiverCurrentFileIndex = index
        receiverWrittenBytes = 0L
        lastAckedWrittenBytes = 0L
        unackedChunksCount = 0
        receiverDigest = MessageDigest.getInstance("SHA-256")

        val partFile = File(destDir, "${file.name}.anice-part")
        receiverPartFile = partFile
        partFile.parentFile?.mkdirs()
        receiverFileOutputStream = FileOutputStream(partFile)
    }

    private fun scheduleAckTimer() {
        if (ackTimerJob?.isActive == true) return
        ackTimerJob = scope.launch {
            delay(20)
            ackTimerJob = null
            flushAck()
        }
    }

    private fun flushAck() {
        if (ackJob?.isActive == true) return
        val current = state as? TransferState.Transferring ?: return
        val batch = current.batch
        val fileIndex = receiverCurrentFileIndex
        if (fileIndex !in batch.files.indices) return
        val currentFile = batch.files[fileIndex]
        val bytesToAck = receiverWrittenBytes
        if (bytesToAck <= lastAckedWrittenBytes && bytesToAck != currentFile.size) return

        ackJob = scope.launch(Dispatchers.IO) {
            try {
                val ack = TransferMessage.ack(batch = batch.id, file = currentFile.id, written = bytesToAck)
                sendWithBackpressure(ack.encode())
                withContext(dispatcher) {
                    lastAckedWrittenBytes = maxOf(lastAckedWrittenBytes, bytesToAck)
                    unackedChunksCount = 0
                }
            } catch (_: Exception) {
                // Retried on next flushAck or capacityAvailable
            } finally {
                withContext(dispatcher) {
                    ackJob = null
                    val unacked = receiverWrittenBytes - lastAckedWrittenBytes
                    if (unacked >= 8 * peerMaxChunkBytes || (receiverWrittenBytes == currentFile.size && receiverWrittenBytes > lastAckedWrittenBytes)) {
                        flushAck()
                    }
                }
            }
        }
    }

    private fun handleChunk(message: TransferMessage) {
        val current = state as? TransferState.Transferring ?: return
        val destDir = destinationDirectory ?: return
        val fos = receiverFileOutputStream ?: return
        val partFile = receiverPartFile ?: return

        val fileId = message.string(1)
        val offset = message.number(2)
        val data = message.bytes(3)

        if (receiverCurrentFileIndex !in current.batch.files.indices) return
        val currentFile = current.batch.files[receiverCurrentFileIndex]
        if (currentFile.id != fileId || offset != receiverWrittenBytes) return

        fos.write(data)
        receiverDigest.update(data)
        receiverWrittenBytes += data.size
        unackedChunksCount++

        val nextTotalBytes = current.totalBytes + data.size
        val now = clock()
        if (now - lastReceiverUiUpdate >= 100L || receiverWrittenBytes == currentFile.size) {
            lastReceiverUiUpdate = now
            val elapsed = (now - receiverStartTime).coerceAtLeast(1L)
            val speed = (nextTotalBytes * 1000.0) / elapsed

            updateState(
                TransferState.Transferring(
                    batch = current.batch,
                    fileIndex = receiverCurrentFileIndex + 1,
                    fileName = currentFile.name,
                    fileBytes = receiverWrittenBytes,
                    fileSize = currentFile.size,
                    totalBytes = nextTotalBytes,
                    speedBps = speed
                )
            )
        }

        // Ack every 8 chunks or at end of file
        val unacked = receiverWrittenBytes - lastAckedWrittenBytes
        if (unacked >= 8 * peerMaxChunkBytes || receiverWrittenBytes == currentFile.size) {
            flushAck()
        } else if (receiverWrittenBytes > lastAckedWrittenBytes) {
            scheduleAckTimer()
        }

        // Check file completion
        if (receiverWrittenBytes == currentFile.size) {
            ackTimerJob?.cancel()
            ackTimerJob = null
            flushAck()
            fos.fd.sync()
            fos.close()
            receiverFileOutputStream = null

            val digest = receiverDigest.digest()
            if (digest.contentEquals(currentFile.sha256)) {
                // Atomic rename
                val targetFile = uniqueFile(destDir, currentFile.name)
                partFile.renameTo(targetFile)
                if (context != null) {
                    android.media.MediaScannerConnection.scanFile(context, arrayOf(targetFile.absolutePath), null, null)
                }

                val fileResult = TransferMessage.fileResult(batch = current.batch.id, file = fileId, result = 0L, hash = digest)
                scope.launch(Dispatchers.IO) {
                    runCatching { sendWithBackpressure(fileResult.encode()) }
                }

                val nextIndex = receiverCurrentFileIndex + 1
                if (nextIndex < current.batch.files.size) {
                    prepareReceiverForFile(nextIndex, current.batch)
                } else {
                    // All files completed
                    val batchResult = TransferMessage.batchResult(batch = current.batch.id, result = 0L)
                    scope.launch(Dispatchers.IO) {
                        runCatching { sendWithBackpressure(batchResult.encode()) }
                    }
                    updateState(TransferState.Completed(current.batch.id, current.batch.files.size, current.batch.totalBytes))
                    cleanupTransfer()
                }
            } else {
                partFile.delete()
                val fileResult = TransferMessage.fileResult(batch = current.batch.id, file = fileId, result = 1L, hash = digest)
                scope.launch(Dispatchers.IO) {
                    runCatching { sendWithBackpressure(fileResult.encode()) }
                }
                failTransfer("Hash mismatch on received file ${currentFile.name}")
            }
        }
    }

    private fun uniqueFile(folder: File, name: String): File {
        var candidate = File(folder, name)
        if (!candidate.exists()) return candidate
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var count = 1
        while (candidate.exists()) {
            candidate = File(folder, "$base ($count)$ext")
            count++
        }
        return candidate
    }

    // MARK: - Cancellation and Failure

    fun cancelTransfer(local: Boolean = true) {
        val current = state
        if (local) {
            val batchId = when (current) {
                is TransferState.WaitingForPeerApproval -> current.batch.id
                is TransferState.IncomingOffer -> current.batch.id
                is TransferState.Transferring -> current.batch.id
                else -> ""
            }
            if (batchId.isNotEmpty()) {
                val cancelMsg = TransferMessage.cancel(batch = batchId, file = "", reason = 0L)
                scope.launch(Dispatchers.IO) { runCatching { sendWithBackpressure(cancelMsg.encode()) } }
            }
        }
        updateState(TransferState.Cancelled)
        cleanupTransfer()
    }

    fun dismiss() {
        updateState(TransferState.Idle)
        cleanupTransfer()
    }

    private fun failTransfer(reason: String) {
        if (state is TransferState.Completed || state is TransferState.Cancelled) return
        updateState(TransferState.Failed(reason))
        cleanupTransfer()
    }

    private fun cleanupTransfer() {
        connectTimeoutJob?.cancel()
        connectTimeoutJob = null
        pendingUrisToSend = emptyList()
        pendingFilesToSend = emptyList()
        transferJob?.cancel()
        transferJob = null
        ackJob?.cancel()
        ackJob = null
        ackTimerJob?.cancel()
        ackTimerJob = null
        runCatching { receiverFileOutputStream?.close() }
        receiverFileOutputStream = null
        receiverPartFile?.delete()
        receiverPartFile = null
        creditDeferred?.complete(Unit)
        creditDeferred = null
        clearCapacityWaiters()
        onLeaseChanged?.invoke(false)
    }
}
