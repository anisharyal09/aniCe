// SPDX-License-Identifier: GPL-3.0-or-later
// Coordinates bidirectional file transfer batches, cumulative flow control and lifecycle leases over LAN-preferred authenticated LAN/BLE channels.
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
    var peerCompatible by mutableStateOf(false); private set
    var onPickerChanged: (Boolean) -> Unit = {}
    private var pickerTimeout: Job? = null
    var selectingFiles = false; private set
    internal val operationID get() = epoch
    fun beginPicker() {
        selectingFiles = true
        onPickerChanged(true)
        pickerTimeout?.cancel()
        pickerTimeout = scope.launch { delay(60000); selectingFiles = false; pickerTimeout = null; onPickerChanged(false) }
    }
    fun endPicker() {
        val wasPicking = selectingFiles
        selectingFiles = false; pickerTimeout?.cancel(); pickerTimeout = null
        if (wasPicking) onPickerChanged(false)
    }
    var backgroundAllowed = false
        internal set
    var onLeaseChanged: ((Boolean) -> Unit)? = null
    var onStateChanged: ((TransferState) -> Unit)? = null

    val isBusy: Boolean
        get() = preparing || offerAssembly != null || state is TransferState.Connecting ||
                state is TransferState.WaitingForPeerApproval ||
                state is TransferState.IncomingOffer ||
                state is TransferState.Transferring

    var onDemandLanConnection: (() -> Boolean)? = null
    private var pendingSend: (() -> Unit)? = null
    private var connectTimeoutJob: Job? = null

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    internal var activeChannel by mutableStateOf<SecuredChannel?>(null); private set
    private val channels = mutableMapOf<String, SecuredChannel>()
    private val capabilities = mutableMapOf<String, TransferMessage>()
    private var preparation: Job? = null
    var preparing by mutableStateOf(false); private set
    private var transferJob: Job? = null

    private var epoch = UUID.randomUUID()
    private var capacityRevision = 0L
    private var sendingFile: TransferFile? = null
    private val retiredBatches = java.util.ArrayDeque<String>()
    private var currentBatch: TransferBatch? = null

    /** True from the moment a received file's last chunk lands until it is hashed and published. */
    var finalizing by mutableStateOf(false); private set

    /**
     * Direction of the active or most recently finished batch: true while this device receives it.
     * It deliberately outlives [cleanupTransfer] so a completed panel can still report which way the
     * files moved; [dismiss] clears it.
     */
    var receiving by mutableStateOf(false); private set

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
    private data class OfferAssembly(val batch: String, val totalSlices: Long, val totalFiles: Long,
                                     val totalBytes: Long, val slices: MutableMap<Long, List<TransferFile>> = mutableMapOf())
    private var offerAssembly: OfferAssembly? = null
    private var offerTimeout: Job? = null
    private var destinationPreparation: Job? = null
    private var documentDestination: TransferDestination? = null
    private var receiverPartDocument: Uri? = null
    private var destinationDirectory: File? = null
    private var receiverCurrentFileIndex = 0
    private var receiverPartFile: File? = null
    private var receiverStorage: TransferReceiveStorage? = null
    private var receiveCleanup: Job? = null
    private var receiverWrittenBytes: Long = 0L
    private var receiverTotalTransferred: Long = 0L
    private var lastAckedWrittenBytes: Long = 0L
    private var ackJob: Job? = null
    private var ackTimerJob: Job? = null
    private var receiverRate = TransferRate()
    private var lastReceiverUiUpdate: Long = 0L

    private fun updateState(newState: TransferState) {
        state = newState
        onStateChanged?.invoke(newState)
    }

    private fun chunkLimit(descriptor: ChannelDescriptor?) =
        if (descriptor?.transport == "lan" && descriptor.maximumDataBytes >= 262144) 131072 else 3072

    override fun available(channel: SecuredChannel) {
        val transport = channel.descriptor.transport
        if (transport != "lan" && transport != "ble") return
        val peer = activeChannel?.descriptor?.peer
        if (peer != null && (peer.deviceId != channel.descriptor.peer.deviceId ||
                peer.fingerprint != channel.descriptor.peer.fingerprint)) return
        if (channels[transport]?.descriptor == channel.descriptor) return
        channels[transport]?.let { retired(it.descriptor) }
        channels[transport] = channel
        selectPreferredChannel()
        scope.launch {
            if (channels[transport] === channel) runCatching { sendWithBackpressure(TransferMessage.capability(
                version = if (chunkLimit(channel.descriptor) > 3072) 2 else 1,
                maxChunkBytes = chunkLimit(channel.descriptor).toLong(),
                maxWindow = if (chunkLimit(channel.descriptor) > 3072) 8 else 64
            ).encode(chunkLimit(channel.descriptor)), channel, jobBound = false) }
        }
    }

    private fun selectPreferredChannel() {
        // A live batch remains bound to its channel generation until cleanup.
        if (activeChannel != null && isBusy && state !is TransferState.Connecting) return
        val preferred = channels["lan"] ?: channels["ble"]
        activeChannel = preferred
        peerConnected = preferred != null
        peerCompatible = false
        peerMaxChunkBytes = 3072
        peerMaxWindow = 64
        clearOfferAssembly()
        preferred?.let { channel ->
            capabilities[channel.descriptor.transport]?.let { applyCapability(it) }
        }
    }

    private fun applyCapability(message: TransferMessage) {
        peerCompatible = true
        peerMaxChunkBytes = message.number(1).coerceAtMost(if (message.number(0) == 2L) chunkLimit(activeChannel?.descriptor).toLong() else 3072L)
        peerMaxWindow = message.number(2).coerceAtMost(if (peerMaxChunkBytes > 3072) 8L else 64L)
        if (state is TransferState.Connecting) {
            connectTimeoutJob?.cancel(); connectTimeoutJob = null
            val send = pendingSend
            pendingSend = null
            updateState(TransferState.Idle)
            send?.invoke()
        }
    }

    override fun retired(descriptor: ChannelDescriptor) {
        if (channels[descriptor.transport]?.descriptor != descriptor) return
        channels.remove(descriptor.transport)
        capabilities.remove(descriptor.transport)
        clearCapacityWaiters()
        if (descriptor != activeChannel?.descriptor) return
        activeChannel = null
        peerConnected = false
        peerCompatible = false
        if (isBusy) updateState(TransferState.Failed("Connection closed. Send the files again using the remaining connection."))
        cleanupTransfer()
        selectPreferredChannel()
    }

    private fun clearCapacityWaiters() {
        capacityRevision++
        while (true) {
            val waiter = capacityWaiters.poll() ?: break
            waiter.complete(Unit)
        }
    }

    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        if (channels[descriptor.transport]?.descriptor != descriptor) return
        clearCapacityWaiters()
        if (descriptor != activeChannel?.descriptor) return
        checkCreditAndResume()
        flushAck()
    }

    private suspend fun sendWithBackpressure(data: ByteArray, channel: SecuredChannel =
        activeChannel ?: throw SessionException(SessionFailure.CANCELLED), jobBound: Boolean = true) {
        val operation = epoch
        while (true) {
            coroutineContext.ensureActive()
            if (jobBound && epoch != operation || channels[channel.descriptor.transport] !== channel) throw SessionException(SessionFailure.CANCELLED)
            val revision = capacityRevision
            val waiter = CompletableDeferred<Unit>()
            capacityWaiters.add(waiter)
            try {
                channel.sendData(data)
                return
            } catch (_: SessionBackpressure) {
                if (revision == capacityRevision) withTimeout(10000) { waiter.await() }
            } finally { capacityWaiters.remove(waiter) }
        }
    }

    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        val limit = chunkLimit(descriptor)
        // A profile-3 chunk record carries 131 KiB of CBOR. Decoding it on a background dispatcher
        // keeps that work off the presentation thread, where it previously blocked frame rendering.
        val message = try {
            withContext(Dispatchers.Default) { TransferMessage.decode(bytes, limit) }
                ?: return DataHandling.UNRECOGNIZED
        } catch (_: TransferWireException) { return DataHandling.DISCARDED }
          catch (_: SessionException) { return DataHandling.UNRECOGNIZED }
        if (channels[descriptor.transport]?.descriptor != descriptor) return DataHandling.DISCARDED
        if (message.kind == 1L) {
            capabilities[descriptor.transport] = message
            if (descriptor == activeChannel?.descriptor) {
                peerCompatible = true
                if (state !is TransferState.Transferring && transferJob?.isActive != true) applyCapability(message)
            }
            return DataHandling.HANDLED
        }
        if (descriptor != activeChannel?.descriptor) return DataHandling.DISCARDED
        processMessage(message, descriptor.peer.deviceName)
        return DataHandling.HANDLED
    }

    private suspend fun processMessage(message: TransferMessage, peerName: String) {
        when (message.kind) {
            2L -> handleOffer(message, peerName)
            3L -> handleAccept(message)
            4L -> handleReject(message)
            5L -> handleChunk(message)
            6L -> handleAck(message)
            7L -> {
                val batch = currentBatch ?: return
                val file = sendingFile ?: return
                if (message.string(0) != batch.id || message.string(1) != file.id ||
                    message.number(2) == 0L && (sentBytes != file.size || !message.bytes(3).contentEquals(file.sha256))) return
                val deferred = fileResultDeferred
                if (deferred != null) { fileResultDeferred = null; deferred.complete(message) }
                else receivedFileResult = message
            }
            8L -> Unit // Verified per-file results determine completion.
            10L -> activeChannel?.let { channel -> scope.launch {
                runCatching { sendWithBackpressure(TransferMessage.status(message.string(0), message.string(1), 0, 4).encode(), channel, jobBound = false) }
            } }
            11L -> Unit
            9L -> {
                val batch = currentBatch ?: return
                val fileId = message.string(1)
                if (message.string(0) != batch.id || fileId.isNotEmpty() && fileId != sendingFile?.id &&
                    fileId != batch.files.getOrNull(receiverCurrentFileIndex)?.id) return
                cancelTransfer(local = false)
            }
        }
    }

    // MARK: - Sender Flow

    fun sendFiles(files: List<File>) = prepareSources(files) { file ->
        prepareFile(file.name, file.length(), sourceFile = file) { FileInputStream(file) }
    }

    fun sendUris(uris: List<Uri>) {
        val resolver = context?.contentResolver ?: run {
            updateState(TransferState.Failed("No context available to resolve files"))
            return
        }
        prepareSources(uris) { uri ->
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
            prepareFile(name, size, sourceUri = uri) { resolver.openInputStream(uri) }
        }
    }

    private fun <T> prepareSources(sources: List<T>, prepare: suspend (T) -> TransferFile) {
        if (state !is TransferState.Connecting) selectPreferredChannel()
        if (sources.isEmpty() || sources.size > 128) {
            updateState(TransferState.Failed("Transfer batch must contain 1 to 128 files"))
            return
        }
        val channel = activeChannel
        if (channel == null || !peerConnected) {
            if (onDemandLanConnection?.invoke() == true) {
                pendingSend = { prepareSources(sources, prepare) }
                updateState(TransferState.Connecting("your Mac"))
                onLeaseChanged?.invoke(true)
                connectTimeoutJob?.cancel()
                connectTimeoutJob = scope.launch {
                    delay(30_000L)
                    if (state is TransferState.Connecting) {
                        failTransfer("Could not connect to your Mac over local network. Check Wi-Fi and Allow Connections on your Mac.")
                    }
                }
            } else updateState(TransferState.Failed("No secured local-network or Bluetooth connection"))
            return
        }
        if (!peerCompatible) { updateState(TransferState.Failed("This peer has not advertised file transfer support")); return }
        if (preparation?.isActive == true || transferJob?.isActive == true) return
        val operation = epoch
        preparing = true
        onLeaseChanged?.invoke(true)
        preparation = scope.launch(Dispatchers.IO) {
            try {
                val files = sources.map { coroutineContext.ensureActive(); prepare(it) }
                val totalBytes = files.fold(0L) { total, file -> Math.addExact(total, file.size) }
                withContext(dispatcher) {
                    if (operation == epoch && activeChannel === channel) startOfferBatch(files, totalBytes, channel)
                }
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                withContext(dispatcher) { if (operation == epoch) failTransfer("File preparation failed: ${error.message}") }
            } finally {
                withContext(NonCancellable + dispatcher) { if (operation == epoch) { preparing = false; preparation = null } }
            }
        }
    }

    private suspend fun prepareFile(name: String, size: Long, sourceFile: File? = null, sourceUri: Uri? = null,
                                    open: () -> java.io.InputStream?): TransferFile {
        if (name.isEmpty() || name.toByteArray(Charsets.UTF_8).size > 255 ||
            '/' in name || '\\' in name || '\u0000' in name || name == "." || name == "..") {
            throw java.io.IOException("Invalid filename: $name")
        }
        if (size < 0) throw java.io.IOException("The provider must supply a known file size: $name")
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(8192)
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

    private fun startOfferBatch(files: List<TransferFile>, totalBytes: Long, channel: SecuredChannel) {
        val batchId = UUID.randomUUID().toString()
        val batch = TransferBatch(batchId, files, totalBytes, channel.descriptor.peer.deviceName)
        currentBatch = batch
        receiving = false
        updateState(TransferState.WaitingForPeerApproval(batch))
        onLeaseChanged?.invoke(true)

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

    private fun handleAccept(message: TransferMessage) {
        val current = state
        if (current !is TransferState.WaitingForPeerApproval || message.string(0) != current.batch.id) return

        if (transferJob?.isActive == true) return
        val operation = epoch
        val channel = activeChannel ?: return
        transferJob = scope.launch {
            if (operation != epoch || activeChannel !== channel) return@launch
            try { streamAcceptedBatch(current.batch) }
            catch (error: TimeoutCancellationException) { if (operation == epoch) failTransfer("File confirmation timed out") }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) { if (operation == epoch) failTransfer("Source read failed: ${error.message}") }
        }
    }

    private suspend fun streamAcceptedBatch(batch: TransferBatch) {
        if (activeChannel == null) return
        val operation = epoch
        var totalTransferred = 0L
        val rate = TransferRate()
        var lastUiUpdate = 0L

        for ((fileIndex, file) in batch.files.withIndex()) {
            if (operation != epoch) return
            val opened = java.util.concurrent.atomic.AtomicReference<java.io.InputStream?>()
            val inputStream = try {
                withContext(Dispatchers.IO) {
                    (file.sourceFile?.let(::FileInputStream)
                        ?: file.sourceUri?.let { context?.contentResolver?.openInputStream(it) }
                        ?: throw java.io.IOException("Cannot open local source file")).also { opened.set(it) }
                }
            } catch (error: Exception) {
                withContext(NonCancellable + Dispatchers.IO) { opened.getAndSet(null)?.close() }
                if (error is CancellationException) throw error
                if (operation == epoch) failTransfer("Cannot open ${file.name}: ${error.message}")
                return
            }

            sendingFile = file
            receivedFileResult = null
            sentBytes = 0L
            acknowledgedBytes = 0L
            var fileBytesSent = 0L

            try {
                val fis = inputStream
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

                    if (!coroutineContext.isActive || operation != epoch || activeChannel == null) return

                    val chunkSize = (file.size - fileBytesSent).coerceAtMost(peerMaxChunkBytes).toInt()
                    val readBytes = try { withContext(Dispatchers.IO) {
                        var filled = 0
                        while (filled < chunkSize) {
                            val count = fis.read(buffer, filled, chunkSize - filled)
                            if (count < 0) break
                            if (count == 0) throw java.io.IOException("Source stream made no progress")
                            filled += count
                        }
                        filled
                    } } catch (error: Exception) {
                        if (error is CancellationException) throw error
                        if (operation == epoch) failTransfer("Source read failed: ${error.message}")
                        return
                    }
                    if (operation != epoch) return
                    if (readBytes != chunkSize) {
                        failTransfer("I/O error reading ${file.name}")
                        return
                    }

                    val chunkMsg = TransferMessage.chunkFrom(
                        batch = batch.id,
                        file = file.id,
                        offset = fileBytesSent,
                        source = buffer,
                        length = chunkSize
                    )

                    try {
                        sentBytes += chunkSize
                        sendWithBackpressure(chunkMsg.encode(chunkLimit(activeChannel?.descriptor)))
                        if (operation != epoch) return
                        fileBytesSent += chunkSize
                        totalTransferred += chunkSize

                        val now = clock()
                        if (now - lastUiUpdate >= 100L || fileBytesSent == file.size) {
                            lastUiUpdate = now
                            val speed = rate.add(totalTransferred, now)

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
                        if (operation == epoch) failTransfer("Failed sending chunk: ${e.message}")
                        return
                    }
                }
            } finally {
                withContext(NonCancellable + Dispatchers.IO) { opened.getAndSet(null)?.close() }
            }

            // Wait for file-result from receiver
            val fileResult = receivedFileResult ?: run {
                val deferred = CompletableDeferred<TransferMessage>().also { fileResultDeferred = it }
                withTimeout(30000) { deferred.await() }
            }
            receivedFileResult = null
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
            updateState(TransferState.Completed(batch.id, batch.files.size, batch.totalBytes))
            cleanupTransfer()
        }
    }

    private fun handleAck(message: TransferMessage) {
        val batch = currentBatch ?: return
        val file = sendingFile ?: return
        if (message.string(0) != batch.id || message.string(1) != file.id) return
        val written = message.number(2)
        if (written < acknowledgedBytes || written > sentBytes || written > file.size) return
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
        if (batchId in retiredBatches) return
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

        if (offerAssembly?.let { it.batch != batchId } == true) return
        val assembly = offerAssembly ?: OfferAssembly(batchId, totalSlices, totalFiles, totalBytes).also {
            offerAssembly = it
            offerTimeout = scope.launch { delay(10000); clearOfferAssembly(); selectPreferredChannel() }
        }
        if (assembly.totalSlices != totalSlices || assembly.totalFiles != totalFiles ||
            assembly.totalBytes != totalBytes) { clearOfferAssembly(); return }
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
                allFiles.map { it.id }.toSet().size != allFiles.size) { clearOfferAssembly(); return }
            clearOfferAssembly()
            val batch = TransferBatch(batchId, allFiles, totalBytes, peerName)

            val isBusy = this.isBusy

            if (isBusy) {
                val channel = activeChannel ?: return
                scope.launch {
                    val reject = TransferMessage.reject(batch = batchId, reason = 3L) // Busy
                    runCatching { sendWithBackpressure(reject.encode(), channel, jobBound = false) }
                }
                return
            }

            cleanupTransfer(selectChannel = false)
            currentBatch = batch
            updateState(TransferState.IncomingOffer(batch))
        }
    }

    private fun clearOfferAssembly() {
        offerTimeout?.cancel(); offerTimeout = null
        offerAssembly = null
    }

    fun acceptIncomingOffer(tree: Uri, modes: Int) {
        val ctx = context ?: return
        val current = state as? TransferState.IncomingOffer ?: return
        if (destinationPreparation?.isActive == true) return
        val operation = epoch
        onLeaseChanged?.invoke(true)
        destinationPreparation = scope.launch {
            val owned = java.util.concurrent.atomic.AtomicReference<TransferDestination?>()
            var destination: TransferDestination? = null
            try {
                receiveCleanup?.join()
                if (operation != epoch) return@launch
                destination = withContext(Dispatchers.IO) {
                    TransferDestination(ctx, tree, modes).also { target ->
                        owned.set(target)
                        try { target.preflight(current.batch.totalBytes) }
                        catch (error: Exception) { target.close(); throw error }
                    }
                }
                if (operation != epoch || activeChannel == null) { withContext(NonCancellable + Dispatchers.IO) { destination.close() }; return@launch }
                documentDestination = destination
                owned.set(null)
                acceptIncomingOffer(File(ctx.filesDir, "unused-document-destination"))
            } catch (error: CancellationException) { withContext(NonCancellable + Dispatchers.IO) { owned.getAndSet(null)?.close() }; throw error }
            catch (error: Exception) {
                withContext(NonCancellable + Dispatchers.IO) { owned.getAndSet(null)?.close() }
                if (operation == epoch) failTransfer("Cannot use this folder: ${error.message}. Choose another local folder.")
            }
        }
    }

    suspend fun acceptIncomingOffer(destinationDir: File) {
        val current = state
        val channel = activeChannel ?: return
        if (current !is TransferState.IncomingOffer) return
        val operation = epoch

        destinationDirectory = destinationDir
        receiving = true
        receiveCleanup?.join()
        if (operation != epoch) return
        receiverCurrentFileIndex = 0
        receiverWrittenBytes = 0L
        receiverTotalTransferred = 0L
        lastAckedWrittenBytes = 0L
        receiverRate = TransferRate()
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

    fun rejectIncomingOffer(reason: Long = 0L) {
        val current = state
        val channel = activeChannel ?: return
        if (current !is TransferState.IncomingOffer) return

        scope.launch {
            val reject = TransferMessage.reject(batch = current.batch.id, reason = reason)
            runCatching { sendWithBackpressure(reject.encode(), channel, jobBound = false) }
        }
        updateState(TransferState.Idle)
        cleanupTransfer()
    }

    private suspend fun prepareReceiverForFile(index: Int, batch: TransferBatch) {
        val destDir = destinationDirectory ?: return
        if (index !in batch.files.indices) return
        val file = batch.files[index]

        receiverCurrentFileIndex = index
        receiverWrittenBytes = 0L
        lastAckedWrittenBytes = 0L
        val operation = epoch
        val storage = TransferReceiveStorage(destDir, documentDestination)
        try {
            val (partial, document) = storage.create(batch.id, file.id)
            if (operation != epoch) { storage.discard(); throw SessionException(SessionFailure.CANCELLED) }
            receiverStorage = storage
            receiverPartFile = partial
            receiverPartDocument = document
        } catch (error: Exception) { withContext(NonCancellable) { storage.discard() }; throw error }
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
            try {
                val ack = TransferMessage.ack(batch = batch.id, file = currentFile.id, written = bytesToAck)
                sendWithBackpressure(ack.encode(), channel)
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
                    if (unacked >= minOf(8L, maxOf(1L, peerMaxWindow / 2)) * peerMaxChunkBytes || (receiverWrittenBytes == currentFile.size && receiverWrittenBytes > lastAckedWrittenBytes)) {
                        flushAck()
                    }
                }
            }
        }
    }

    private suspend fun handleChunk(message: TransferMessage) {
        val current = state as? TransferState.Transferring ?: return
        val destDir = destinationDirectory ?: return
        val storage = receiverStorage ?: return
        if (receiverPartFile == null && receiverPartDocument == null) return

        val fileId = message.string(1)
        val offset = message.number(2)
        val data = message.bytes(3)

        if (receiverCurrentFileIndex !in current.batch.files.indices) return
        val currentFile = current.batch.files[receiverCurrentFileIndex]
        if (currentFile.id != fileId || offset != receiverWrittenBytes) return

        if (message.string(0) != current.batch.id || data.size > chunkLimit(activeChannel?.descriptor) || data.size.toLong() > currentFile.size - receiverWrittenBytes) return
        val operation = epoch
        try { storage.write(data) }
        catch (error: java.io.IOException) { if (operation == epoch) failTransfer("Destination write failed: ${error.message}"); return }
        if (operation != epoch || receiverStorage !== storage) return
        receiverWrittenBytes += data.size
        receiverTotalTransferred += data.size

        val now = clock()
        if (now - lastReceiverUiUpdate >= 100L || receiverWrittenBytes == currentFile.size) {
            lastReceiverUiUpdate = now
            val speed = receiverRate.add(receiverTotalTransferred, now)

            updateState(
                TransferState.Transferring(
                    batch = current.batch,
                    fileIndex = receiverCurrentFileIndex + 1,
                    fileName = currentFile.name,
                    fileBytes = receiverWrittenBytes,
                    fileSize = currentFile.size,
                    totalBytes = receiverTotalTransferred,
                    speedBps = speed
                )
            )
        }

        // Ack every 8 chunks or at end of file
        val unacked = receiverWrittenBytes - lastAckedWrittenBytes
        if (unacked >= minOf(8L, maxOf(1L, peerMaxWindow / 2)) * peerMaxChunkBytes || receiverWrittenBytes == currentFile.size) {
            flushAck()
        } else if (receiverWrittenBytes > lastAckedWrittenBytes) {
            scheduleAckTimer()
        }

        if (receiverWrittenBytes == currentFile.size) finalizeReceiverFile(current.batch)
    }

    private suspend fun finalizeReceiverFile(batch: TransferBatch) {
        if (finalizing) return
        val file = batch.files.getOrNull(receiverCurrentFileIndex) ?: return
        val storage = receiverStorage ?: return
        val partial = receiverPartFile
        val document = receiverPartDocument
        if (partial == null && document == null) return
        val destination = destinationDirectory ?: return
        finalizing = true
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
            storage.finish(file.name, file.sha256)
        } catch (error: Exception) {
            if (operation == epoch) { finalizing = false; failTransfer("File verification or finalization failed: ${error.message}") }
            return
        }
        if (operation != epoch || receiverStorage !== storage) return
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
                sendWithBackpressure(TransferMessage.fileResult(batch.id, file.id, 0L, digest).encode())
                if (operation != epoch) return@launch
                finalizing = false
                if (next < batch.files.size) {
                    if (receiverWrittenBytes == batch.files[next].size) finalizeReceiverFile(batch)
                } else {
                    sendWithBackpressure(TransferMessage.batchResult(batch.id, 0L).encode())
                    if (operation != epoch) return@launch
                    updateState(TransferState.Completed(batch.id, batch.files.size, batch.totalBytes))
                    cleanupTransfer()
                }
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) { if (operation == epoch) failTransfer("Completion delivery failed: ${error.message}") }
        }
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
                val channel = activeChannel
                scope.launch { if (channel != null && channels[channel.descriptor.transport] === channel) runCatching { sendWithBackpressure(cancelMsg.encode(), channel, jobBound = false) } }
            }
        }
        updateState(TransferState.Cancelled)
        cleanupTransfer()
    }

    fun dismiss() {
        receiving = false
        updateState(TransferState.Idle)
        cleanupTransfer()
    }

    private fun failTransfer(reason: String) {
        if (state is TransferState.Completed || state is TransferState.Cancelled) return
        val batch = currentBatch
        val channel = activeChannel
        val file = batch?.files?.getOrNull(receiverCurrentFileIndex)
        if ((receiverPartFile != null || receiverPartDocument != null) && batch != null && file != null && channel != null) {
            val result = TransferMessage.fileResult(batch.id, file.id, 2L, ByteArray(32))
            scope.launch { if (channels[channel.descriptor.transport] === channel) runCatching { sendWithBackpressure(result.encode(), channel, jobBound = false) } }
        }
        updateState(TransferState.Failed(reason))
        cleanupTransfer()
    }

    private fun cleanupTransfer(selectChannel: Boolean = true) {
        connectTimeoutJob?.cancel()
        connectTimeoutJob = null
        pendingSend = null
        endPicker()
        destinationPreparation?.cancel(); destinationPreparation = null
        preparation?.cancel(); preparation = null; preparing = false
        clearOfferAssembly()
        epoch = UUID.randomUUID()
        // Already-sealed work finishes; epoch checks discard its callbacks without closing the shared socket.
        transferJob = null
        fileResultDeferred?.cancel()
        fileResultDeferred = null
        receivedFileResult = null
        currentBatch?.let { retiredBatches.addLast(it.id); if (retiredBatches.size > 32) retiredBatches.removeFirst() }
        currentBatch = null
        destinationDirectory = null
        sendingFile = null
        finalizing = false
        ackJob = null
        ackTimerJob?.cancel()
        ackTimerJob = null
        val storage = receiverStorage
        val destination = documentDestination
        receiverStorage = null
        receiverPartFile = null
        receiverPartDocument = null
        documentDestination = null
        receiveCleanup = scope.launch(Dispatchers.IO) {
            try { storage?.discard() }
            catch (error: Exception) { System.err.println("Transfer partial cleanup failed: ${error.javaClass.simpleName}") }
            finally { destination?.close() }
        }
        creditDeferred?.complete(Unit)
        creditDeferred = null
        clearCapacityWaiters()
        receiverTotalTransferred = 0L
        onLeaseChanged?.invoke(false)
        if (selectChannel) selectPreferredChannel()
    }
}
