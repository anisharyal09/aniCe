// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.identity

import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.fail
import org.junit.Test

class IdentityVectorTest {
    private fun vectors(): JSONObject = JSONObject(checkNotNull(javaClass.classLoader?.getResourceAsStream("identity-vectors.json"))
        .bufferedReader().use { it.readText() })
    @Test fun sharedPositiveVectors() {
        val valid = vectors().getJSONArray("valid")
        for (index in 0 until valid.length()) {
            val vector = valid.getJSONObject(index)
            val identity = DeviceIdentity.fromJson(vector.getJSONObject("identity"))
            val bytes = IdentityCrypto.decodeBase64(identity.publicKey)
            assertEquals(vector.getString("publicKeyHex"), bytes.joinToString("") { "%02x".format(it.toInt() and 255) })
            assertArrayEquals(bytes, IdentityCrypto.exportPublicKey(IdentityCrypto.publicKey(bytes)))
            assertEquals(identity.fingerprint, IdentityCrypto.fingerprint(bytes))
            assertTrue(vector.getString("name"), IdentityCrypto.verify(bytes,
                IdentityCrypto.decodeBase64(vector.getString("messageBase64")), IdentityCrypto.decodeBase64(vector.getString("signatureBase64"))))
        }
    }
    @Test fun rejectsInvalidIdentities() {
        val invalid = vectors().getJSONArray("invalidIdentities")
        for (index in 0 until invalid.length()) {
            val vector = invalid.getJSONObject(index)
            try { DeviceIdentity.fromJson(vector.getJSONObject("identity")); fail(vector.getString("name")) }
            catch (_: Exception) { }
        }
    }
    @Test fun rejectsInvalidSignatures() {
        val invalid = vectors().getJSONArray("invalidSignatures")
        for (index in 0 until invalid.length()) {
            val vector = invalid.getJSONObject(index)
            val identity = DeviceIdentity.fromJson(vector.getJSONObject("identity"))
            assertFalse(vector.getString("name"), IdentityCrypto.verify(IdentityCrypto.decodeBase64(identity.publicKey),
                IdentityCrypto.decodeBase64(vector.getString("messageBase64")), IdentityCrypto.decodeBase64(vector.getString("signatureBase64"))))
        }
    }
    @Test fun namesCountUnicodeCodePoints() {
        assertEquals("Android", DeviceIdentity.displayName("  "))
        assertEquals(64, DeviceIdentity.displayName("😀".repeat(70)).codePointCount(0, 128))
        assertEquals("Pixel", DeviceIdentity.displayName(" Pixel "))
    }
}
