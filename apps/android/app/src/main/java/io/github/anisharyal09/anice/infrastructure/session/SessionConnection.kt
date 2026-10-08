// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.session

import io.github.anisharyal09.anice.infrastructure.bluetooth.SessionEnvelope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** BLE-independent ordering owner; queues live in the transport, never in authentication. */
class SessionConnection(
  private val handshake: SessionHandshakeEngine,
  private val responder: Boolean,
  private val capacity: suspend (Int) -> Boolean,
  private val submit: suspend (ByteArray) -> Unit,
  private val data: suspend (ByteArray) -> Unit,
  private val secured: suspend () -> Unit,
) {
  private val ownership = Any()
  private val operation = Mutex()
  @Volatile private var closed = false
  private var channel: SecureSession? = null
  @Volatile
  var closedByPeer = false
    private set

  @Volatile
  var expiration: SessionExpiry? = null
    private set

  @Volatile private var deadline = System.nanoTime() / 1_000_000 + 30000

  fun timedOut() = deadline != 0L && System.nanoTime() / 1_000_000 >= deadline

  private var expected = if (responder) 1 else 2
  val isClosed
    get() = closed

  suspend fun start() =
    operation.withLock {
      try {
        requireOpen()
        if (!responder) submit(SessionEnvelope.encode(1, handshake.initiate()))
      } catch (e: Exception) {
        close()
        throw e
      }
    }

  suspend fun receive(envelope: ByteArray) =
    operation.withLock {
      try {
        requireOpen()
        val (kind, payload) = SessionEnvelope.decode(envelope)
        if (kind == 5) handshake.receiveError(payload)
        if (kind == 6) {
          val ch = channel ?: throw SessionException(SessionFailure.STATE)
          val result = ch.receive(payload)
          // Application access begins only after encrypted readiness confirms the exported keys.
          when (result.first) {
            // Responder readiness follows transport submission, which does not prove peer delivery.
            RecordKind.READY -> {
              ch.send(RecordKind.READY_ACK)
              deadline = 0
              secured()
            }
            RecordKind.READY_ACK -> {
              deadline = 0
              secured()
            }
            RecordKind.DATA -> data(result.second)
            RecordKind.CLOSE -> {
              closedByPeer = true
              close()
            }
          }
        } else {
          if (channel != null || kind != expected) throw SessionException(SessionFailure.STATE)
          when (kind) {
            1 -> {
              submit(SessionEnvelope.encode(2, handshake.respond(payload)))
              expected = 3
            }
            2 -> {
              submit(SessionEnvelope.encode(3, handshake.authenticateResponder(payload)))
              expected = 4
            }
            3 -> {
              submit(SessionEnvelope.encode(4, handshake.authenticateInitiator(payload)))
              makeChannel()
            }
            4 -> {
              handshake.confirmResponder(payload)
              makeChannel()
              channel!!.send(RecordKind.READY)
            }
            else -> throw SessionException(SessionFailure.STATE)
          }
        }
      } catch (e: Exception) {
        close()
        throw e
      }
    }

  private suspend fun makeChannel() {
    requireOpen()
    deadline = System.nanoTime() / 1_000_000 + 10000
    val created =
      SecureSession.fromHandshake(
        handshake,
        responder,
        capacity,
        { submit(SessionEnvelope.encode(6, it)) },
      )
    // Exporting can suspend; never publish keys created after synchronous retirement.
    synchronized(ownership) {
      if (closed) {
        created.close()
        throw SessionException(SessionFailure.CANCELLED)
      }
      channel = created
    }
  }

  private suspend fun <T> applicationOperation(block: suspend () -> T): T {
    if (!operation.tryLock()) throw SessionBackpressure()
    try {
      return block()
    } finally {
      operation.unlock()
    }
  }

  suspend fun sendData(bytes: ByteArray) = applicationOperation {
    requireOpen()
    val ch = channel ?: throw SessionException(SessionFailure.STATE)
    try {
      ch.send(RecordKind.DATA, bytes)
    } catch (e: SessionBackpressure) {
      throw e
    } catch (e: Exception) {
      close()
      throw e
    }
  }

  suspend fun tick() =
    operation.withLock {
      requireOpen()
      try {
        channel?.tick() ?: handshake.checkDeadline()
      } catch (e: Exception) {
        close()
        throw e
      }
    }

  suspend fun disconnect() {
    try {
      if (channel?.stage == ChannelStage.SECURED) channel?.send(RecordKind.CLOSE)
    } finally {
      close()
    }
  }

  // Retirement cannot wait for the operation mutex: a signer may still be suspended.
  fun retire() =
    synchronized(ownership) {
      closed = true
      expiration = expiration ?: channel?.expiration
      channel?.close()
      channel = null
      handshake.invalidate()
    }

  suspend fun close() {
    retire()
    handshake.close()
  }

  private fun requireOpen() {
    if (closed) throw SessionException(SessionFailure.CANCELLED)
  }
}
