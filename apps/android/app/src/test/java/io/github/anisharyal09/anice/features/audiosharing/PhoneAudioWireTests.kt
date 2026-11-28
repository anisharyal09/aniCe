// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies the reverse envelope against independent canonical and adversarial fixtures.
package io.github.anisharyal09.anice.features.audiosharing

import io.github.anisharyal09.anice.infrastructure.session.SessionException
import io.github.anisharyal09.anice.infrastructure.session.SessionFailure
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PhoneAudioWireTests {
    private fun hex(value: String) = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun fixtures() = JSONObject(javaClass.classLoader!!
        .getResource("phone-audio/phone-audio-vectors.json")!!.readText())

    @Test fun independentFixturesStayCanonicalAndIsolateTheReverseTag() {
        val root = fixtures()
        val valid = root.getJSONArray("valid")
        val invalid = root.getJSONArray("invalid")
        val unrecognized = root.getJSONArray("unrecognized")
        assertTrue(valid.length() >= 35)
        assertTrue(invalid.length() >= 100)
        assertTrue(unrecognized.length() >= 4)
        val kinds = mutableSetOf<Long>()
        for (index in 0 until valid.length()) {
            val row = valid.getJSONObject(index)
            val name = row.getString("name")
            val encoded = hex(row.getString("bytesHex"))
            val message = requireNotNull(PhoneAudioMessage.decode(encoded)) { name }
            assertEquals(name, row.getLong("kind"), message.kind)
            assertArrayEquals(name, encoded, message.encode())
            assertTrue(name, encoded.size <= 4000)
            kinds.add(message.kind)
        }
        assertEquals((0L..4L).toSet(), kinds)
        for (index in 0 until invalid.length()) {
            val row = invalid.getJSONObject(index)
            val name = row.getString("name")
            try {
                PhoneAudioMessage.decode(hex(row.getString("bytesHex")))
                fail(name)
            } catch (_: AudioSharingWireException) {
            } catch (error: SessionException) {
                assertEquals(name, SessionFailure.MALFORMED, error.reason)
            }
        }
        for (index in 0 until unrecognized.length()) {
            val row = unrecognized.getJSONObject(index)
            assertNull(row.getString("name"), PhoneAudioMessage.decode(hex(row.getString("bytesHex"))))
        }
    }

    @Test fun reverseFixturesNeverBecomeListeningAudioAndListeningAudioNeverBecomesReverse() {
        val valid = fixtures().getJSONArray("valid")
        val audio = (0 until valid.length()).map(valid::getJSONObject)
            .first { it.getString("name") == "audio-pcm16-stereo" }
        val reverse = requireNotNull(PhoneAudioMessage.decode(hex(audio.getString("bytesHex"))))
        assertNull(AudioSharingMessage.decode(reverse.encode()))
        val listening = AudioSharingMessage.audio(
            "01234567-89ab-4cde-8fab-0123456789ab", 1, ByteArray(3840))
        assertNull(PhoneAudioMessage.decode(listening.encode()))
    }
}
