// SPDX-License-Identifier: GPL-3.0-or-later
// Encodes deterministic CBOR with explicit byte budgets and fixed depth/item bounds.
package io.github.anisharyal09.anice.infrastructure.session

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

enum class SessionFailure {
  MALFORMED,
  UNSUPPORTED_PROFILE,
  UNTRUSTED_PEER,
  AUTHENTICATION,
  STATE,
  CANCELLED,
  EXPIRED,
  CONTROL_TIMEOUT,
}

class SessionException(val reason: SessionFailure) : Exception(reason.name)

sealed interface Cbor {
  data class Integer(val value: Long) : Cbor

  class Bytes : Cbor {
    val value: ByteArray

    /** Copies its input, so a constructed node can never alias a caller's mutable buffer. */
    constructor(bytes: ByteArray) {
      value = bytes.copyOf()
    }

    /** Copies one slice of [source] exactly once, so a reused buffer needs no intermediate copy. */
    internal constructor(source: ByteArray, from: Int, to: Int) {
      value = source.copyOfRange(from, to)
    }

    override fun equals(other: Any?) = other is Bytes && value.contentEquals(other.value)

    override fun hashCode() = value.contentHashCode()
  }

  data class Text(val value: String) : Cbor

  data class Array(val value: List<Cbor>) : Cbor

  data class Map(val value: List<Pair<Cbor, Cbor>>) : Cbor

  data class Bool(val value: Boolean) : Cbor
}

/** Deterministic RFC 8949 length-first map ordering, bounded to the session profile. */
object SessionCbor {
  const val MAX_BYTES = 4096
  private const val MAX_ITEMS = 512
  private const val MAX_DEPTH = 8

  fun sequence(vararg values: Cbor): ByteArray = encodeValues(values.toList())

  fun encode(value: Cbor, maximumBytes: Int = MAX_BYTES): ByteArray = encodeValues(listOf(value), maximumBytes)

  private fun encodeValues(values: List<Cbor>, maximumBytes: Int = MAX_BYTES): ByteArray {
    require(maximumBytes in 1..262144)
    return Encoder(maximumBytes).encode(values)
  }

  /**
   * Measures and then writes deterministic CBOR into one exact-size buffer. Both passes share this
   * single traversal, so a measured size and its bytes cannot disagree, and a payload-sized value
   * costs one allocation instead of stream growth plus a trailing copy.
   */
  private class Encoder(private val maximumBytes: Int) {
    private var out = ByteArray(0)
    private var position = 0
    private var items = 0

    fun encode(values: List<Cbor>): ByteArray {
      items = 0
      position = 0
      values.forEach { write(it, 0) }
      val size = position
      out = ByteArray(size)
      items = 0
      position = 0
      values.forEach { write(it, 0) }
      check(position == size)
      return out
    }

    private fun emit(byte: Int) {
      if (out.isNotEmpty()) out[position] = byte.toByte()
      position++
    }

    private fun emit(bytes: ByteArray, offset: Int, length: Int) {
      if (out.isNotEmpty()) System.arraycopy(bytes, offset, out, position, length)
      position += length
    }

    private fun head(major: Int, n: Long) {
      require(n >= 0)
      val width =
        when {
          n < 24 -> 0
          n <= 255 -> 1
          n <= 65535 -> 2
          n <= 0xffffffffL -> 4
          else -> 8
        }
      emit(
        (major shl 5) or
          when (width) {
            0 -> n.toInt()
            1 -> 24
            2 -> 25
            4 -> 26
            else -> 27
          }
      )
      for (i in width - 1 downTo 0) emit((n ushr (i * 8)).toInt() and 255)
    }

    private fun utf8(text: String): ByteArray =
      try {
        Charsets.UTF_8.newEncoder()
          .onMalformedInput(CodingErrorAction.REPORT)
          .encode(java.nio.CharBuffer.wrap(text))
          .let { b -> ByteArray(b.remaining()).also(b::get) }
      } catch (_: java.nio.charset.CharacterCodingException) {
        fail()
      }

    private fun write(value: Cbor, depth: Int) {
      if (depth > MAX_DEPTH || ++items > MAX_ITEMS) fail()
      when (value) {
        is Cbor.Integer ->
          head(
            if (value.value >= 0) 0 else 1,
            if (value.value >= 0) value.value else -(value.value + 1),
          )
        is Cbor.Bytes -> {
          if (value.value.size > maximumBytes) fail()
          head(2, value.value.size.toLong())
          emit(value.value, 0, value.value.size)
        }
        is Cbor.Text -> {
          val bytes = utf8(value.value)
          if (bytes.size > maximumBytes) fail()
          head(3, bytes.size.toLong())
          emit(bytes, 0, bytes.size)
        }
        is Cbor.Array -> {
          if (value.value.size > MAX_ITEMS) fail()
          head(4, value.value.size.toLong())
          value.value.forEach { write(it, depth + 1) }
        }
        is Cbor.Map -> {
          if (value.value.size > MAX_ITEMS / 2) fail()
          if (value.value.any { it.first is Cbor.Map || it.first is Cbor.Array }) fail()
          // Sort encoded keys deterministically; duplicate encodings cannot bind different values.
          val sorted =
            value.value
              .map { Triple(encode(it.first), it.first, it.second) }
              .sortedWith { a, b -> compare(a.first, b.first) }
          sorted.zipWithNext().forEach { (a, b) -> if (compare(a.first, b.first) == 0) fail() }
          head(5, sorted.size.toLong())
          sorted.forEach {
            write(it.second, depth + 1)
            write(it.third, depth + 1)
          }
        }
        is Cbor.Bool -> emit(if (value.value) 0xf5 else 0xf4)
      }
      if (position > maximumBytes) fail()
    }
  }

  fun decode(data: ByteArray, maximumBytes: Int = MAX_BYTES): Cbor =
    decodeSequence(data, maximumBytes).let {
      if (it.size != 1) fail()
      it.single()
    }

  fun decodeSequence(data: ByteArray, maximumBytes: Int = MAX_BYTES): List<Cbor> {
    require(maximumBytes in 1..262144)
    if (data.size > maximumBytes) fail()
    var offset = 0
    var items = 0
    fun byte(): Int {
      if (offset >= data.size) fail()
      return data[offset++].toInt() and 255
    }
    fun length(additional: Int): Long {
      if (additional < 24) return additional.toLong()
      val width =
        when (additional) {
          24 -> 1
          25 -> 2
          26 -> 4
          27 -> 8
          else -> fail()
        }
      var n = 0L
      repeat(width) {
        if (n > Long.MAX_VALUE ushr 8) fail()
        n = (n shl 8) or byte().toLong()
      }
      val floor =
        when (width) {
          1 -> 24L
          2 -> 256L
          4 -> 65536L
          else -> 0x100000000L
        }
      if (n < floor) fail()
      return n
    }
    fun read(depth: Int): Cbor {
      if (depth > MAX_DEPTH || ++items > MAX_ITEMS) fail()
      val first = byte()
      val major = first ushr 5
      val extra = first and 31
      if (major == 7)
        return when (extra) {
          20 -> Cbor.Bool(false)
          21 -> Cbor.Bool(true)
          else -> fail()
        }
      val n = length(extra)
      return when (major) {
        0 -> Cbor.Integer(n)
        1 -> Cbor.Integer(-1 - n)
        2,
        3 -> {
          if (n > maximumBytes || n > data.size - offset) fail()
          val start = offset
          offset += n.toInt()
          if (major == 2) Cbor.Bytes(data, start, offset)
          else {
            val text =
              try {
                Charsets.UTF_8.newDecoder()
                  .onMalformedInput(CodingErrorAction.REPORT)
                  .onUnmappableCharacter(CodingErrorAction.REPORT)
                  .decode(ByteBuffer.wrap(data, start, n.toInt()))
                  .toString()
              } catch (_: java.nio.charset.CharacterCodingException) {
                fail()
              }
            Cbor.Text(text)
          }
        }
        4 -> {
          if (n > MAX_ITEMS) fail()
          Cbor.Array(List(n.toInt()) { read(depth + 1) })
        }
        5 -> {
          if (n > MAX_ITEMS / 2) fail()
          var previous: ByteArray? = null
          Cbor.Map(
            List(n.toInt()) {
              val start = offset
              val key = read(depth + 1)
              val encoded = data.copyOfRange(start, offset)
              if (key is Cbor.Map || key is Cbor.Array) fail()
              previous?.let { if (compare(it, encoded) >= 0) fail() }
              previous = encoded
              key to read(depth + 1)
            }
          )
        }
        else -> fail()
      }
    }
    return buildList { while (offset < data.size) add(read(0)) }
  }

  private fun compare(a: ByteArray, b: ByteArray): Int {
    if (a.size != b.size) return a.size.compareTo(b.size)
    for (i in a.indices) {
      val c = (a[i].toInt() and 255).compareTo(b[i].toInt() and 255)
      if (c != 0) return c
    }
    return 0
  }

  private fun fail(): Nothing = throw SessionException(SessionFailure.MALFORMED)
}

internal fun Cbor.bytes(size: Int? = null): ByteArray {
  val result = (this as? Cbor.Bytes)?.value ?: throw SessionException(SessionFailure.MALFORMED)
  if (size != null && result.size != size) throw SessionException(SessionFailure.MALFORMED)
  return result.copyOf()
}
