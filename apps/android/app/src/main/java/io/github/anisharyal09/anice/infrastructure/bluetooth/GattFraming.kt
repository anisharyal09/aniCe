// SPDX-License-Identifier: GPL-3.0-or-later
// Bounded GATT reassembly and MTU fragmentation for pairing (v1) and session (v2) wire messages.
package io.github.anisharyal09.anice.infrastructure.bluetooth

import io.github.anisharyal09.anice.infrastructure.session.*
import java.nio.ByteBuffer

/** Wire versions share mechanics; their authentication engines and budgets remain independent. */
class GattReassembler(
  private val version: Int,
  private val now: () -> Long = { System.nanoTime() / 1_000_000 },
) {
  private var id = 0L
  private var total = 0
  private var buffer = byteArrayOf()
  private var started = 0L
  private val header
    get() = if (version == 1) 7 else 9

  fun tick() {
    if (buffer.isNotEmpty() && now() - started >= 10000)
      throw SessionException(SessionFailure.EXPIRED)
  }

  fun receive(fragment: ByteArray): ByteArray? {
    tick()
    if (fragment.size <= header || fragment[0].toInt() != version)
      throw SessionException(SessionFailure.MALFORMED)
    val b = ByteBuffer.wrap(fragment)
    b.get()
    val mid = if (version == 1) b.short.toLong() and 65535 else b.int.toLong() and 0xffffffffL
    val length = b.short.toInt() and 65535
    val offset = b.short.toInt() and 65535
    if (
      mid != id ||
        id > (if (version == 1) 65535L else 0xffffffffL) ||
        length !in 1..4096 ||
        offset != buffer.size ||
        (buffer.isNotEmpty() && total != length) ||
        fragment.size - header > length - offset
    )
      throw SessionException(SessionFailure.MALFORMED)
    // Progress does not extend the assembly deadline, preventing slow-fragment retention.
    if (buffer.isEmpty()) started = now()
    total = length
    buffer += fragment.copyOfRange(header, fragment.size)
    // A single buffer and exact next offset forbid interleaved or reordered messages.
    if (buffer.size != total) return null
    val result = buffer
    buffer = byteArrayOf()
    total = 0
    id++
    return result
  }

  companion object {
    fun fragments(data: ByteArray, id: Long, capacity: Int, version: Int): List<ByteArray> {
      val header = if (version == 1) 7 else 9
      if (
        version !in 1..2 ||
          data.size !in 1..4096 ||
          id !in 0..(if (version == 1) 65535L else 0xffffffffL) ||
          capacity <= header
      )
        throw SessionException(SessionFailure.MALFORMED)
      return (data.indices step (capacity - header)).map { offset ->
        val b = ByteBuffer.allocate(header).put(version.toByte())
        if (version == 1) b.putShort(id.toShort()) else b.putInt(id.toInt())
        b.putShort(data.size.toShort()).putShort(offset.toShort()).array() +
          data.copyOfRange(offset, minOf(data.size, offset + capacity - header))
      }
    }
  }
}

/** Counts retained logical envelopes, including messages currently being submitted. */
class GattQueueBudget {
  var messages = 0
    private set

  var bytes = 0
    private set

  fun canReserve(size: Int) = size in 1..4096 && messages < 8 && bytes + size <= 32768

  fun reserve(size: Int) {
    if (!canReserve(size)) throw SessionBackpressure()
    messages++
    bytes += size
  }

  fun release(size: Int) {
    check(messages > 0 && size in 1..bytes)
    messages--
    bytes -= size
  }

  fun clear() {
    messages = 0
    bytes = 0
  }
}
