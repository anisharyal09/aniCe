// SPDX-License-Identifier: GPL-3.0-or-later
// Owns transfer checkpoints, interrupted-job recovery and transport resume.

package io.github.anisharyal09.anice.features.transfer

import android.net.Uri
import java.io.*
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import android.content.Context
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
import kotlinx.coroutines.channels.Channel

internal data class TransferCheckpoint(
    val localFingerprint: String,
    val peerId: String,
    val peerFingerprint: String,
    val batch: TransferBatch,
    val receiving: Boolean,
    val index: Int,
    val offset: Long,
    val folder: String,
    val tree: String,
    val partial: String,
    val document: String,
    val transport: String,
    val expiresAt: Long,
    val stage: Int = 0,
    val fileIdentity: String = "",
    val treeModes: Int = 0,
)

internal class TransferRecoveryStore(private val file: File, private val replace: (File, File) -> Unit = { source, target ->
    Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
}) {
    fun save(snapshot: TransferCheckpoint) {
        val bytes = encode(snapshot)
        val folder = file.parentFile ?: throw IOException("Missing recovery folder")
        if (!folder.isDirectory && !folder.mkdirs()) throw IOException("Cannot create recovery folder")
        val temporary = File.createTempFile("checkpoint-", ".tmp", folder)
        try {
            // Flush checkpoint contents before replacing the last committed recovery snapshot.
            FileOutputStream(temporary).use { it.write(bytes); it.fd.sync() }
            replace(temporary, file)
        } finally { if (temporary.exists() && !temporary.delete()) throw IOException("Cannot remove recovery temporary") }
    }

    fun load(): TransferCheckpoint? {
        if (!file.exists()) return null
        if (file.length() !in 1..MAX_BYTES) throw IOException("Invalid transfer checkpoint size")
        return decode(file.readBytes())
    }

    fun clear() {
        if (file.exists() && !file.delete()) throw IOException("Cannot remove transfer checkpoint")
    }

    companion object {
        private const val MAX_BYTES = 1024L * 1024
        private fun DataOutputStream.text(value: String) {
            val bytes = value.toByteArray(Charsets.UTF_8)
            require(bytes.size <= 8192)
            writeInt(bytes.size); write(bytes)
        }
        private fun DataInputStream.text(): String {
            val size = readInt()
            if (size !in 0..8192 || size > available()) throw IOException("Invalid checkpoint string")
            val bytes = ByteArray(size).also(::readFully)
            val value = bytes.toString(Charsets.UTF_8)
            if (!value.toByteArray(Charsets.UTF_8).contentEquals(bytes)) throw IOException("Invalid checkpoint UTF-8")
            return value
        }
        fun encode(value: TransferCheckpoint): ByteArray {
            validate(value)
            val bytes = ByteArrayOutputStream()
            DataOutputStream(bytes).use { out ->
                out.writeInt(1)
                for (s in listOf(value.localFingerprint, value.peerId, value.peerFingerprint,
                    value.batch.id, value.batch.peerName)) out.text(s)
                out.writeLong(value.batch.totalBytes); out.writeInt(value.batch.files.size)
                value.batch.files.forEach { file ->
                    out.text(file.id); out.text(file.name); out.writeLong(file.size); out.write(file.sha256)
                    out.text(file.sourceFile?.absolutePath ?: ""); out.text(file.sourceUri?.toString() ?: "")
                    out.writeBoolean(file.ownsReadGrant)
                }
                out.writeBoolean(value.receiving); out.writeInt(value.index); out.writeLong(value.offset)
                for (s in listOf(value.folder, value.tree, value.partial, value.document, value.transport)) out.text(s)
                out.writeLong(value.expiresAt)
                out.writeInt(value.stage)
                out.text(value.fileIdentity)
                out.writeInt(value.treeModes)
            }
            return bytes.toByteArray().also { require(it.size <= MAX_BYTES) }
        }
        fun decode(bytes: ByteArray): TransferCheckpoint {
            if (bytes.size.toLong() !in 1..MAX_BYTES) throw IOException("Invalid checkpoint size")
            return DataInputStream(ByteArrayInputStream(bytes)).use { input ->
                if (input.readInt() != 1) throw IOException("Unsupported checkpoint")
                val local = input.text(); val peer = input.text(); val fingerprint = input.text()
                val id = input.text(); val name = input.text(); val total = input.readLong()
                val count = input.readInt()
                if (count !in 1..128) throw IOException("Invalid checkpoint file count")
                val files = List(count) {
                    val fileId = input.text(); val fileName = input.text(); val size = input.readLong()
                    val hash = ByteArray(32).also(input::readFully)
                    val source = input.text(); val uri = input.text()
                    TransferFile(fileId, fileName, size, hash, source.takeIf { it.isNotEmpty() }?.let(::File),
                        uri.takeIf { it.isNotEmpty() }?.let(Uri::parse), input.readBoolean())
                }
                TransferCheckpoint(local, peer, fingerprint, TransferBatch(id, files, total, name),
                    input.readBoolean(), input.readInt(), input.readLong(), input.text(), input.text(),
                    input.text(), input.text(), input.text(), input.readLong(), input.readInt(), input.text(), input.readInt()).also {
                    if (input.available() != 0) throw IOException("Trailing checkpoint data")
                    validate(it)
                }
            }
        }
        private fun validate(value: TransferCheckpoint) {
            require(value.localFingerprint.matches(Regex("[0-9a-f]{64}")))
            require(value.peerFingerprint.matches(Regex("[0-9a-f]{64}")))
            require(UUID.fromString(value.peerId).toString() == value.peerId)
            require(UUID.fromString(value.batch.id).toString() == value.batch.id)
            require(value.batch.files.size in 1..128 && value.index in value.batch.files.indices)
            require(value.batch.files.map { it.id }.toSet().size == value.batch.files.size)
            var total = 0L
            value.batch.files.forEach {
                require(UUID.fromString(it.id).toString() == it.id && it.size >= 0 && it.sha256.size == 32)
                require(it.name.toByteArray(Charsets.UTF_8).size in 1..255 && it.name !in listOf(".", ".."))
                require(it.name.none { c -> c < ' ' || c == '/' || c == '\\' })
                total = Math.addExact(total, it.size)
            }
            require(total == value.batch.totalBytes && value.offset in 0..value.batch.files[value.index].size)
            require(value.transport in listOf("lan", "ble") && value.expiresAt > 0)
            require(value.stage in 0..4)
            require(value.stage != 1 || !value.receiving)
            require(value.stage != 2 || value.receiving)
            require(value.stage != 3 || value.receiving && value.index == value.batch.files.lastIndex && value.offset == value.batch.files.last().size)
            require(value.stage != 4 || value.receiving && value.offset == value.batch.files[value.index].size)
            require(value.treeModes in 0..3)
        }
    }
}

// MARK: - Controller checkpoint flow

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

// MARK: - Pause and transport resume

internal fun TransferController.expirePausedIfNeeded(): Boolean {
        if (state !is TransferState.Paused || pauseDeadline?.let { clock() >= it } != true) return false
        failTransfer("Transfer paused for too long without a connection. Send the files again.")
        return true
    }

internal fun TransferController.claimResumeAttempt(descriptor: ChannelDescriptor): Boolean {
        val now = clock()
        if (resumeAttemptChannel == descriptor && now < nextResumeAttemptAt) return false
        resumeAttemptChannel = descriptor; nextResumeAttemptAt = now + 2000
        return true
    }

internal fun TransferController.pauseOnConfirmationTimeout() {
        val current = state as? TransferState.Transferring ?: return
        val channel = activeChannel ?: return
        pauseTransfer(channel.descriptor, current)
        selectPreferredChannel()
    }

internal fun TransferController.pauseOffer(descriptor: ChannelDescriptor, previous: TransferState) {
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

internal fun TransferController.resumeInterruptedOffer(): Boolean {
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

internal fun TransferController.pauseTransfer(descriptor: ChannelDescriptor, previous: TransferState.Transferring) {
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

internal fun TransferController.startPauseTimer() {
        pauseTimerJob?.cancel()
        val operation = epoch
        pauseTimerJob = scope.launch {
            delay((pauseDeadline?.minus(clock()) ?: pauseTimeoutMillis).coerceAtLeast(0))
            if (operation == epoch && state is TransferState.Paused) {
                failTransfer("Transfer paused for too long without a connection. Send the files again.")
            }
        }
    }

internal fun TransferController.resumeOverBluetoothFlow() {
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

internal fun TransferController.refreshPausedCapability() {
        val paused = state as? TransferState.Paused ?: return
        val canBle = !allowBleResume && pausedTransport == "lan" &&
            channels["lan"] == null && channels["ble"] != null && capabilities["ble"] != null
        if (paused.canResumeOverBle != canBle) updateState(paused.copy(canResumeOverBle = canBle))
    }

internal fun TransferController.attemptResume() {
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

internal fun TransferController.requestPeerContinuation() {
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

internal suspend fun TransferController.requestStatus(channel: SecuredChannel, request: ByteArray): TransferMessage? {
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

internal fun TransferController.handleStatus(message: TransferMessage) {
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

internal suspend fun TransferController.handleResume(message: TransferMessage, descriptor: ChannelDescriptor) {
        val operation = epoch
        val channel = channels[descriptor.transport] ?: return
        if (channel.descriptor != descriptor) return
        expirePausedIfNeeded()
        if (currentBatch == null && receiptDeadline?.let { clock() >= it } == true) {
            retainedFileResult = null; retainedBatch = null; receiptDeadline = null
            if (recoveryStore != null) recoveryWrites.trySend(TransferController.RecoveryWrite(null, null))
        }
        val batchId = message.string(0)
        val fileId = message.string(1)
        val offset = message.number(2)
        val prefix = message.bytes(3)

        val proof = retainedFileResult
        val completedFile = retainedBatch?.takeIf { it.id == batchId }?.files?.find { it.id == fileId }
            ?: currentBatch?.takeIf { receiving && it.id == batchId }?.files?.take(receiverCurrentFileIndex)?.find { it.id == fileId }
        val retained = if (proof != null && completedFile != null) TransferController.RetainedResult(batchId, fileId, completedFile.size,
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

internal fun TransferController.bindResumeChannel(channel: SecuredChannel) {
        if (finalizing) finalizationResumed = true
        activeChannel = channel
        peerConnected = true
        peerCompatible = true
        peerMaxChunkBytes = 3072
        peerMaxWindow = 64
        capabilities[channel.descriptor.transport]?.let { applyCapability(it) }
        onChannelChanged()
    }

internal suspend fun TransferController.handlePeerResume(
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

internal fun TransferController.maybeUpgradeToLan(descriptor: ChannelDescriptor) {
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

internal fun TransferController.continueAfterRetainedReplay() {
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

internal suspend fun TransferController.resetReceiverFile(batch: TransferBatch, file: TransferFile): Boolean {
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

internal suspend fun TransferController.replyStatus(channel: SecuredChannel, batch: String, file: String, bytes: Long, status: Long) {
        runCatching {
            sendWithBackpressure(
                TransferMessage.status(batch, file, bytes, status).encode(),
                channel,
                jobBound = false
            )
        }
    }

internal suspend fun TransferController.filePrefixDigest(file: TransferFile, length: Long): ByteArray = withContext(Dispatchers.IO) {
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

internal fun TransferController.skipFully(stream: java.io.InputStream, length: Long) {
        var remaining = length
        val buffer = ByteArray(131072)
        while (remaining > 0) {
            val count = stream.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
            if (count < 0) throw java.io.IOException("Source ended before the retained offset")
            if (count == 0) throw java.io.IOException("Source stream made no progress")
            remaining -= count
        }
    }
