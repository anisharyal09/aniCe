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
    internal val context: Context? = null,
    internal val dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
    internal val clock: () -> Long = { if (context != null) android.os.SystemClock.elapsedRealtime() else System.nanoTime() / 1_000_000L },
    internal val pauseTimeoutMillis: Long = 15 * 60 * 1000L,
    internal val resumeTimeoutMillis: Long = 15000L,
    internal val confirmationTimeoutMillis: Long = 30000L,
    recoveryFile: File? = null,
    internal val receiveDispatcher: CoroutineDispatcher = transferReceiveDispatcher,
    internal val openSource: (TransferFile) -> java.io.InputStream = { file ->
        file.sourceFile?.let(::FileInputStream)
            ?: file.sourceUri?.let { context?.contentResolver?.openInputStream(it) }
            ?: throw java.io.IOException("Cannot open local source file")
    },
    internal val recoveryIdentity: suspend () -> String = {
        (context as io.github.anisharyal09.anice.AniCeApplication).identityService.getOrCreateIdentity().identity.fingerprint
    }
) : FeatureHandler {

    var state by mutableStateOf<TransferState>(TransferState.Idle); internal set
    var peerConnected by mutableStateOf(false); internal set
    var peerCompatible by mutableStateOf(false); internal set
    var onPickerChanged: (Boolean) -> Unit = {}
    var onChannelChanged: () -> Unit = {}
    internal var pickerTimeout: Job? = null
    var selectingFiles = false; internal set
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
    internal var pendingSend: (() -> Unit)? = null
    internal var awaitingLan = false
    internal var connectTimeoutJob: Job? = null

    internal val scope = CoroutineScope(SupervisorJob() + dispatcher)
    internal var activeChannel by mutableStateOf<SecuredChannel?>(null); internal set
    internal val channels = mutableMapOf<String, SecuredChannel>()
    internal val capabilities = mutableMapOf<String, TransferMessage>()
    internal var preparation: Job? = null
    var preparing by mutableStateOf(false); internal set
    internal var transferJob: Job? = null

    internal val ingress by lazy {
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
    internal var epoch = UUID.randomUUID()
        set(value) { field = value; ingress.invalidate() }
    internal var capacityRevision = 0L
    internal var sendingFile: TransferFile? = null
    internal var senderFileIndex = 0
    internal val retiredBatches = java.util.ArrayDeque<String>()
    internal var currentBatch: TransferBatch? = null
    internal var transferPeerDeviceId: String? = null
    internal var transferPeerFingerprint: String? = null

    // Logical checkpoints survive process death; channel generations and sealed work remain process-local.
    internal var pausedTransport: String? = null
    internal var pausedFileIndex = 0
    internal var pausedFileOffset = 0L
    internal var pausedCompletedBytes = 0L
    internal var pauseTimerJob: Job? = null
    internal var resumeJob: Job? = null
    internal var upgradeJob: Job? = null
    internal var statusDeferred: CompletableDeferred<TransferMessage>? = null
    internal var allowBleResume = false

    internal data class RetainedResult(
        val batchId: String,
        val fileId: String,
        val fileSize: Long,
        val result: TransferMessage,
        val peerId: String,
        val peerFingerprint: String,
    )
    /** The last verified result this receiver sent, replayable when a resume lands after the file. */
    internal var retainedFileResult: RetainedResult? = null
    internal var retainedBatch: TransferBatch? = null
    internal var offerReplayed = false
    internal var restoredSender = false
    /**
     * Guards [fileResultDeferred]/[receivedFileResult]. Chunk delivery may run on a session thread
     * while the sender coroutine waits, so reading the pending result then installing the waiter
     * must be one atomic step or the result can land in the gap and stall until the timeout.
     */
    internal val fileResultLock = Any()

    /** True from the moment a received file's last chunk lands until it is hashed and published. */
    var finalizing by mutableStateOf(false); internal set

    /**
     * Direction of the active or most recently finished batch: true while this device receives it.
     * It deliberately outlives [cleanupTransfer] so a completed panel can still report which way the
     * files moved; [dismiss] clears it.
     */
    var receiving by mutableStateOf(false); internal set

    internal var peerMaxChunkBytes: Long = 3072L
    internal var peerMaxWindow: Long = 64L
    internal var sendWindow: TransferSendWindow? = null
    internal val senderChunkBytes get() = sendWindow?.chunkBytes ?: peerMaxChunkBytes
    internal val sendCreditBytes: Long
        get() = sendWindow?.creditBytes ?: (peerMaxChunkBytes * peerMaxWindow)

    // Cumulative ACKs may end within a chunk; credit must fit the entire next chunk.
    internal val hasSendCredit: Boolean
        get() {
            val next = minOf(senderChunkBytes, ((sendingFile?.size ?: sentBytes) - sentBytes).coerceAtLeast(0))
            return sentBytes - acknowledgedBytes <= sendCreditBytes - next
        }

    // Sender flow control & backpressure
    @Volatile internal var sentBytes: Long = 0L
    @Volatile internal var acknowledgedBytes: Long = 0L
    /** When the last cumulative ACK arrived; a receiver-initiated BLE fallback yields to a live LAN. */
    @Volatile internal var lastAckAtMillis: Long? = null
    /** When the current sender stream started, used to give a fresh LAN resume time to produce ACKs. */
    @Volatile internal var streamStartedAtMillis: Long? = null
    @Volatile internal var creditDeferred: CompletableDeferred<Unit>? = null
    internal val capacityWaiters = java.util.concurrent.ConcurrentLinkedQueue<CompletableDeferred<Unit>>()
    @Volatile internal var fileResultDeferred: CompletableDeferred<TransferMessage>? = null
    @Volatile internal var receivedFileResult: TransferMessage? = null

    // Receiver state
    internal data class OfferAssembly(val batch: String, val totalSlices: Long, val totalFiles: Long,
                                     val totalBytes: Long, val slices: MutableMap<Long, List<TransferFile>> = mutableMapOf())
    internal var offerAssembly: OfferAssembly? = null
    internal var offerTimeout: Job? = null
    internal var destinationPreparation: Job? = null
    internal var documentDestination: TransferDestination? = null
    internal var receiverPartDocument: Uri? = null
    internal var destinationDirectory: File? = null
    internal var receiverCurrentFileIndex = 0
    internal var receiverPartFile: File? = null
    internal var receiverStorage: TransferReceiveStorage? = null
    internal var receiveCleanup: Job? = null
    internal var receiverWrittenBytes: Long = 0L
    internal var receiverTotalTransferred: Long = 0L
    internal var lastAckedWrittenBytes: Long = 0L
    internal var receiverAckChunkBytes = 3072L
    internal var ackJob: Job? = null
    internal var ackTimerJob: Job? = null
    internal var lastReceiverUiUpdate: Long = 0L

    internal var recoveryStore = recoveryFile?.let(::TransferRecoveryStore)
    internal var recoveryStarted = false
    internal data class RecoveryWrite(val snapshot: TransferCheckpoint?, val storage: TransferReceiveStorage?, val done: CompletableDeferred<Unit>? = null)
    internal val recoveryWrites = Channel<RecoveryWrite>(Channel.CONFLATED, onUndeliveredElement = {
        it.done?.completeExceptionally(SessionException(SessionFailure.CANCELLED))
    })
    internal var recoveryReady = CompletableDeferred<Unit>()
    internal var recoveryLocal: String? = null
    internal var recoveryPeer: ChannelDescriptor? = null
    internal var checkpointAt = 0L
    internal var checkpointPosition: String? = null
    internal var pauseExpiresAt: Long? = null
    internal var pauseDeadline: Long? = null
    internal var resumeAttemptChannel: ChannelDescriptor? = null
    internal var nextResumeAttemptAt = 0L
    internal var interruptedOffer: TransferState? = null
    internal val ownedSourceGrants = mutableSetOf<Uri>()
    internal var finalizationRetired: ChannelDescriptor? = null
    internal var finalizationResumed = false
    internal var receiptExpiry: Job? = null
    internal var receiptDeadline: Long? = null
    internal var failedRecovery: TransferCheckpoint? = null

    init {
        if (recoveryStore == null) recoveryReady.complete(Unit) else startRecoveryWorkers()
    }

    /** Application.onCreate runs after Android attaches the base Context. */
    fun restoreOnLaunch() { restoreOnLaunchFlow() }

    fun acceptIncomingOffer(tree: Uri, modes: Int) { acceptIncomingOfferFlow(tree, modes) }

    suspend fun acceptIncomingOffer(destinationDir: File) { acceptIncomingOfferFlow(destinationDir) }

    fun rejectIncomingOffer(reason: Long = 0L) { rejectIncomingOfferFlow(reason) }

    fun cancelTransfer(local: Boolean = true) { cancelTransferFlow(local) }

    fun dismiss() { dismissFlow() }

    internal fun invalidate() { invalidateFlow() }

    internal var progressJob: Job? = null
    internal var progressRate = TransferRate()
    internal var progressEpoch: UUID? = null
    internal var progressSampleAt = 0L
    internal var progressSpeed = 0.0

    internal fun chunkLimit(descriptor: ChannelDescriptor?) =
        if (descriptor?.transport == "lan" && descriptor.maximumDataBytes >= 524416) 524288 else if (descriptor?.transport == "lan" && descriptor.maximumDataBytes >= 262144) 262016 else 3072

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
            val versions = if (limit > 262016) listOf(2L, 3L, 4L) else if (limit > 131072) listOf(2L, 3L) else listOf(if (limit > 3072) 2L else 1L)
            for (version in versions) {
                if (channels[transport] !== channel) return@launch
                val chunk = if (version == 2L) minOf(131072, limit) else if (version == 3L) minOf(262016, limit) else limit
                try {
                    sendWithBackpressure(TransferMessage.capability(version, chunk.toLong(),
                        if (transport == "ble") 4 else if (chunk > 3072) 8 else 64).encode(limit), channel, jobBound = false)
                } catch (error: CancellationException) { throw error }
                  catch (_: Exception) { return@launch }
            }
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


    fun resumeOverBluetooth() { resumeOverBluetoothFlow() }


    // MARK: - Sender Flow

    fun sendFiles(files: List<File>) = prepareSources(files) { file ->
        prepareFile(file.name, file.length(), sourceFile = file) { FileInputStream(file) }
    }

    fun sendUris(uris: List<Uri>, reviewedPeerDeviceId: String? = null, reviewedPeerFingerprint: String? = null) { sendUrisFlow(uris, reviewedPeerDeviceId, reviewedPeerFingerprint) }
}
