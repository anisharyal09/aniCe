// SPDX-License-Identifier: GPL-3.0-or-later
// Validates control messages and enforces compatibility, ping ordering and renewal thresholds.
package io.github.anisharyal09.anice.infrastructure.session

enum class ControlKind(val wire: Int, val field: String) {
  HELLO(1, "version"), HELLO_ACK(2, "version"), PING(3, "requestId"),
  PONG(4, "requestId"), RENEWAL_REQUEST(5, "reason"),
}

/** Exact DATA payload defined by protocol/session/control.cddl; never a new record kind. */
data class SessionControl(val kind: ControlKind, val value: Long = 1) {
  fun encode(): ByteArray {
    validate()
    return SessionCbor.encode(Cbor.Array(listOf(Cbor.Text(TAG), Cbor.Integer(1),
      Cbor.Integer(kind.wire.toLong()), Cbor.Map(listOf(Cbor.Text(kind.field) to Cbor.Integer(value))))))
  }

  private fun validate() {
    val valid = when (kind) {
      ControlKind.HELLO, ControlKind.HELLO_ACK -> value == 1L
      ControlKind.PING, ControlKind.PONG -> value in 0..0xffffffffL
      ControlKind.RENEWAL_REQUEST -> value in 1..2
    }
    if (!valid) throw SessionException(SessionFailure.MALFORMED)
  }

  companion object {
    private const val TAG = "aniCe control"
    fun decode(bytes: ByteArray): SessionControl {
      if (bytes.size > 128) throw SessionException(SessionFailure.MALFORMED)
      return fromCbor(SessionCbor.decode(bytes))
    }

    private fun fromCbor(cbor: Cbor): SessionControl {
      val row = (cbor as? Cbor.Array)?.value ?: throw SessionException(SessionFailure.MALFORMED)
      if (row.size != 4 || row[0] != Cbor.Text(TAG)) throw SessionException(SessionFailure.MALFORMED)
      val version = (row[1] as? Cbor.Integer)?.value ?: throw SessionException(SessionFailure.MALFORMED)
      if (version != 1L) throw SessionException(SessionFailure.UNSUPPORTED_PROFILE)
      val type = (row[2] as? Cbor.Integer)?.value ?: throw SessionException(SessionFailure.MALFORMED)
      val kind = ControlKind.entries.singleOrNull { it.wire.toLong() == type }
        ?: throw SessionException(SessionFailure.UNSUPPORTED_PROFILE)
      val payload = (row[3] as? Cbor.Map)?.value ?: throw SessionException(SessionFailure.MALFORMED)
      if (payload.size != 1 || payload[0].first != Cbor.Text(kind.field)) throw SessionException(SessionFailure.MALFORMED)
      val value = (payload[0].second as? Cbor.Integer)?.value ?: throw SessionException(SessionFailure.MALFORMED)
      return SessionControl(kind, value).also { it.validate() }
    }

    /** Arrays must be valid CBOR; other payloads and arrays with a different tag keep their dispatcher. */
    fun application(bytes: ByteArray): SessionControl? {
      if (bytes.isEmpty() || (bytes[0].toInt() and 0xe0) != 0x80) return null
      val parsed = SessionCbor.decode(bytes)
      val row = (parsed as? Cbor.Array)?.value ?: return null
      if (row.firstOrNull() != Cbor.Text(TAG)) return null
      if (bytes.size > 128) throw SessionException(SessionFailure.MALFORMED)
      return fromCbor(parsed)
    }
  }
}

/** Connection-serialized policy, in monotonic milliseconds; it never owns keys or transport. */
internal class SessionLiveness(private val responder: Boolean, private var nextId: Long = 0) {
  @Volatile var support: Boolean? = null
    private set
  var pending: SessionControl? = null
    private set
  private var started = false
  private var compatibilityDeadline = 0L
  private var lastActivity = 0L
  private var helloIssued = false
  private var outstanding: Long? = null
  private var pongDeadline: Long? = null
  private var expectedPing = 0L
  @Volatile var renewalReason: Long? = null
    private set
  private var renewalSubmitted = false

  fun requestRenewal(reason: Long) {
    if (reason !in 1..2) stateFailure()
    if (support == true && renewalReason == null) renewalReason = reason
  }

  fun start(now: Long) {
    if (started) stateFailure()
    started = true
    lastActivity = now
    compatibilityDeadline = now + 10000
    if (!responder) pending = SessionControl(ControlKind.HELLO)
  }
  fun activity(now: Long) { lastActivity = now }

  fun receive(message: SessionControl, now: Long) {
    if (!started || support == false) stateFailure()
    activity(now)
    when (message.kind) {
      ControlKind.HELLO -> {
        if (!responder || support != null || pending != null || now >= compatibilityDeadline) stateFailure()
        pending = SessionControl(ControlKind.HELLO_ACK)
      }
      ControlKind.HELLO_ACK -> {
        if (responder || support != null || !helloIssued || now >= compatibilityDeadline) stateFailure()
        support = true
      }
      ControlKind.PING -> {
        if (!responder || support != true || pending != null || message.value != expectedPing) stateFailure()
        expectedPing++ // Stored as Long so uint32 exhaustion never wraps back to zero.
        pending = SessionControl(ControlKind.PONG, message.value)
      }
      ControlKind.PONG -> {
        if (responder || support != true || outstanding != message.value || pongDeadline == null) stateFailure()
        if (now >= pongDeadline!!) timeout()
        outstanding = null
        pongDeadline = null
      }
      ControlKind.RENEWAL_REQUEST -> {
        if (responder || support != true) stateFailure()
        requestRenewal(message.value) // Local and remote threshold races coalesce into one retirement.
      }
    }
  }

  fun poll(now: Long) {
    if (!started) return
    if (support == null && now >= compatibilityDeadline) {
      support = false
      pending = null // Legacy manual operation remains usable; no further negotiation traffic.
    }
    if (pending?.kind == ControlKind.HELLO_ACK && now >= compatibilityDeadline) timeout()
    pongDeadline?.let { if (now >= it) timeout() }
    if (responder && support == true && pending == null && renewalReason != null && !renewalSubmitted) {
      pending = SessionControl(ControlKind.RENEWAL_REQUEST, renewalReason!!)
    }
    if (!responder && support == true && renewalReason == null && pending == null && outstanding == null && now - lastActivity >= 60000) {
      if (nextId !in 0..0xffffffffL) timeout()
      pending = SessionControl(ControlKind.PING, nextId++)
    }
  }

  /** Called after queue preflight, before awaiting submission: a fast peer may respond immediately. */
  fun issuing(message: SessionControl, now: Long) {
    if (pending != message) stateFailure()
    when (message.kind) {
      ControlKind.HELLO -> helloIssued = true
      ControlKind.HELLO_ACK -> support = true
      ControlKind.PING -> if (outstanding == null) { outstanding = message.value; pongDeadline = now + 20000 }
      else -> Unit
    }
  }
  fun submitted(message: SessionControl, now: Long) {
    if (pending == message) pending = null
    if (message.kind == ControlKind.RENEWAL_REQUEST) renewalSubmitted = true
    activity(now)
  }
  private fun stateFailure(): Nothing = throw SessionException(SessionFailure.STATE)
  private fun timeout(): Nothing = throw SessionException(SessionFailure.CONTROL_TIMEOUT)
}
