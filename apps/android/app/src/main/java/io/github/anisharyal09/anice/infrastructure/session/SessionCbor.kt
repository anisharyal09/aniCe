// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.session

import java.io.ByteArrayOutputStream
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
}

class SessionException(val reason: SessionFailure) : Exception(reason.name)

sealed interface Cbor {
  data class Integer(val value: Long) : Cbor

  class Bytes(bytes: ByteArray) : Cbor {
    val value = bytes.copyOf()

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

  fun encode(value: Cbor): ByteArray = encodeValues(listOf(value))

  private fun encodeValues(values: List<Cbor>): ByteArray {
    val out = ByteArrayOutputStream()
    var items = 0
    fun head(major: Int, n: Long) {
      require(n >= 0)
      val width =
        when {
          n < 24 -> 0
          n <= 255 -> 1
          n <= 65535 -> 2
          n <= 0xffffffffL -> 4
          else -> 8
        }
      out.write(
        (major shl 5) or
          when (width) {
            0 -> n.toInt()
            1 -> 24
            2 -> 25
            4 -> 26
            else -> 27
          }
      )
      for (i in width - 1 downTo 0) out.write((n ushr (i * 8)).toInt() and 255)
    }
    fun write(value: Cbor, depth: Int) {
      if (depth > MAX_DEPTH || ++items > MAX_ITEMS) fail()
      when (value) {
        is Cbor.Integer ->
          head(
            if (value.value >= 0) 0 else 1,
            if (value.value >= 0) value.value else -(value.value + 1),
          )
        is Cbor.Bytes -> {
          if (value.value.size > MAX_BYTES) fail()
          head(2, value.value.size.toLong())
          out.write(value.value)
        }
        is Cbor.Text -> {
          val bytes =
            try {
              Charsets.UTF_8.newEncoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .encode(java.nio.CharBuffer.wrap(value.value))
                .let { b -> ByteArray(b.remaining()).also(b::get) }
            } catch (_: java.nio.charset.CharacterCodingException) {
              fail()
            }
          if (bytes.size > MAX_BYTES) fail()
          head(3, bytes.size.toLong())
          out.write(bytes)
        }
        is Cbor.Array -> {
          if (value.value.size > MAX_ITEMS) fail()
          head(4, value.value.size.toLong())
          value.value.forEach { write(it, depth + 1) }
        }
        is Cbor.Map -> {
          if (value.value.size > MAX_ITEMS / 2) fail()
          if (value.value.any { it.first is Cbor.Map || it.first is Cbor.Array }) fail()
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
        is Cbor.Bool -> out.write(if (value.value) 0xf5 else 0xf4)
      }
      if (out.size() > MAX_BYTES) fail()
    }
    values.forEach { write(it, 0) }
    return out.toByteArray()
  }

  fun decode(data: ByteArray): Cbor =
    decodeSequence(data).let {
      if (it.size != 1) fail()
      it.single()
    }

  fun decodeSequence(data: ByteArray): List<Cbor> {
    if (data.size > MAX_BYTES) fail()
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
          if (n > MAX_BYTES || n > data.size - offset) fail()
          val bytes = data.copyOfRange(offset, offset + n.toInt())
          offset += n.toInt()
          if (major == 2) Cbor.Bytes(bytes)
          else {
            val text =
              try {
                Charsets.UTF_8.newDecoder()
                  .onMalformedInput(CodingErrorAction.REPORT)
                  .onUnmappableCharacter(CodingErrorAction.REPORT)
                  .decode(ByteBuffer.wrap(bytes))
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
