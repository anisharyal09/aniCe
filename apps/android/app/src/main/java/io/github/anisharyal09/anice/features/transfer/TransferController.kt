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
import kotlinx.coroutines.channels.Channel

data class TransferFile(
    val id: String,
    val name: String,
    val size: Long,
    val sha256: ByteArray,
    val sourceFile: File? = null,
    val sourceUri: Uri? = null,
    val ownsReadGrant: Boolean = false
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
    /**
     * The secured channel retired mid-stream. The verified prefix and destination stay retained in
     * checkpoints for [pauseTimeoutMillis], so a reconnected channel can continue instead of restarting.
     */
    data class Paused(
        val batch: TransferBatch,
        val fileIndex: Int,
        val fileName: String,
        val fileBytes: Long,
        val fileSize: Long,
        val totalBytes: Long,
        val reason: String,
        val canResumeOverBle: Boolean
    ) : TransferState
    data class Completed(val batchId: String, val fileCount: Int, val totalBytes: Long) : TransferState
    data class Rejected(val batchId: String, val reason: Long) : TransferState
    data class Failed(val reason: String) : TransferState
    data object Cancelled : TransferState
}

class TransferController(
    private val context: Context? = null,
    private val dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
    private val clock: () -> Long = { if (context != null) android.os.SystemClock.elapsedRealtime() else System.nanoTime() / 1_000_000L },
    private val pauseTimeoutMillis: Long = 15 * 60 * 1000L,
    private val resumeTimeoutMillis: Long = 15000L,
    private val confirmationTimeoutMillis: Long = 30000L,
    recoveryFile: File? = null,
    private val receiveDispatcher: CoroutineDispatcher = transferReceiveDispatcher,
    private val openSource: (TransferFile) -> java.io.InputStream = { file ->
        file.sourceFile?.let(::FileInputStream)
            ?: file.sourceUri?.let { context?.contentResolver?.openInputStream(it) }
            ?: throw java.io.IOException("Cannot open local source file")
    },
    private val recoveryIdentity: suspend () -> String = {
        (context as io.github.anisharyal09.anice.AniCeApplication).identityService.getOrCreateIdentity().identity.fingerprint
    }
) : FeatureHandler {

    var state by mutableStateOf<TransferState>(TransferState.Idle); private set
    var peerConnected by mutableStateOf(false); private set
    var peerCompatible by mutableStateOf(false); private set
    var onPickerChanged: (Boolean) -> Unit = {}
    var onChannelChanged: () -> Unit = {}
    private var pickerTimeout: Job? = null
    var selectingFiles = false; private set
    internal val operationID get() = currentBatch?.id?.let(UUID::fromString) ?: epoch
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

    /**
     * A failed LAN attempt must not drop a pending send when a secured Bluetooth channel is alive.
     * When Bluetooth is connected, fall back to it; otherwise fail the wait immediately so the send
     * does not spin until the connect timeout.
     */
    fun onLanUnavailable(reason: String) {
        if (state !is TransferState.Connecting || pendingSend == null) return
        awaitingLan = false
        val ble = channels["ble"]
        if (ble != null && (channels["lan"] == null || capabilities["lan"] == null)) {
            selectPreferredChannel()
            if (state !is TransferState.Connecting) return
            // Re-announce capability over Bluetooth to prompt the peer in case its capability was missed.
            scope.launch {
                runCatching {
                    sendWithBackpressure(TransferMessage.capability(
                        version = 1L,
                        maxChunkBytes = 3072L,
                        maxWindow = 4L
                    ).encode(3072), ble, jobBound = false)
                }
            }
            connectTimeoutJob?.cancel()
            connectTimeoutJob = scope.launch {
                delay(3000L)
                if (state is TransferState.Connecting) {
                    pendingSend = null
                    failTransfer("This peer has not advertised file transfer support")
                }
            }
            return
        }
        connectTimeoutJob?.cancel(); connectTimeoutJob = null
        pendingSend = null
        failTransfer(reason)
    }
    var backgroundAllowed = false
        internal set
    var onLeaseChanged: ((Boolean) -> Unit)? = null
    var onStateChanged: ((TransferState) -> Unit)? = null
    /** Requests one bounded automatic LAN attempt after a pause; transport policy still decides. */
    var onLanRequired: (() -> Unit)? = null

    val isBusy: Boolean
        get() = preparing || offerAssembly != null || state is TransferState.Connecting ||
                state is TransferState.WaitingForPeerApproval ||
                state is TransferState.IncomingOffer ||
                state is TransferState.Transferring ||
                state is TransferState.Paused

    val isPaused: Boolean get() = state is TransferState.Paused

    var onDemandLanConnection: (() -> Boolean)? = null
    private var pendingSend: (() -> Unit)? = null
    private var awaitingLan = false
    private var connectTimeoutJob: Job? = null

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    internal var activeChannel by mutableStateOf<SecuredChannel?>(null); private set
    private val channels = mutableMapOf<String, SecuredChannel>()
    private val capabilities = mutableMapOf<String, TransferMessage>()
    private var preparation: Job? = null
    var preparing by mutableStateOf(false); private set
    private var transferJob: Job? = null

    private val ingress by lazy {
        TransferIngress(scope) { descriptor, operation, bytes ->
            val channel = channels[descriptor.transport]
            try {
                if (operation == epoch && channel?.descriptor == descriptor && handle(descriptor, bytes) == DataHandling.HANDLED && operation == epoch) {
                    channel.received(bytes)
                }
            } catch (error: CancellationException) { throw error }
              catch (error: Exception) {
                if (operation == epoch) failTransfer("Transfer receive failed: ${error.message}")
            }
        }
    }
    private var epoch = UUID.randomUUID()
        set(value) { field = value; ingress.invalidate() }
    private var capacityRevision = 0L
    private var sendingFile: TransferFile? = null
    private var senderFileIndex = 0
    private val retiredBatches = java.util.ArrayDeque<String>()
    private var currentBatch: TransferBatch? = null
    private var transferPeerDeviceId: String? = null
    private var transferPeerFingerprint: String? = null

    // Logical checkpoints survive process death; channel generations and sealed work remain process-local.
    private var pausedTransport: String? = null
    private var pausedFileIndex = 0
    private var pausedFileOffset = 0L
    private var pausedCompletedBytes = 0L
    private var pauseTimerJob: Job? = null
    private var resumeJob: Job? = null
    private var upgradeJob: Job? = null
    private var statusDeferred: CompletableDeferred<TransferMessage>? = null
    private var allowBleResume = false

    private data class RetainedResult(
        val batchId: String,
        val fileId: String,
        val fileSize: Long,
        val result: TransferMessage,
        val peerId: String,
        val peerFingerprint: String,
    )
    /** The last verified result this receiver sent, replayable when a resume lands after the file. */
    private var retainedFileResult: RetainedResult? = null
    private var retainedBatch: TransferBatch? = null
    private var offerReplayed = false
    private var restoredSender = false
    /**
     * Guards [fileResultDeferred]/[receivedFileResult]. Chunk delivery may run on a session thread
     * while the sender coroutine waits, so reading the pending result then installing the waiter
     * must be one atomic step or the result can land in the gap and stall until the timeout.
     */
    private val fileResultLock = Any()

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
    private var sendWindow: TransferSendWindow? = null
    private val senderChunkBytes get() = sendWindow?.chunkBytes ?: peerMaxChunkBytes
    private val sendCreditBytes: Long
        get() = sendWindow?.creditBytes ?: (peerMaxChunkBytes * peerMaxWindow)

    // Cumulative ACKs may end within a chunk; credit must fit the entire next chunk.
    private val hasSendCredit: Boolean
        get() {
            val next = minOf(senderChunkBytes, ((sendingFile?.size ?: sentBytes) - sentBytes).coerceAtLeast(0))
            return sentBytes - acknowledgedBytes <= sendCreditBytes - next
        }

    // Sender flow control & backpressure
    @Volatile private var sentBytes: Long = 0L
    @Volatile private var acknowledgedBytes: Long = 0L
    /** When the last cumulative ACK arrived; a receiver-initiated BLE fallback yields to a live LAN. */
    @Volatile private var lastAckAtMillis: Long? = null
    /** When the current sender stream started, used to give a fresh LAN resume time to produce ACKs. */
    @Volatile private var streamStartedAtMillis: Long? = null
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
    private var receiverAckChunkBytes = 3072L
    private var ackJob: Job? = null
    private var ackTimerJob: Job? = null
    private var lastReceiverUiUpdate: Long = 0L

    private var recoveryStore = recoveryFile?.let(::TransferRecoveryStore)
    private var recoveryStarted = false
    private data class RecoveryWrite(val snapshot: TransferCheckpoint?, val storage: TransferReceiveStorage?, val done: CompletableDeferred<Unit>? = null)
    private val recoveryWrites = Channel<RecoveryWrite>(Channel.CONFLATED, onUndeliveredElement = {
        it.done?.completeExceptionally(SessionException(SessionFailure.CANCELLED))
    })
    private var recoveryReady = CompletableDeferred<Unit>()
    private var recoveryLocal: String? = null
    private var recoveryPeer: ChannelDescriptor? = null
    private var checkpointAt = 0L
    private var checkpointPosition: String? = null
    private var pauseExpiresAt: Long? = null
    private var pauseDeadline: Long? = null
    private var resumeAttemptChannel: ChannelDescriptor? = null
    private var nextResumeAttemptAt = 0L
    private var interruptedOffer: TransferState? = null
    private val ownedSourceGrants = mutableSetOf<Uri>()
    private var finalizationRetired: ChannelDescriptor? = null
    private var finalizationResumed = false
    private var receiptExpiry: Job? = null
    private var receiptDeadline: Long? = null
    private var failedRecovery: TransferCheckpoint? = null

    init {
        if (recoveryStore == null) recoveryReady.complete(Unit) else startRecoveryWorkers()
    }

    /** Application.onCreate runs after Android attaches the base Context. */
    fun restoreOnLaunch() {
        if (recoveryStarted || context == null) return
        recoveryStore = TransferRecoveryStore(File(context.noBackupFilesDir, "transfer/checkpoint.bin"))
        recoveryReady = CompletableDeferred()
        startRecoveryWorkers()
    }

    private fun startRecoveryWorkers() {
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

    private fun checkpoint(force: Boolean = false, publishingIdentity: String? = null): CompletableDeferred<Unit>? {
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
        recoveryWrites.trySend(RecoveryWrite(snapshot, if (receiving) receiverStorage else null, done))
        return done
    }

    private suspend fun restoreRecovery(snapshot: TransferCheckpoint, local: String) {
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
            retainedFileResult = RetainedResult(batch.id, file.id, file.size,
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
            retainedFileResult = RetainedResult(batch.id, file.id, file.size,
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

    private var progressJob: Job? = null
    private var progressRate = TransferRate()
    private var progressEpoch: UUID? = null
    private var progressSampleAt = 0L
    private var progressSpeed = 0.0

    private fun updateState(newState: TransferState) {
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

    private fun chunkLimit(descriptor: ChannelDescriptor?) =
        if (descriptor?.transport == "lan" && descriptor.maximumDataBytes >= 262144) 262016 else 3072

    override fun available(channel: SecuredChannel) {
        val transport = channel.descriptor.transport
        if (transport != "lan" && transport != "ble") return
        // A paused batch has no active channel, so its peer identity must outlive the channel that
        // paused it; otherwise a different peer's channel could be rebound to the retained prefix.
        val peerId = activeChannel?.descriptor?.peer?.deviceId ?: transferPeerDeviceId
        val peerFingerprint = activeChannel?.descriptor?.peer?.fingerprint ?: transferPeerFingerprint
        if (peerId != null && (peerId != channel.descriptor.peer.deviceId ||
                peerFingerprint != channel.descriptor.peer.fingerprint)) return
        if (channels[transport]?.descriptor == channel.descriptor) return
        channels[transport]?.let { retired(it.descriptor) }
        channels[transport] = channel
        if (!recoveryReady.isCompleted) {
            scope.launch { recoveryReady.await(); if (channels[transport] === channel) { channels.remove(transport); available(channel) } }
            return
        }
        selectPreferredChannel()
        scope.launch {
            val limit = chunkLimit(channel.descriptor)
            val versions = if (limit > 131072) listOf(2L, 3L) else listOf(if (limit > 3072) 2L else 1L)
            for (version in versions) {
                if (channels[transport] !== channel) return@launch
                val chunk = if (version == 2L) minOf(131072, limit) else limit
                try {
                    sendWithBackpressure(TransferMessage.capability(version, chunk.toLong(),
                        if (transport == "ble") 4 else if (chunk > 3072) 8 else 64).encode(limit), channel, jobBound = false)
                } catch (error: CancellationException) { throw error }
                  catch (_: Exception) { return@launch }
            }
        }
    }

    private fun selectPreferredChannel() {
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

    private fun applyCapability(message: TransferMessage) {
        peerCompatible = true
        peerMaxChunkBytes = message.number(1).coerceAtMost(when (message.number(0)) {
            3L -> chunkLimit(activeChannel?.descriptor).toLong()
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

    override fun retired(descriptor: ChannelDescriptor) {
        if (channels[descriptor.transport]?.descriptor != descriptor) return
        ingress.invalidate(descriptor)
        channels.remove(descriptor.transport)
        capabilities.remove(descriptor.transport)
        clearCapacityWaiters()
        if (descriptor != activeChannel?.descriptor) {
            refreshPausedCapability()
            return
        }
        val previous = state
        activeChannel = null
        recoveryPeer = descriptor
        peerConnected = false
        peerCompatible = false
        when {
            previous is TransferState.Transferring && finalizing -> finalizationRetired = descriptor
            previous is TransferState.Transferring && !finalizing -> pauseTransfer(descriptor, previous)
            previous is TransferState.IncomingOffer || previous is TransferState.WaitingForPeerApproval -> pauseOffer(descriptor, previous)
            preparing -> Unit
            previous is TransferState.Paused -> {
                // A resume attempt lost its channel before it completed; keep the retained prefix.
                epoch = UUID.randomUUID()
                resumeJob?.cancel(); resumeJob = null
                statusDeferred?.cancel(); statusDeferred = null
                startPauseTimer()
            }
            isBusy -> {
                updateState(TransferState.Failed("Connection closed. Send the files again using the remaining connection."))
                cleanupTransfer()
            }
            else -> cleanupTransfer()
        }
        selectPreferredChannel()
    }

    private fun clearCapacityWaiters() {
        capacityRevision++
        val pending = ArrayList<CompletableDeferred<Unit>>()
        while (true) {
            val waiter = capacityWaiters.poll() ?: break
            pending.add(waiter)
        }
        // Resumption can synchronously enqueue another waiter; it belongs to the next notification.
        pending.forEach { it.complete(Unit) }
    }

    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        if (channels[descriptor.transport]?.descriptor != descriptor) return
        clearCapacityWaiters()
        if (descriptor != activeChannel?.descriptor) return
        checkCreditAndResume()
        flushAck()
        if (state is TransferState.Paused && !resumeInterruptedOffer()) {
            if (receiving) { if (allowBleResume) requestPeerContinuation() } else attemptResume()
        }
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
                // Admission stays cancellable; the session protects records only after nonce ownership.
                channel.sendData(data)
                return
            } catch (_: SessionBackpressure) {
                if (revision == capacityRevision) withTimeout(10000) { waiter.await() }
            } finally { capacityWaiters.remove(waiter) }
        }
    }

    override suspend fun ingest(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        val kind = TransferMessage.peekKind(bytes)
        // A resume must observe all earlier writes; a blocked provider cannot retain it indefinitely.
        if (kind == 10 && withTimeoutOrNull(10000) { ingress.drain(); true } != true) {
            retired(descriptor); return DataHandling.DISCARDED
        }
        // Receiver takeover shares the chunk consumer so later old-channel writes cannot cross it.
        if (kind != 5 && !(kind == 10 && receiving)) return handle(descriptor, bytes)
        val operation = epoch
        // Peer limits describe its receiver; this FIFO must cover our advertised receive credit.
        val chunk = chunkLimit(descriptor)
        val window = if (descriptor.transport == "ble") 4 else if (chunk > 3072) 8 else 64
        val accepted = ingress.enqueue(descriptor, operation, bytes,
            minOf(chunk * window + 65536, 2 * 1024 * 1024), minOf(64, window * 8)) {
            operation == epoch && channels[descriptor.transport]?.descriptor == descriptor
        }
        return if (accepted) DataHandling.QUEUED else DataHandling.DISCARDED
    }

    override suspend fun drain(descriptor: ChannelDescriptor) {
        if (channels[descriptor.transport]?.descriptor != descriptor) return
        val drained = withTimeoutOrNull(10000) { ingress.drain(descriptor); true } ?: false
        if (!drained) retired(descriptor)
    }

    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        recoveryReady.await()
        val operation = epoch
        val limit = chunkLimit(descriptor)
        // Chunk CBOR decoding stays on Default; storage uses its separate IO lane.
        val message = try {
            withContext(Dispatchers.Default) { TransferMessage.decode(bytes, limit) }
                ?: return DataHandling.UNRECOGNIZED
        } catch (_: TransferWireException) { return DataHandling.DISCARDED }
          catch (_: SessionException) { return DataHandling.UNRECOGNIZED }
        if (operation != epoch || channels[descriptor.transport]?.descriptor != descriptor) return DataHandling.DISCARDED
        if (message.kind == 1L) {
            capabilities[descriptor.transport] = message
            if (!isBusy || state is TransferState.Connecting || state is TransferState.Paused) selectPreferredChannel()
            if (descriptor == activeChannel?.descriptor) {
                peerCompatible = true
                if (state !is TransferState.Transferring && transferJob?.isActive != true) applyCapability(message)
                if (state is TransferState.Paused) {
                    if (resumeInterruptedOffer()) return DataHandling.HANDLED
                    refreshPausedCapability()
                    if (receiving) { if (allowBleResume) requestPeerContinuation() } else attemptResume()
                }
            } else if (state is TransferState.Paused) {
                refreshPausedCapability()
                if (activeChannel?.descriptor?.transport == "lan" && peerCompatible) {
                    if (receiving) { if (allowBleResume) requestPeerContinuation() } else attemptResume()
                }
            } else if (descriptor.transport == "lan" && state is TransferState.Transferring) {
                // LAN is preferred even after a deliberate Bluetooth continuation. The receiver
                // answers the resume while it is still transferring, so the stream can switch
                // without a pause card once the new channel proves compatible.
                maybeUpgradeToLan(descriptor)
            }
            return DataHandling.HANDLED
        }
        // Resume and status may name the batch a new channel is taking over, so they are routed
        // before the active-descriptor guard. A resume for an unknown batch still receives a status.
        if (message.kind == 10L) {
            handleResume(message, descriptor)
            return DataHandling.HANDLED
        }
        if (message.kind == 11L) {
            if (message.string(0) == currentBatch?.id) handleStatus(message)
            return DataHandling.HANDLED
        }
        if (message.kind == 9L && message.string(0) == currentBatch?.id) {
            processMessage(message, descriptor.peer.deviceName, descriptor)
            return DataHandling.HANDLED
        }
        if (message.kind == 2L && (message.string(0) == currentBatch?.id || message.string(0) == retainedBatch?.id)) {
            processMessage(message, descriptor.peer.deviceName, descriptor)
            return DataHandling.HANDLED
        }
        if (descriptor != activeChannel?.descriptor) return DataHandling.DISCARDED
        if (message.kind == 5L) return handleChunk(message)
        processMessage(message, descriptor.peer.deviceName, descriptor)
        return DataHandling.HANDLED
    }

    private suspend fun processMessage(message: TransferMessage, peerName: String, descriptor: ChannelDescriptor) {
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

    // MARK: - Pause and Resume

    private fun expirePausedIfNeeded(): Boolean {
        if (state !is TransferState.Paused || pauseDeadline?.let { clock() >= it } != true) return false
        failTransfer("Transfer paused for too long without a connection. Send the files again.")
        return true
    }

    private fun claimResumeAttempt(descriptor: ChannelDescriptor): Boolean {
        val now = clock()
        if (resumeAttemptChannel == descriptor && now < nextResumeAttemptAt) return false
        resumeAttemptChannel = descriptor; nextResumeAttemptAt = now + 2000
        return true
    }

    private fun pauseOnConfirmationTimeout() {
        val current = state as? TransferState.Transferring ?: return
        val channel = activeChannel ?: return
        pauseTransfer(channel.descriptor, current)
        selectPreferredChannel()
    }

    private fun pauseOffer(descriptor: ChannelDescriptor, previous: TransferState) {
        val batch = currentBatch ?: return
        interruptedOffer = previous
        recoveryPeer = descriptor; pausedTransport = descriptor.transport
        pauseExpiresAt = pauseExpiresAt ?: (System.currentTimeMillis() + pauseTimeoutMillis)
        pauseDeadline = pauseDeadline ?: (clock() + pauseTimeoutMillis)
        pausedFileIndex = 0; pausedFileOffset = 0; pausedCompletedBytes = 0
        epoch = UUID.randomUUID()
        val file = batch.files.first()
        updateState(TransferState.Paused(batch, 1, file.name, 0, file.size, 0, "Waiting to reconnect", false))
        startPauseTimer(); checkpoint(force = true)
    }

    private fun resumeInterruptedOffer(): Boolean {
        if (expirePausedIfNeeded()) return true
        val previous = interruptedOffer ?: return false
        if (!peerCompatible || state !is TransferState.Paused) return true
        val channel = activeChannel ?: return true
        if (pausedTransport == "lan" && channel.descriptor.transport == "ble" && !allowBleResume) {
            refreshPausedCapability(); return true
        }
        interruptedOffer = null
        pauseTimerJob?.cancel(); pauseTimerJob = null; pauseExpiresAt = null; pauseDeadline = null
        offerReplayed = previous is TransferState.WaitingForPeerApproval
        updateState(previous)
        onLeaseChanged?.invoke(true)
        if (previous is TransferState.WaitingForPeerApproval) sendOfferBatch(previous.batch, channel)
        return true
    }

    /**
     * Retains a mid-stream batch after its active channel retired. Nothing is published, discarded
     * or leased away here: the partial, destination grant and foreground ownership stay alive for
     * [pauseTimeoutMillis], and only Cancel, a permanent recovery failure or the timer ends them.
     */
    private fun pauseTransfer(descriptor: ChannelDescriptor, previous: TransferState.Transferring) {
        val batch = previous.batch
        val fileIndex = if (receiving) receiverCurrentFileIndex else senderFileIndex
        val file = batch.files.getOrNull(fileIndex) ?: run {
            failTransfer("Connection closed. Send the files again using the remaining connection.")
            return
        }
        if (receiving && receiverStorage == null) {
            failTransfer("Connection closed while saving ${file.name}. Send the files again.")
            return
        }
        pausedTransport = descriptor.transport
        recoveryPeer = descriptor
        pauseExpiresAt = pauseExpiresAt ?: (System.currentTimeMillis() + pauseTimeoutMillis)
        pauseDeadline = pauseDeadline ?: (clock() + pauseTimeoutMillis)
        pausedFileIndex = fileIndex
        pausedFileOffset = (if (receiving) receiverWrittenBytes else acknowledgedBytes).coerceIn(0L, file.size)
        pausedCompletedBytes = if (receiving) {
            (receiverTotalTransferred - receiverWrittenBytes).coerceAtLeast(0L)
        } else {
            batch.files.take(fileIndex).fold(0L) { total, item -> total + item.size }
        }
        allowBleResume = false
        transferJob?.cancel(); transferJob = null
        ackJob?.cancel(); ackJob = null
        ackTimerJob?.cancel(); ackTimerJob = null
        fileResultDeferred?.cancel(); fileResultDeferred = null
        resumeCredit()
        resumeJob?.cancel(); resumeJob = null
        upgradeJob?.cancel(); upgradeJob = null
        statusDeferred?.cancel(); statusDeferred = null
        // Old-channel callbacks must not touch the retained batch after the channel is gone.
        epoch = UUID.randomUUID()
        val reason = if (descriptor.transport == "lan") "Local network connection lost" else "Bluetooth connection lost"
        updateState(
            TransferState.Paused(
                batch = batch,
                fileIndex = fileIndex + 1,
                fileName = file.name,
                fileBytes = pausedFileOffset,
                fileSize = file.size,
                totalBytes = pausedCompletedBytes + pausedFileOffset,
                reason = reason,
                canResumeOverBle = false
            )
        )
        startPauseTimer()
        checkpoint(force = true)
        // Automatic LAN policy decides whether a new window may open; an explicit Disconnect still
        // wins, so a paused batch never forces LAN back on by itself.
        onLanRequired?.invoke()
    }

    private fun startPauseTimer() {
        pauseTimerJob?.cancel()
        val operation = epoch
        pauseTimerJob = scope.launch {
            delay((pauseDeadline?.minus(clock()) ?: pauseTimeoutMillis).coerceAtLeast(0))
            if (operation == epoch && state is TransferState.Paused) {
                failTransfer("Transfer paused for too long without a connection. Send the files again.")
            }
        }
    }

    /**
     * Explicit Bluetooth continuation for either side. The sender asks the receiver to continue at
     * its acknowledged offset; the receiver asks the sender to validate the prefix it already holds
     * and stream the rest over BLE. Both use the same resume/status kinds with no framing change.
     */
    fun resumeOverBluetooth() {
        if (state !is TransferState.Paused) return
        if (pausedTransport != "lan") return
        allowBleResume = true
        val ble = channels["ble"]
        if (ble != null && activeChannel?.descriptor != ble.descriptor) {
            activeChannel = ble
            peerConnected = true
            peerCompatible = false
            peerMaxChunkBytes = 3072
            peerMaxWindow = 64
            capabilities["ble"]?.let { applyCapability(it) }
            onChannelChanged()
        }
        refreshPausedCapability()
        if (!peerCompatible) return
        if (!resumeInterruptedOffer()) {
            if (receiving) requestPeerContinuation() else attemptResume()
        }
    }

    private fun refreshPausedCapability() {
        val paused = state as? TransferState.Paused ?: return
        val canBle = !allowBleResume && pausedTransport == "lan" &&
            channels["lan"] == null && channels["ble"] != null && capabilities["ble"] != null
        if (paused.canResumeOverBle != canBle) updateState(paused.copy(canResumeOverBle = canBle))
    }

    /**
     * Sender-initiated handshake. The prefix hash proves the receiver's retained bytes are the ones
     * this source would have sent; the receiver's answer is authoritative for the continue offset.
     */
    private fun attemptResume() {
        if (expirePausedIfNeeded()) return
        val paused = state as? TransferState.Paused ?: return
        if (receiving || resumeJob?.isActive == true) return
        val channel = activeChannel ?: return
        if (!peerCompatible) return
        val transport = channel.descriptor.transport
        val allowed = when {
            transport == "lan" -> true
            pausedTransport == "lan" -> allowBleResume
            else -> true
        }
        if (!allowed) { refreshPausedCapability(); return }
        if (!claimResumeAttempt(channel.descriptor)) return
        val batch = paused.batch
        val fileIndex = pausedFileIndex
        val file = batch.files.getOrNull(fileIndex) ?: return
        val completedBefore = pausedCompletedBytes
        val operation = epoch
        resumeJob = scope.launch {
            var offset = pausedFileOffset
            var retriedOffset = false
            var restarted = false
            while (true) {
                val prefix = try {
                    filePrefixDigest(file, offset)
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    if (operation == epoch) failTransfer("Cannot read ${file.name} to resume: ${error.message}")
                    return@launch
                }
                val status = requestStatus(
                    channel,
                    TransferMessage.resume(batch.id, file.id, offset, prefix).encode(chunkLimit(channel.descriptor))
                ) ?: run {
                    return@launch
                }
                if (operation != epoch) return@launch
                when (status.number(3)) {
                    0L -> { offset = status.number(2).coerceIn(0L, file.size); break }
                    1L -> {
                        if (retriedOffset) {
                            failTransfer("The other device keeps reporting a different transfer offset.")
                            return@launch
                        }
                        retriedOffset = true
                        offset = status.number(2).coerceIn(0L, file.size)
                    }
                    2L -> {
                        if (restarted) {
                            failTransfer("The retained file no longer matches. Send the files again.")
                            return@launch
                        }
                        restarted = true
                        offset = 0L
                    }
                    else -> {
                        return@launch
                    }
                }
            }
            withContext(dispatcher) {
                if (operation != epoch) return@withContext
                pauseTimerJob?.cancel(); pauseTimerJob = null
                onLeaseChanged?.invoke(true)
                updateState(
                    TransferState.Transferring(
                        batch = batch,
                        fileIndex = fileIndex + 1,
                        fileName = file.name,
                        fileBytes = offset,
                        fileSize = file.size,
                        totalBytes = completedBefore + offset,
                        speedBps = 0.0
                    )
                )
                transferJob = scope.launch {
                    try {
                        streamBatchFrom(batch, fileIndex, offset, completedBefore, recovered = true)
                    } catch (error: TimeoutCancellationException) {
                        if (operation == epoch) pauseOnConfirmationTimeout()
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Exception) {
                        if (operation == epoch) failTransfer("Source read failed: ${error.message}")
                    }
                }
            }
        }
    }

    /**
     * Receiver-initiated continuation. The receiver hashes what it retained and asks the sender;
     * the sender validates its own source prefix and, when it matches, starts streaming from the
     * retained offset. The request follows whichever channel is currently preferred, so a LAN that
     * returns while the user is opting into Bluetooth wins instead of racing the sender.
     */
    private fun requestPeerContinuation() {
        if (expirePausedIfNeeded()) return
        val paused = state as? TransferState.Paused ?: return
        if (!receiving || !allowBleResume || resumeJob?.isActive == true) return
        val candidate = activeChannel ?: return
        if (!peerCompatible || candidate.descriptor.transport != "ble" || !claimResumeAttempt(candidate.descriptor)) return
        val batch = paused.batch
        val fileIndex = receiverCurrentFileIndex
        val file = batch.files.getOrNull(fileIndex) ?: return
        val operation = epoch
        resumeJob = scope.launch {
            var restarted = false
            try {
                while (true) {
                    if (operation != epoch) return@launch
                    val channel = activeChannel ?: break
                    if (!peerCompatible || channel.descriptor.transport != "ble") break
                    val storage = receiverStorage ?: break
                    val offset = receiverWrittenBytes.coerceIn(0L, file.size)
                    val prefix = withContext(receiveDispatcher) {
                        runCatching { storage.prefixDigest(offset) }.getOrNull()
                    } ?: break
                    if (operation != epoch || activeChannel !== channel) break
                    val status = requestStatus(
                        channel,
                        TransferMessage.resume(batch.id, file.id, offset, prefix)
                            .encode(chunkLimit(channel.descriptor))
                    ) ?: break
                    if (operation != epoch) return@launch
                    when (status.number(3)) {
                        0L -> {
                            // The sender streams on the channel that carried the request. If the
                            // preferred channel changed meanwhile, ask again there so both sides
                            // converge instead of splitting across transports.
                            if (activeChannel?.descriptor != channel.descriptor) continue
                            withContext(dispatcher) {
                                if (operation != epoch || state !is TransferState.Paused) return@withContext
                                pauseTimerJob?.cancel(); pauseTimerJob = null
                                lastAckedWrittenBytes = receiverWrittenBytes
                                val current = state as? TransferState.Paused ?: return@withContext
                                updateState(
                                    TransferState.Transferring(
                                        batch = batch,
                                        fileIndex = fileIndex + 1,
                                        fileName = file.name,
                                        fileBytes = receiverWrittenBytes,
                                        fileSize = file.size,
                                        totalBytes = current.totalBytes,
                                        speedBps = 0.0
                                    )
                                )
                            }
                            return@launch
                        }
                        2L -> {
                            if (restarted) break
                            restarted = true
                            if (!resetReceiverFile(batch, file)) break
                            val current = state as? TransferState.Paused
                            if (current != null) {
                                updateState(current.copy(fileBytes = 0L, totalBytes = receiverTotalTransferred))
                            }
                        }
                        // State 1 would require rewinding retained bytes; 3/4/timeout leave the
                        // batch paused so LAN, another attempt or Cancel can still decide.
                        else -> break
                    }
                }
            } finally {
                withContext(NonCancellable + dispatcher) {
                    if (operation == epoch && state is TransferState.Paused) {
                        refreshPausedCapability()
                    }
                }
            }
        }
    }

    private suspend fun requestStatus(channel: SecuredChannel, request: ByteArray): TransferMessage? {
        val deferred = CompletableDeferred<TransferMessage>()
        statusDeferred = deferred
        return try {
            sendWithBackpressure(request, channel)
            withTimeout(resumeTimeoutMillis) { deferred.await() }
        } catch (error: TimeoutCancellationException) {
            null
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            null
        } finally {
            if (statusDeferred === deferred) statusDeferred = null
        }
    }

    private fun handleStatus(message: TransferMessage) {
        val batch = currentBatch ?: return
        if (message.string(0) != batch.id) return
        // The waiter belongs to whichever side initiated the handshake: the sender after its own
        // resume, or the receiver after a receiver-initiated Bluetooth continuation.
        val index = if (receiving) receiverCurrentFileIndex else senderFileIndex
        val file = batch.files.getOrNull(index) ?: return
        if (message.string(1) != file.id) return
        if (message.number(2) !in 0..file.size) return
        val deferred = statusDeferred ?: return
        if (!receiving && message.number(3) == 0L && message.number(2) in 0..file.size) {
            sendingFile = file
            sentBytes = message.number(2)
        }
        statusDeferred = null
        deferred.complete(message)
    }

    /**
     * Receiver side of the handshake: verify the retained prefix, rebind to the sender's chosen
     * channel and answer with the offset the sender must continue from.
     */
    private suspend fun handleResume(message: TransferMessage, descriptor: ChannelDescriptor) {
        val operation = epoch
        val channel = channels[descriptor.transport] ?: return
        if (channel.descriptor != descriptor) return
        expirePausedIfNeeded()
        if (currentBatch == null && receiptDeadline?.let { clock() >= it } == true) {
            retainedFileResult = null; retainedBatch = null; receiptDeadline = null
            if (recoveryStore != null) recoveryWrites.trySend(RecoveryWrite(null, null))
        }
        val batchId = message.string(0)
        val fileId = message.string(1)
        val offset = message.number(2)
        val prefix = message.bytes(3)

        val proof = retainedFileResult
        val completedFile = retainedBatch?.takeIf { it.id == batchId }?.files?.find { it.id == fileId }
            ?: currentBatch?.takeIf { receiving && it.id == batchId }?.files?.take(receiverCurrentFileIndex)?.find { it.id == fileId }
        val retained = if (proof != null && completedFile != null) RetainedResult(batchId, fileId, completedFile.size,
            TransferMessage.fileResult(batchId, fileId, 0, completedFile.sha256), proof.peerId, proof.peerFingerprint) else proof
        if (retained != null && retained.batchId == batchId && retained.fileId == fileId &&
            retained.peerId == descriptor.peer.deviceId && retained.peerFingerprint == descriptor.peer.fingerprint) {
            // The file was already verified before the channel died. Replaying its result lets the
            // sender skip the last-chunk wait instead of failing on a resume for a closed file.
            bindResumeChannel(channel)
            runCatching {
                sendWithBackpressure(
                    TransferMessage.status(batchId, fileId, retained.fileSize, 0L).encode(),
                    channel,
                    jobBound = false
                )
                sendWithBackpressure(retained.result.encode(), channel, jobBound = false)
            }
            if (operation != epoch || channels[descriptor.transport] !== channel) return
            continueAfterRetainedReplay()
            return
        }

        // A resume from the data receiver asks this device, the sender, to continue over the
        // channel the receiver chose. It uses the same kinds and is validated against our source.
        if (!receiving) {
            handlePeerResume(batchId, fileId, offset, prefix, channel)
            return
        }

        val batch = currentBatch
        if (batch == null || batch.id != batchId || !receiving ||
            (state !is TransferState.Paused && state !is TransferState.Transferring)) {
            replyStatus(channel, batchId, fileId, 0L, 4L)
            return
        }
        val fileIndex = batch.files.indexOfFirst { it.id == fileId }
        if (fileIndex == -1 || fileIndex != receiverCurrentFileIndex) {
            replyStatus(channel, batchId, fileId, receiverWrittenBytes, 3L)
            return
        }
        val file = batch.files[fileIndex]
        val storage = receiverStorage
        if (storage == null) {
            replyStatus(channel, batchId, fileId, 0L, if (finalizing) 3L else 4L)
            return
        }
        if (offset > receiverWrittenBytes) {
            replyStatus(channel, batchId, fileId, receiverWrittenBytes, 1L)
            return
        }
        val matches = try { storage.matchesPrefix(offset, prefix) }
        catch (error: CancellationException) { throw error }
        catch (_: Exception) { replyStatus(channel, batchId, fileId, 0, 3); return }
        if (operation != epoch || channels[descriptor.transport] !== channel || receiverStorage !== storage) return
        if (!matches) {
            if (!resetReceiverFile(batch, file)) {
                replyStatus(channel, batchId, fileId, 0L, 4L)
                return
            }
            if (operation != epoch || channels[descriptor.transport] !== channel) return
            bindResumeChannel(channel)
            replyStatus(channel, batchId, fileId, 0L, 2L)
            return
        }
        bindResumeChannel(channel)
        pauseTimerJob?.cancel(); pauseTimerJob = null
        onLeaseChanged?.invoke(true)
        lastAckedWrittenBytes = receiverWrittenBytes
        updateState(
            TransferState.Transferring(
                batch = batch,
                fileIndex = fileIndex + 1,
                fileName = file.name,
                fileBytes = receiverWrittenBytes,
                fileSize = file.size,
                totalBytes = receiverTotalTransferred,
                speedBps = 0.0
            )
        )
        replyStatus(channel, batchId, fileId, receiverWrittenBytes, 0L)
        if (receiverWrittenBytes == file.size) finalizeReceiverFile(batch)
    }

    private fun bindResumeChannel(channel: SecuredChannel) {
        if (finalizing) finalizationResumed = true
        activeChannel = channel
        peerConnected = true
        peerCompatible = true
        peerMaxChunkBytes = 3072
        peerMaxWindow = 64
        capabilities[channel.descriptor.transport]?.let { applyCapability(it) }
        onChannelChanged()
    }

    /**
     * Sender side of a receiver-initiated continuation. The receiver asks over the channel it
     * prefers; we prove our source still begins with its retained prefix and then stream the rest
     * from its offset. A reliable LAN is not pulled down to BLE, but a stalled one yields.
     */
    private suspend fun handlePeerResume(
        batchId: String,
        fileId: String,
        offset: Long,
        prefix: ByteArray,
        channel: SecuredChannel
    ) {
        val lookup = epoch
        if (resumeJob?.isActive == true || upgradeJob?.isActive == true) { replyStatus(channel, batchId, fileId, 0, 3); return }
        val batch = currentBatch
        if (batch == null || batch.id != batchId) { replyStatus(channel, batchId, fileId, 0L, 4L); return }
        val fileIndex = batch.files.indexOfFirst { it.id == fileId }
        val file = batch.files.getOrNull(fileIndex)
        if (file == null) { replyStatus(channel, batchId, fileId, 0L, 3L); return }
        val previous = state
        val currentIndex = when (previous) {
            is TransferState.Paused -> pausedFileIndex
            is TransferState.Transferring -> senderFileIndex
            else -> { replyStatus(channel, batchId, fileId, 0L, 4L); return }
        }
        if (fileIndex != currentIndex) { replyStatus(channel, batchId, fileId, 0L, 3L); return }

        // A receiver can only ask us to leave LAN when its own LAN is gone. Give a freshly resumed
        // LAN stream a few seconds to start producing ACKs before treating it as stalled.
        if (channel.descriptor.transport == "ble" && previous is TransferState.Transferring &&
            activeChannel?.descriptor?.transport == "lan") {
            val lastAck = lastAckAtMillis
            val started = streamStartedAtMillis
            val acking = lastAck != null && clock() - lastAck < 3000L
            val fresh = lastAck == null && started != null && clock() - started < 3000L &&
                sentBytes > acknowledgedBytes
            if (acking || fresh) { replyStatus(channel, batchId, fileId, 0L, 3L); return }
        }

        val sent = if (restoredSender) file.size else sentBytes.coerceIn(0L, file.size)
        if (offset < 0 || offset > sent) { replyStatus(channel, batchId, fileId, sent, 1L); return }
        val matches = try { filePrefixDigest(file, offset).contentEquals(prefix) }
        catch (error: CancellationException) { throw error }
        catch (_: Exception) { replyStatus(channel, batchId, fileId, 0, 4); return }
        if (lookup != epoch || channels[channel.descriptor.transport] !== channel || senderFileIndex != fileIndex) return
        if (previous is TransferState.Paused && state is TransferState.Transferring) { replyStatus(channel, batchId, fileId, 0, 3); return }
        if (channel.descriptor.transport == "ble" && activeChannel?.descriptor?.transport == "lan" &&
            lastAckAtMillis?.let { clock() - it < 3000L } == true) { replyStatus(channel, batchId, fileId, 0, 3); return }
        if (!matches) { replyStatus(channel, batchId, fileId, 0L, 2L); return }

        val completedBefore = if (previous is TransferState.Paused) pausedCompletedBytes
            else batch.files.take(fileIndex).fold(0L) { total, item -> total + item.size }
        // Fence the current stream before binding the requested channel. The receiver already
        // validated its retained prefix; anything still in flight on the old transport is
        // discarded there once it rebinds.
        transferJob?.cancel(); transferJob = null
        resumeJob?.cancel(); resumeJob = null
        upgradeJob?.cancel(); upgradeJob = null
        statusDeferred?.cancel(); statusDeferred = null
        fileResultDeferred?.cancel(); fileResultDeferred = null
        resumeCredit()
        pauseTimerJob?.cancel(); pauseTimerJob = null
        epoch = UUID.randomUUID()
        val operation = epoch
        activeChannel = channel
        peerConnected = true
        peerCompatible = true
        peerMaxChunkBytes = 3072
        peerMaxWindow = 64
        capabilities[channel.descriptor.transport]?.let { applyCapability(it) }
        onChannelChanged()
        updateState(
            TransferState.Transferring(
                batch = batch,
                fileIndex = fileIndex + 1,
                fileName = file.name,
                fileBytes = offset,
                fileSize = file.size,
                totalBytes = completedBefore + offset,
                speedBps = 0.0
            )
        )
        replyStatus(channel, batchId, fileId, offset, 0L)
        if (operation != epoch || activeChannel !== channel) return
        transferJob = scope.launch {
            try {
                streamBatchFrom(batch, fileIndex, offset, completedBefore, recovered = true)
            } catch (error: TimeoutCancellationException) {
                if (operation == epoch) pauseOnConfirmationTimeout()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (operation == epoch) failTransfer("Source read failed: ${error.message}")
            }
        }
    }

    /**
     * Sender-side transport upgrade. A capable LAN channel arriving during a Bluetooth stream
     * triggers the existing resume handshake; the receiver accepts while transferring, reports its
     * actual written offset, and both sides switch without a visible pause.
     */
    private fun maybeUpgradeToLan(descriptor: ChannelDescriptor) {
        if (descriptor.transport != "lan" || receiving) return
        if (state !is TransferState.Transferring) return
        val active = activeChannel ?: return
        if (active.descriptor.transport != "ble") return
        val lan = channels["lan"] ?: return
        if (lan.descriptor != descriptor || capabilities["lan"] == null) return
        if (upgradeJob?.isActive == true || resumeJob?.isActive == true || statusDeferred != null) return
        val batch = currentBatch ?: return
        val fileIndex = senderFileIndex
        val file = batch.files.getOrNull(fileIndex) ?: return
        // At the file-result boundary the stream is idle; wait for the next file's start.
        if (fileResultDeferred != null || sentBytes >= file.size) return
        val completedBefore = batch.files.take(fileIndex).fold(0L) { total, item -> total + item.size }
        val offset = acknowledgedBytes.coerceIn(0L, file.size)
        val streamEpoch = epoch
        upgradeJob = scope.launch {
            val prefix = try {
                filePrefixDigest(file, offset)
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) { return@launch }
            val status = requestStatus(
                lan,
                TransferMessage.resume(batch.id, file.id, offset, prefix)
                    .encode(chunkLimit(lan.descriptor))
            )
            if (epoch != streamEpoch) return@launch
            if (status == null) {
                // Ambiguous: the receiver may already have rebound. Pause and let the preferred
                // channel resume deterministically instead of streaming into a lost stream.
                withContext(dispatcher) {
                    val transferring = state as? TransferState.Transferring ?: return@withContext
                    if (epoch != streamEpoch) return@withContext
                    pauseTransfer(active.descriptor, transferring)
                    selectPreferredChannel()
                }
                return@launch
            }
            val code = status.number(3)
            if (code != 0L && code != 2L) return@launch // The receiver kept the Bluetooth stream.
            val startOffset = if (code == 2L) 0L else status.number(2).coerceIn(0L, file.size)
            withContext(dispatcher) {
                if (epoch != streamEpoch || state !is TransferState.Transferring) return@withContext
                val lan = channels["lan"] ?: return@withContext
                transferJob?.cancel(); transferJob = null
                fileResultDeferred?.cancel(); fileResultDeferred = null
                resumeCredit()
                epoch = UUID.randomUUID()
                val operation = epoch
                activeChannel = lan
                peerConnected = true
                peerCompatible = true
                peerMaxChunkBytes = 3072
                peerMaxWindow = 64
                capabilities["lan"]?.let { applyCapability(it) }
                onChannelChanged()
                updateState(
                    TransferState.Transferring(
                        batch = batch,
                        fileIndex = fileIndex + 1,
                        fileName = file.name,
                        fileBytes = startOffset,
                        fileSize = file.size,
                        totalBytes = completedBefore + startOffset,
                        speedBps = 0.0
                    )
                )
                transferJob = scope.launch {
                    try {
                        streamBatchFrom(batch, fileIndex, startOffset, completedBefore, recovered = true)
                    } catch (error: TimeoutCancellationException) {
                        if (operation == epoch) pauseOnConfirmationTimeout()
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Exception) {
                        if (operation == epoch) failTransfer("Source read failed: ${error.message}")
                    }
                }
            }
        }
    }

    /**
     * When the replayed file was the one before the receiver's current file, the sender resumes the
     * next file at zero; the receiver must already be accepting it, with no second handshake.
     */
    private fun continueAfterRetainedReplay() {
        if (!receiving || state !is TransferState.Paused) return
        val batch = currentBatch ?: return
        if (receiverStorage == null || receiverWrittenBytes != 0L) return
        val file = batch.files.getOrNull(receiverCurrentFileIndex) ?: return
        if (retainedFileResult?.fileId == file.id) return
        pauseTimerJob?.cancel(); pauseTimerJob = null
        lastAckedWrittenBytes = 0L
        updateState(
            TransferState.Transferring(
                batch = batch,
                fileIndex = receiverCurrentFileIndex + 1,
                fileName = file.name,
                fileBytes = 0L,
                fileSize = file.size,
                totalBytes = receiverTotalTransferred,
                speedBps = 0.0
            )
        )
    }

    /** Recreates the current file from zero after the retained prefix failed verification. */
    private suspend fun resetReceiverFile(batch: TransferBatch, file: TransferFile): Boolean {
        val operation = epoch
        val previous = receiverStorage
        receiverStorage = null
        receiverPartFile = null
        receiverPartDocument = null
        withContext(receiveDispatcher) { runCatching { previous?.discard() } }
        if (operation != epoch || currentBatch?.id != batch.id) return false
        receiverTotalTransferred = (receiverTotalTransferred - receiverWrittenBytes).coerceAtLeast(0L)
        receiverWrittenBytes = 0L
        lastAckedWrittenBytes = 0L
        return try {
            prepareReceiverForFile(receiverCurrentFileIndex, batch)
            true
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            false
        }
    }

    private suspend fun replyStatus(channel: SecuredChannel, batch: String, file: String, bytes: Long, status: Long) {
        runCatching {
            sendWithBackpressure(
                TransferMessage.status(batch, file, bytes, status).encode(),
                channel,
                jobBound = false
            )
        }
    }

    private suspend fun filePrefixDigest(file: TransferFile, length: Long): ByteArray = withContext(Dispatchers.IO) {
        if (length < 0 || length > file.size) throw java.io.IOException("Invalid resume offset")
        val digest = MessageDigest.getInstance("SHA-256")
        openSource(file).use { stream ->
            var remaining = length
            val buffer = ByteArray(131072)
            while (remaining > 0) {
                val count = stream.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                if (count < 0) throw java.io.IOException("Source ended before the retained offset")
                if (count == 0) throw java.io.IOException("Source stream made no progress")
                digest.update(buffer, 0, count)
                remaining -= count
            }
        }
        digest.digest()
    }

    private fun skipFully(stream: java.io.InputStream, length: Long) {
        var remaining = length
        val buffer = ByteArray(131072)
        while (remaining > 0) {
            val count = stream.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
            if (count < 0) throw java.io.IOException("Source ended before the retained offset")
            if (count == 0) throw java.io.IOException("Source stream made no progress")
            remaining -= count
        }
    }

    // MARK: - Sender Flow

    fun sendFiles(files: List<File>) = prepareSources(files) { file ->
        prepareFile(file.name, file.length(), sourceFile = file) { FileInputStream(file) }
    }

    fun sendUris(uris: List<Uri>, reviewedPeerDeviceId: String? = null, reviewedPeerFingerprint: String? = null) {
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

    private fun <T> prepareSources(
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

    private suspend fun prepareFile(name: String, size: Long, sourceFile: File? = null, sourceUri: Uri? = null,
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

    private fun startOfferBatch(files: List<TransferFile>, totalBytes: Long, channel: SecuredChannel) {
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

    private fun sendOfferBatch(batch: TransferBatch, channel: SecuredChannel) {
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

    private fun handleAccept(message: TransferMessage) {
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

    private suspend fun streamAcceptedBatch(batch: TransferBatch) =
        streamBatchFrom(batch, startFileIndex = 0, startOffset = 0L, completedBefore = 0L)

    /**
     * Streams from [startFileIndex] at [startOffset], where the receiver already retains
     * [startOffset] bytes of that file and [completedBefore] complete bytes precede it.
     */
    private suspend fun streamBatchFrom(
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
                        val encoded = chunkMsg.encode(chunkLimit(activeChannel?.descriptor))
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

    private fun handleAck(message: TransferMessage) {
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

    private fun resumeCredit() {
        // Detach before waking: an immediate dispatcher can register the next waiter inline.
        val waiting = creditDeferred
        creditDeferred = null
        waiting?.complete(Unit)
    }

    private fun checkCreditAndResume() {
        if (hasSendCredit) resumeCredit()
    }

    private fun handleReject(message: TransferMessage) {
        val current = state
        if (current !is TransferState.WaitingForPeerApproval || message.string(0) != current.batch.id) return
        updateState(TransferState.Rejected(current.batch.id, message.number(1)))
        cleanupTransfer()
    }

    // MARK: - Receiver Flow

    private fun handleOffer(message: TransferMessage, peerName: String, descriptor: ChannelDescriptor) {
        val batchId = message.string(0)
        if (batchId in retiredBatches && retainedBatch?.id != batchId) return
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

    suspend fun acceptIncomingOffer(destinationDir: File) {
        val current = state
        val channel = activeChannel ?: return
        if (current !is TransferState.IncomingOffer) return
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

    private suspend fun handleChunk(message: TransferMessage): DataHandling {
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

    private suspend fun finalizeReceiverFile(batch: TransferBatch) = withContext(NonCancellable) {
        finalizeReceiverFileOwned(batch)
    }

    private suspend fun finalizeReceiverFileOwned(batch: TransferBatch) {
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
        retainedFileResult = RetainedResult(batch.id, file.id, file.size, result,
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

    private fun completeReceiver(batch: TransferBatch) {
        val peer = activeChannel?.descriptor ?: recoveryPeer
        val saved = recoveryLocal?.let { local -> peer?.let {
            TransferCheckpoint(local, it.peer.deviceId, it.peer.fingerprint, batch, true,
                batch.files.lastIndex, batch.files.last().size, "", "", "", "", it.transport,
                System.currentTimeMillis() + pauseTimeoutMillis, 3)
        } }
        updateState(TransferState.Completed(batch.id, batch.files.size, batch.totalBytes))
        cleanupTransfer()
        retainedBatch = batch
        if (saved != null) recoveryWrites.trySend(RecoveryWrite(saved, null))
        expireReceipt(batch.id, pauseTimeoutMillis)
    }

    private fun expireReceipt(batchId: String, remaining: Long) {
        receiptExpiry?.cancel()
        receiptDeadline = clock() + remaining
        receiptExpiry = scope.launch {
            delay(remaining)
            if (retainedFileResult?.batchId == batchId && currentBatch == null) {
                retainedFileResult = null; retainedBatch = null; receiptDeadline = null
                if (recoveryStore != null) recoveryWrites.trySend(RecoveryWrite(null, null))
            }
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

    fun dismiss() {
        receiving = false
        retainedFileResult = null
        updateState(TransferState.Idle)
        cleanupTransfer()
    }

    internal fun invalidate() {
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

    private fun failTransfer(reason: String) {
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

    private fun cleanupTransfer(selectChannel: Boolean = true) {
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
        if (recoveryStore != null) recoveryWrites.trySend(RecoveryWrite(null, null))
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
}

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
