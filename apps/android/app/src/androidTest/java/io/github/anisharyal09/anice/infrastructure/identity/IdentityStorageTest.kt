// SPDX-License-Identifier: GPL-3.0-or-later
// Verifies isolated native Keystore persistence, external mutation and protected signing.
package io.github.anisharyal09.anice.infrastructure.identity

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.KeyStore
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class IdentityStorageTest {
    @Test fun nativeProviderReuseDetectsExternalKeyReplacementAndDeletion() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val testId = DeviceIdentity.newId()
        val filename = "identity-test-$testId.json"
        val prefix = "anice.test.$testId."
        val keys = AndroidIdentityKeys()
        val external = AndroidIdentityKeys()
        val owner = IdentityService(AndroidIdentityMetadata(context, filename), keys, { "Native validation" }, prefix)
        try {
            val initial = owner.getOrCreateIdentity()
            repeat(4) { assertEquals(initial, owner.getOrCreateIdentity()) }
            val alias = keys.aliases().single { it.startsWith(prefix) }
            external.delete(alias)
            external.create(alias)
            try { owner.getOrCreateIdentity(); fail("External replacement accepted") }
            catch (error: IdentityException) { assertEquals(IdentityErrorKind.INCONSISTENT, error.kind) }
            assertTrue(external.aliases().contains(alias))
            external.delete(alias)
            try { owner.getOrCreateIdentity(); fail("External deletion accepted") }
            catch (error: IdentityException) { assertEquals(IdentityErrorKind.KEY_MISSING, error.kind) }
        } finally {
            external.aliases().filter { it.startsWith(prefix) }.forEach(external::delete)
            File(context.noBackupFilesDir, filename).delete()
        }
    }

    @Test fun keystorePersistenceSigningAndReset() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val testId = DeviceIdentity.newId()
        val filename = "identity-test-$testId.json"
        val prefix = "anice.test.$testId."
        val keys = AndroidIdentityKeys()
        fun service() = IdentityService(AndroidIdentityMetadata(context, filename), keys, { "Test Android" }, prefix)
        try {
            val initial = service().getOrCreateIdentity()
            assertEquals(initial, service().getOrCreateIdentity())
            assertEquals(65, IdentityCrypto.decodeBase64(initial.identity.publicKey).size)
            val alias = keys.aliases().single { it.startsWith(prefix) }
            val key = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.getKey(alias, null)
            assertNull(key.encoded)
            val payload = "Android Keystore test".toByteArray()
            val signed = service().sign(payload)
            assertEquals(initial.identity, signed.snapshot.identity)
            assertTrue(IdentityCrypto.verify(IdentityCrypto.decodeBase64(initial.identity.publicKey), payload, signed.signature))
            assertFalse(IdentityCrypto.verify(IdentityCrypto.decodeBase64(initial.identity.publicKey), payload + 0, signed.signature))
            val replacement = service().resetIdentity()
            assertNotEquals(initial.identity.deviceId, replacement.identity.deviceId)
            assertNotEquals(initial.identity.fingerprint, replacement.identity.fingerprint)
            assertFalse(keys.aliases().contains(alias))
            assertEquals(replacement, service().getOrCreateIdentity())
            assertTrue(File(context.noBackupFilesDir, filename).exists())
        } finally {
            keys.aliases().filter { it.startsWith(prefix) }.forEach(keys::delete)
            File(context.noBackupFilesDir, filename).delete()
        }
    }

    @Test fun lostKeyAndCorruptMetadataRequireExplicitReset() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val testId = DeviceIdentity.newId()
        val filename = "identity-test-$testId.json"
        val prefix = "anice.test.$testId."
        val keys = AndroidIdentityKeys()
        val metadata = AndroidIdentityMetadata(context, filename)
        val service = IdentityService(metadata, keys, { "Test Android" }, prefix)
        try {
            val original = service.getOrCreateIdentity()
            keys.aliases().filter { it.startsWith(prefix) }.forEach(keys::delete)
            try { service.getOrCreateIdentity(); fail("Missing key must fail") }
            catch (error: IdentityException) { assertEquals(IdentityErrorKind.KEY_MISSING, error.kind) }
            val repaired = service.resetIdentity()
            assertNotEquals(original.identity.deviceId, repaired.identity.deviceId)
            File(context.noBackupFilesDir, filename).writeText("{\"storageVersion\":1,\"active\":false,\"cleanup\":[]}")
            try { service.getOrCreateIdentity(); fail("Corrupt record must fail") }
            catch (error: IdentityException) { assertEquals(IdentityErrorKind.INCONSISTENT, error.kind) }
            service.resetIdentity()
            assertEquals(1, keys.aliases().count { it.startsWith(prefix) })
        } finally {
            keys.aliases().filter { it.startsWith(prefix) }.forEach(keys::delete)
            File(context.noBackupFilesDir, filename).delete()
        }
    }

    @Test fun sharedVectorsOnAndroidProvider() {
        val context = InstrumentationRegistry.getInstrumentation().context
        val vectors = JSONObject(context.assets.open("identity-vectors.json").bufferedReader().use { it.readText() })
        val valid = vectors.getJSONArray("valid")
        assertTrue("Identity positive fixture inventory was reduced", valid.length() >= 2)
        for (i in 0 until valid.length()) {
            val vector = valid.getJSONObject(i)
            val identity = DeviceIdentity.fromJson(vector.getJSONObject("identity"))
            assertTrue(vector.getString("name"), IdentityCrypto.verify(IdentityCrypto.decodeBase64(identity.publicKey),
                IdentityCrypto.decodeBase64(vector.getString("messageBase64")), IdentityCrypto.decodeBase64(vector.getString("signatureBase64"))))
        }
        val invalid = vectors.getJSONArray("invalidSignatures")
        assertTrue("Signature negative fixture inventory was reduced", invalid.length() >= 12)
        for (i in 0 until invalid.length()) {
            val vector = invalid.getJSONObject(i)
            val identity = DeviceIdentity.fromJson(vector.getJSONObject("identity"))
            assertFalse(vector.getString("name"), IdentityCrypto.verify(IdentityCrypto.decodeBase64(identity.publicKey),
                IdentityCrypto.decodeBase64(vector.getString("messageBase64")), IdentityCrypto.decodeBase64(vector.getString("signatureBase64"))))
        }
    }
}
