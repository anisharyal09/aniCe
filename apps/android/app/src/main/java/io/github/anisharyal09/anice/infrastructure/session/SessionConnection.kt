// SPDX-License-Identifier: GPL-3.0-or-later
// Owns authenticated envelope ordering and deadline-driven transport-independent session maintenance.
package io.github.anisharyal09.anice.infrastructure.session

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

// Only admission waiters are retained here; callers keep plaintext and SecureSession owns sealing.
internal class SessionDataAdmission {
  private class Waiter(val bulk: Boolean) {
    val ready = CompletableDeferred<Unit>()
    var granted = false
  }
  private val lock = Any()
  private val waiters = mutableListOf<Waiter>()
  private var active = false
  private var closed = false
  private var interactiveTurns = 0
  internal val pendingCount get() = synchronized(lock) { waiters.size }

  suspend fun run(bulk: Boolean, action: suspend () -> Unit) {
    currentCoroutineContext().ensureActive()
    val waiter = synchronized(lock) {
      if (closed) throw SessionException(SessionFailure.CANCELLED)
      if (!active) { active = true; null } else {
        if (waiters.size >= 8) throw SessionBackpressure()
        Waiter(bulk).also { waiters.add(it) }
      }
    }
    if (waiter != null) {
      try { waiter.ready.await() } catch (error: CancellationException) {
        val next = synchronized(lock) {
          if (!waiters.remove(waiter) && waiter.granted) releaseLocked() else null
        }
        next?.ready?.complete(Unit)
        throw error
      }
    }
    try {
      currentCoroutineContext().ensureActive()
      synchronized(lock) { if (closed) throw SessionException(SessionFailure.CANCELLED) }
      action()
    } finally {
      val next = synchronized(lock) { releaseLocked() }
      next?.ready?.complete(Unit)
    }
  }
  private fun releaseLocked(): Waiter? {
    if (waiters.isEmpty()) { active = false; interactiveTurns = 0; return null }
    // Four small-record turns bound bulk starvation; classification uses size until explicit feature priority exists.
    val bulk = waiters.indexOfFirst { it.bulk }
    val interactive = waiters.indexOfFirst { !it.bulk }
    val index = if (interactive < 0 || interactiveTurns >= 4 && bulk >= 0) bulk else interactive
    return waiters.removeAt(index).also {
      it.granted = true
      interactiveTurns = if (it.bulk) 0 else minOf(4, interactiveTurns + 1)
    }
  }
  fun close() {
    val pending = synchronized(lock) {
      closed = true
      waiters.toList().also { waiters.clear() }
    }
    pending.forEach { it.ready.completeExceptionally(SessionException(SessionFailure.CANCELLED)) }
  }
}

/** BLE-independent ordering owner; sealed record queues remain in the transport. */
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
  private val profile: SessionProfile = SessionProfile.STANDARD,
  private val drain: suspend () -> Unit = {},
) {
  private val liveness = if (controls) SessionLiveness(responder) else null
  val controlSupport get() = liveness?.support
  val renewalReason get() = if (responder) null else liveness?.renewalReason
  fun disableRenewal() { if (!closed) { renew = false; changed() } }
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
    if (closed || closedByPeer) return null
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

  // Application delivery runs outside the session lock: it hops dispatchers and decodes a whole
  // record, and none of that may delay control flush, deadline maintenance or the next record's
  // authentication. Delivery order is preserved because every caller awaits one `receive` before
  // starting the next; LanSessionController's transport consumer and SessionController's queue worker
  // are both single sequential loops.
  suspend fun receive(envelope: ByteArray) {
    var delivery: ByteArray? = null
    var peerDrain = false
    operation.withLock {
      try {
        requireOpen()
        val (kind, payload) = SessionEnvelope.decode(envelope, profile)
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
              val control = if (liveness != null) SessionControl.application(result.second, minOf(262144, maxOf(4096, profile.maximumPlaintext))) else null
              if (control != null) liveness!!.receive(control, now()) else delivery = result.second
            }
            RecordKind.CLOSE -> {
              closedByPeer = true
              peerDrain = true
            }
          }
          if (!closed && !closedByPeer) flushControl()
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
    // Accepted feature work may send a final reply. Let it reach the closing-state rejection
    // without waiting on the lock held by the drain that is awaiting that same work.
    if (peerDrain) {
      try { drain() } finally { close() }
    }
    // Application delivery releases the maintenance lock; transport callers still await it in record order.
    delivery?.let {
      val deliveryStart = SessionTiming.start()
      try { data(it) } finally { SessionTiming.end(this, "delivery", deliveryStart, it.size, profile = profile.wire, direction = "receive") }
    }
  }

  private suspend fun makeChannel() {
    requireOpen()
    deadline = now() + 10000
    val created =
      SecureSession.fromHandshake(
        handshake,
        responder,
        capacity,
        { submit(SessionEnvelope.encode(6, it, profile)) },
        now,
        profile,
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

  private val dataAdmission = SessionDataAdmission()

  val applicationAvailable get() = !closed && !closedByPeer && channel != null && deadline == 0L && liveness?.renewalReason == null
  suspend fun sendData(bytes: ByteArray) {
    val admissionStart = SessionTiming.start()
    dataAdmission.run(bytes.size > SessionProfile.STANDARD.maximumPlaintext) {
      SessionTiming.end(this, "admission", admissionStart, bytes.size, profile = profile.wire, direction = "send")
      sendAdmittedData(bytes)
    }
  }

  private suspend fun sendAdmittedData(bytes: ByteArray) {
    var refused = false
    try {
      // Receive and maintenance also flush controls; pending/issuing/submitted share their serializer.
      val ch = operation.withLock {
        requireOpen()
        if (liveness?.renewalReason != null) throw SessionBackpressure()
        flushControl()
        if (liveness?.pending != null) throw SessionBackpressure()
        channel ?: throw SessionException(SessionFailure.STATE)
      }
      ch.send(RecordKind.DATA, bytes)
      operation.withLock { requireOpen(); liveness?.activity(now()) }
    } catch (e: SessionBackpressure) {
      refused = true
      throw e
    } catch (e: CancellationException) {
      if (!closedByPeer && channel?.stage != ChannelStage.SECURED) close()
      throw e
    } catch (e: Exception) {
      if (!closedByPeer) close()
      throw e
    } finally { if (!refused) changed() }
  }

  @Volatile internal var maintenanceRuns = 0L
    private set

  internal fun checkDeadlines() {
    if (closedByPeer && !closed) return
    // Authentication may suspend in a signer; retirement and hard deadlines cannot wait for it.
    try {
      requireOpen()
      if (timedOut()) throw SessionException(SessionFailure.EXPIRED)
      channel?.checkDeadlines() ?: handshake.checkTime()
      liveness?.checkPongDeadline(now())
    } catch (e: SessionException) { retire(); throw e }
  }

  suspend fun tick() {
    if (closedByPeer && !closed) return
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
      dataAdmission.close()
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
    if (closed || closedByPeer) throw SessionException(SessionFailure.CANCELLED)
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
