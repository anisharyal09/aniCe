// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies private-listening CBOR, PCM layout and timeline bounds against independent adversarial fixtures.
package io.github.anisharyal09.anice.features.privatelistening

import io.github.anisharyal09.anice.infrastructure.session.Cbor
import io.github.anisharyal09.anice.infrastructure.session.SessionException
import io.github.anisharyal09.anice.infrastructure.session.SessionFailure
import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PrivateListeningWireTests {
    private val streamId = "01234567-89ab-4cde-8fab-0123456789ab"
    private fun hex(value: String) = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun fixtures() = JSONObject(javaClass.classLoader!!
        .getResource("private-listening/vectors.json")!!.readText())

    @Test fun independentFixturesAndCanonicalBytes() {
        val root = fixtures()
        val valid = root.getJSONArray("valid")
        val invalid = root.getJSONArray("invalid")
        val unrecognized = root.getJSONArray("unrecognized")
        assertTrue(valid.length() >= 45)
        assertTrue(invalid.length() >= 145)
        assertTrue(unrecognized.length() >= 3)
        val kinds = mutableSetOf<Long>()
        for (index in 0 until valid.length()) {
            val row = valid.getJSONObject(index)
            val name = row.getString("name")
            val encoded = hex(row.getString("bytesHex"))
            val message = PrivateListeningMessage.decode(encoded)!!
            assertEquals(name, message.kind == 3L, PrivateListeningMessage.hasAudioPrefix(encoded))
            assertEquals(name, row.getLong("kind"), message.kind)
            assertArrayEquals(name, encoded, message.encode())
            assertTrue(name, encoded.size <= 4000)
            kinds.add(message.kind)
        }
        assertEquals((0L..5L).toSet(), kinds)
        for (index in 0 until invalid.length()) {
            val row = invalid.getJSONObject(index)
            try {
                PrivateListeningMessage.decode(hex(row.getString("bytesHex")))
                fail(row.getString("name"))
            } catch (_: PrivateListeningWireException) {
            } catch (error: SessionException) {
                assertEquals(row.getString("name"), SessionFailure.MALFORMED, error.reason)
            }
        }
        for (index in 0 until unrecognized.length()) {
            val row = unrecognized.getJSONObject(index)
            assertNull(row.getString("name"), PrivateListeningMessage.decode(hex(row.getString("bytesHex"))))
        }
    }

    @Test fun independentPCMLayoutAndOwnedPacketBytes() {
        val valid = fixtures().getJSONArray("valid")
        val row = (0 until valid.length()).map(valid::getJSONObject)
            .first { it.getString("name") == "audio-pcm16-stereo" }
        val message = PrivateListeningMessage.decode(hex(row.getString("bytesHex")))!!
        assertEquals(streamId, message.text(0))
        assertEquals(1L, message.number(1))
        assertEquals(0L, message.number(2))
        assertEquals(3840, message.bytes(3).size)
        // Interleaved signed samples: [0,0], [32767,-32768], [-1,1], [12345,-12345].
        val samples = intArrayOf(0, 0, 0, 0, 255, 127, 0, 128, 255, 255, 1, 0, 57, 48, 199, 207)
        assertArrayEquals(samples.map { it.toByte() }.toByteArray(), message.bytes(3).copyOf(16))
        val pcm = ByteArray(3840) { 7 }
        val packet = PrivateListeningMessage.audio(streamId, 1, pcm)
        pcm.fill(0)
        assertEquals(7.toByte(), packet.bytes(3)[0])
    }

    @Test fun factoriesPreserveTheFinalPacketEndAndSmallRecordBudget() {
        val maximum = PrivateListeningMessage.MAX_SEQUENCE
        val message = PrivateListeningMessage.audio(streamId, maximum, ByteArray(3840))
        assertEquals(9607679205057058L, maximum)
        assertEquals((maximum - 1) * 960, message.number(2))
        assertEquals(maximum * 960, message.number(2) + 960)
        assertTrue(message.number(2) + 960 <= Long.MAX_VALUE)
        assertEquals(3927, message.encode().size)
        for (sequence in listOf(Long.MIN_VALUE, -1L, 0L, maximum + 1, Long.MAX_VALUE)) {
            rejects { PrivateListeningMessage.audio(streamId, sequence, ByteArray(3840)) }
        }
        for (size in listOf(0, 3839, 3841, 4000)) {
            rejects { PrivateListeningMessage.audio(streamId, 1, ByteArray(size)) }
        }
        rejects { PrivateListeningMessage.start(streamId.uppercase()).encode() }
        val start = PrivateListeningMessage.start(UUID.randomUUID().toString())
        assertEquals(start, PrivateListeningMessage.decode(start.encode()))
        val capability = PrivateListeningMessage.capability(false)
        assertEquals(capability, PrivateListeningMessage.decode(capability.encode()))
    }

    @Test fun encodingRejectsInvalidLocallyConstructedShapes() {
        val bad = listOf(
            PrivateListeningMessage(3, listOf(Cbor.Integer(1))),
            PrivateListeningMessage(3, listOf(Cbor.Text(streamId), Cbor.Integer(Long.MAX_VALUE),
                Cbor.Integer(0), Cbor.Bytes(ByteArray(3840)))),
            PrivateListeningMessage(3, listOf(Cbor.Text(streamId), Cbor.Integer(2),
                Cbor.Integer(961), Cbor.Bytes(ByteArray(3840)))),
            PrivateListeningMessage(0, listOf(Cbor.Integer(48000), Cbor.Integer(2),
                Cbor.Integer(16), Cbor.Integer(960), Cbor.Integer(1))),
            PrivateListeningMessage(5, listOf(Cbor.Text(streamId), Cbor.Integer(0), Cbor.Integer(2),
                Cbor.Integer(1), Cbor.Integer(960), Cbor.Integer(0), Cbor.Integer(1))),
            PrivateListeningMessage(5, listOf(Cbor.Text(streamId), Cbor.Integer(1), Cbor.Integer(5),
                Cbor.Integer(1), Cbor.Integer(960), Cbor.Integer(48001), Cbor.Integer(0))),
        )
        bad.forEach { message -> rejects { message.encode() } }
    }

    private fun rejects(action: () -> Unit) {
        try {
            action()
            fail("Accepted invalid local message")
        } catch (_: PrivateListeningWireException) {
        }
    }
}
