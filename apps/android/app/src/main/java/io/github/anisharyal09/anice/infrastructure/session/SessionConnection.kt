// SPDX-License-Identifier: GPL-3.0-or-later
// Owns authenticated envelope ordering and deadline-driven transport-independent session maintenance.
package io.github.anisharyal09.anice.infrastructure.session

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
  controls: Boolean = false,
  private val now: () -> Long = { System.nanoTime() / 1_000_000 },
  @Volatile private var renew: Boolean = false,
  private val changed: () -> Unit = {},
) {
  private val liveness = if (controls) SessionLiveness(responder) else null
  val controlSupport get() = liveness?.support
  val renewalReason get() = if (responder) null else liveness?.renewalReason
  fun enableRenewal() { if (!closed) { renew = true; changed() } }
  private val ownership = Any()
  private val operation = Mutex()
  @Volatile private var closed = false
  @Volatile private var channel: SecureSession? = null
  @Volatile
  var closedByPeer = false
    private set

  @Volatile
  var expiration: SessionExpiry? = null
    private set

  @Volatile private var deadline = now() + 30000

  fun timedOut() = deadline != 0L && now() >= deadline

  private var expected = if (responder) 1 else 2
  val isClosed
    get() = closed

  suspend fun nextDeadline(includeMaintenance: Boolean = true): Long? {
    if (closed) return null
    val available = operation.tryLock()
    val policy = available && includeMaintenance
    try {
      return listOfNotNull(
        deadline.takeIf { it != 0L },
        handshake.nextDeadline(),
        channel?.nextDeadline(policy && renew && liveness?.support == true && liveness.renewalReason == null),
        if (policy) liveness?.nextDeadline() else liveness?.pendingPongDeadline,
      ).minOrNull()
    } finally { if (available) operation.unlock() }
  }

  suspend fun start() =
    operation.withLock {
      try {
        requireOpen()
        if (!responder) submit(SessionEnvelope.encode(1, handshake.initiate()))
      } catch (e: Exception) {
        close()
        throw e
      } finally { changed() }
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
          requireOpen()
          liveness?.activity(now())
          // Application access begins only after encrypted readiness confirms the exported keys.
          when (result.first) {
            // Responder readiness follows transport submission, which does not prove peer delivery.
            RecordKind.READY -> {
              ch.send(RecordKind.READY_ACK)
              deadline = 0
              secured()
              requireOpen()
              liveness?.start(now())
            }
            RecordKind.READY_ACK -> {
              deadline = 0
              secured()
              requireOpen()
              liveness?.start(now())
            }
            RecordKind.DATA -> {
              val control = if (liveness != null) SessionControl.application(result.second) else null
              if (control != null) liveness!!.receive(control, now()) else data(result.second)
            }
            RecordKind.CLOSE -> {
              closedByPeer = true
              close()
            }
          }
          if (!closed) flushControl()
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
      } finally { changed() }
    }

  private suspend fun makeChannel() {
    requireOpen()
    deadline = now() + 10000
    val created =
      SecureSession.fromHandshake(
        handshake,
        responder,
        capacity,
        { submit(SessionEnvelope.encode(6, it)) },
        now,
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
      changed()
    }
  }

  suspend fun sendData(bytes: ByteArray) = applicationOperation {
    requireOpen()
    if (liveness?.renewalReason != null) throw SessionBackpressure()
    val ch = channel ?: throw SessionException(SessionFailure.STATE)
    try {
      ch.send(RecordKind.DATA, bytes)
      liveness?.activity(now())
    } catch (e: SessionBackpressure) {
      throw e
    } catch (e: Exception) {
      close()
      throw e
    }
  }

  @Volatile internal var maintenanceRuns = 0L
    private set

  internal fun checkDeadlines() {
    // Authentication may suspend in a signer; retirement and hard deadlines cannot wait for it.
    try {
      requireOpen()
      if (timedOut()) throw SessionException(SessionFailure.EXPIRED)
      channel?.checkDeadlines() ?: handshake.checkTime()
      liveness?.checkPongDeadline(now())
    } catch (e: SessionException) { retire(); throw e }
  }

  suspend fun tick() {
    checkDeadlines()
    if (!operation.tryLock()) return
    try {
      maintenanceRuns++
      try {
        if (timedOut()) throw SessionException(SessionFailure.EXPIRED)
        channel?.checkDeadlines() ?: handshake.checkTime()
        if (renew) channel?.renewalReason()?.let { liveness?.requestRenewal(it) }
        liveness?.poll(now())
        flushControl()
      } catch (e: Exception) {
        close()
        throw e
      }
    } finally { operation.unlock() }
  }

  private suspend fun flushControl() {
    val message = liveness?.pending ?: return
    val ch = channel ?: return
    val bytes = message.encode()
    // Queue refusal is recoverable only before sealing; retain one logical control for a capacity event.
    if (!capacity(bytes.size + 31)) return
    requireOpen()
    liveness.issuing(message, now())
    try {
      ch.send(RecordKind.DATA, bytes)
      requireOpen()
      liveness.submitted(message, now())
    } catch (_: SessionBackpressure) { /* No sequence consumed; the pending control remains bounded. */ }
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
      changed()
    }

  suspend fun close() {
    retire()
    handshake.close()
  }

  private fun requireOpen() {
    if (closed) throw SessionException(SessionFailure.CANCELLED)
  }
}

/** One conflated event lane prevents lost wakes while a deadline snapshot is being computed. */
internal suspend fun awaitSessionDeadline(
  events: kotlinx.coroutines.channels.Channel<Unit>, deadline: Long?, now: () -> Long,
): Boolean {
  if (deadline == null) { events.receive(); return true }
  return kotlinx.coroutines.withTimeoutOrNull((deadline - now()).coerceAtLeast(1)) { events.receive(); true } ?: false
}

/** Crypto completion recalculates deadlines without recursively requesting another crypto operation. */
internal class SessionMaintenance {
  private val events = kotlinx.coroutines.channels.Channel<Unit>(kotlinx.coroutines.channels.Channel.CONFLATED)
  private val requested = java.util.concurrent.atomic.AtomicBoolean()
  fun request() { deferWork(); resnapshot() }
  fun deferWork() { requested.set(true) }
  fun resnapshot() { events.trySend(Unit) }
  suspend fun await(deadline: Long?, now: () -> Long): Boolean {
    val event = awaitSessionDeadline(events, deadline, now)
    val work = requested.getAndSet(false)
    return !event || work
  }
}
