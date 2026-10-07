// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.identity

import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class IdentityServiceTest {
    private class MemoryMetadata : IdentityMetadataStore {
        var value: IdentityJournal? = null
        var readError: IdentityErrorKind? = null
        var failWrite = false
        var failCommit = false
        override fun read(): IdentityJournal? {
            readError?.let { throw IdentityException(it) }; return value
        }
        override fun write(journal: IdentityJournal) {
            if (failWrite || (failCommit && journal.active != null && journal.pending == null)) throw IdentityException(IdentityErrorKind.STORAGE_UNAVAILABLE)
            value = journal
        }
    }
    private class MemoryKeys : IdentityKeyStore {
        val values = mutableMapOf<String, KeyPair>()
        var unavailable = false
        var failDelete = false
        private fun check() { if (unavailable) throw IdentityException(IdentityErrorKind.STORAGE_UNAVAILABLE) }
        override fun aliases(): Set<String> { check(); return values.keys.toSet() }
        override fun create(alias: String) {
            check(); check(!values.containsKey(alias))
            values[alias] = KeyPairGenerator.getInstance("EC").run {
                initialize(ECGenParameterSpec("secp256r1")); generateKeyPair()
            }
        }
        override fun publicKey(alias: String): ByteArray? { check(); return values[alias]?.let { IdentityCrypto.exportPublicKey(it.public) } }
        override fun protection(alias: String): KeyProtection = KeyProtection.PLATFORM
        override fun sign(alias: String, message: ByteArray): ByteArray {
            check()
            val pair = values[alias] ?: throw IdentityException(IdentityErrorKind.KEY_MISSING)
            return Signature.getInstance("SHA256withECDSA").run { initSign(pair.private); update(message); sign() }
        }
        override fun delete(alias: String) { check(); if (failDelete) throw IdentityException(IdentityErrorKind.STORAGE_UNAVAILABLE); values.remove(alias) }
    }
    private val metadata = MemoryMetadata()
    private val keys = MemoryKeys()
    private fun service() = IdentityService(metadata, keys, { "Pixel" })
    private fun expectError(kind: IdentityErrorKind, action: () -> Any?) {
        try { action(); fail("Expected $kind") } catch (error: IdentityException) { assertEquals(kind, error.kind) }
    }
    @Test fun identitySurvivesServiceRecreationAndSigns() {
        val original = service().getOrCreateIdentity()
        val restored = service().getOrCreateIdentity()
        assertEquals(original, restored)
        val data = byteArrayOf(1, 2, 3)
        val signature = service().sign(data)
        assertEquals(original, signature.snapshot)
        assertTrue(IdentityCrypto.verify(IdentityCrypto.decodeBase64(original.identity.publicKey), data, signature.signature))
    }
    @Test fun concurrentInitializationCreatesOneIdentity() {
        val service = service()
        val pool = Executors.newFixedThreadPool(6)
        try {
            val identities = pool.invokeAll((0..15).map { Callable { service.getOrCreateIdentity().identity.deviceId } }).map { it.get() }
            assertEquals(1, identities.toSet().size)
            assertEquals(1, keys.values.size)
        } finally { pool.shutdownNow() }
    }
    @Test fun unavailableStorageDoesNotCreateOrReplaceIdentity() {
        val original = service().getOrCreateIdentity()
        metadata.readError = IdentityErrorKind.STORAGE_UNAVAILABLE
        expectError(IdentityErrorKind.STORAGE_UNAVAILABLE) { service().getOrCreateIdentity() }
        expectError(IdentityErrorKind.STORAGE_UNAVAILABLE) { service().resetIdentity() }
        metadata.readError = null
        keys.unavailable = true
        expectError(IdentityErrorKind.STORAGE_UNAVAILABLE) { service().getOrCreateIdentity() }
        keys.unavailable = false
        assertEquals(original, service().getOrCreateIdentity())
    }
    @Test fun missingKeyRequiresExplicitReset() {
        val original = service().getOrCreateIdentity()
        keys.values.clear()
        expectError(IdentityErrorKind.KEY_MISSING) { service().getOrCreateIdentity() }
        assertTrue(keys.values.isEmpty())
        assertNotEquals(original.identity.deviceId, service().resetIdentity().identity.deviceId)
    }
    @Test fun mismatchedKeyRequiresExplicitReset() {
        service().getOrCreateIdentity()
        val alias = metadata.value!!.active!!.alias
        keys.values.clear(); keys.create(alias)
        expectError(IdentityErrorKind.INCONSISTENT) { service().getOrCreateIdentity() }
        service().resetIdentity()
        assertEquals(1, keys.values.size)
    }
    @Test fun resetChangesIdentityOnlyAfterCommit() {
        val original = service().getOrCreateIdentity()
        metadata.failCommit = true
        expectError(IdentityErrorKind.STORAGE_UNAVAILABLE) { service().resetIdentity() }
        metadata.failCommit = false
        assertEquals(original, service().getOrCreateIdentity())
        assertEquals(1, keys.values.size)
        val replacement = service().resetIdentity()
        assertNotEquals(original.identity.deviceId, replacement.identity.deviceId)
        assertNotEquals(original.identity.fingerprint, replacement.identity.fingerprint)
        assertEquals(1, keys.values.size)
    }
    @Test fun interruptedFirstCreationRecoversSamePendingIdentity() {
        metadata.failCommit = true
        expectError(IdentityErrorKind.STORAGE_UNAVAILABLE) { service().getOrCreateIdentity() }
        val pending = metadata.value!!.pending!!
        val publicKey = keys.publicKey(pending.alias)
        metadata.failCommit = false
        val recovered = service().getOrCreateIdentity()
        assertEquals(pending.deviceId, recovered.identity.deviceId)
        assertArrayEquals(publicKey, IdentityCrypto.decodeBase64(recovered.identity.publicKey))
    }
    @Test fun resetCleanupFailureKeepsReplacementAndRetriesLater() {
        val original = service().getOrCreateIdentity()
        keys.failDelete = true
        val replacement = service().resetIdentity()
        assertNotEquals(original.identity.deviceId, replacement.identity.deviceId)
        assertEquals(2, keys.values.size)
        keys.failDelete = false
        assertEquals(replacement, service().getOrCreateIdentity())
        assertEquals(1, keys.values.size)
    }
    @Test fun corruptedMetadataNeverCountsAsFirstRun() {
        service().getOrCreateIdentity()
        metadata.readError = IdentityErrorKind.INCONSISTENT
        expectError(IdentityErrorKind.INCONSISTENT) { service().getOrCreateIdentity() }
        val replacement = service().resetIdentity()
        metadata.readError = null
        assertEquals(replacement, service().getOrCreateIdentity())
        assertEquals(1, keys.values.size)
    }
    @Test fun missingMetadataWithExistingKeyRequiresReset() {
        service().getOrCreateIdentity(); metadata.value = null
        expectError(IdentityErrorKind.INCONSISTENT) { service().getOrCreateIdentity() }
        service().resetIdentity()
        assertEquals(1, keys.values.size)
    }
    @Test fun invalidAliasAndPlatformCannotBeUsed() {
        service().getOrCreateIdentity()
        val journal = metadata.value!!
        metadata.value = journal.copy(active = journal.active!!.copy(alias = "unrelated.key"))
        expectError(IdentityErrorKind.INCONSISTENT) { service().getOrCreateIdentity() }
        metadata.value = journal.copy(active = journal.active.copy(identity = journal.active.identity.copy(platform = "macos")))
        expectError(IdentityErrorKind.INCONSISTENT) { service().getOrCreateIdentity() }
        metadata.value = journal.copy(pending = PendingIdentity(journal.active.alias, journal.active.identity.deviceId))
        expectError(IdentityErrorKind.INCONSISTENT) { service().getOrCreateIdentity() }
        metadata.value = journal.copy(cleanup = listOf(journal.active.alias))
        expectError(IdentityErrorKind.INCONSISTENT) { service().getOrCreateIdentity() }
    }
    @Test fun failedPendingWritePreservesExistingIdentity() {
        val original = service().getOrCreateIdentity()
        metadata.failWrite = true
        expectError(IdentityErrorKind.STORAGE_UNAVAILABLE) { service().resetIdentity() }
        metadata.failWrite = false
        assertEquals(original, service().getOrCreateIdentity())
        assertEquals(1, keys.values.size)
    }

    @Test fun everyCreationAndResetStorageBoundaryRecoversCommittedIdentity() {
        // Fail both before and after each storage operation. A write which committed
        // before its error must still remain the source of truth on restart.
        fun scenario(reset: Boolean, after: Boolean, boundary: Int?): Int {
            val metadata = MemoryMetadata()
            val keys = MemoryKeys()
            fun normal() = IdentityService(metadata, keys, { "Pixel" })
            if (reset) normal().getOrCreateIdentity()
            var operations = 0
            var enabled = true
            var triggered = false
            fun <T> operation(body: () -> T): T {
                val fails = enabled && ++operations == boundary
                if (fails) triggered = true
                if (fails && !after) throw IdentityException(IdentityErrorKind.STORAGE_UNAVAILABLE)
                val result = body()
                if (fails && after) throw IdentityException(IdentityErrorKind.STORAGE_UNAVAILABLE)
                return result
            }
            val faultMetadata = object : IdentityMetadataStore {
                override fun read(): IdentityJournal? = operation { metadata.read() }
                override fun write(journal: IdentityJournal) = operation { metadata.write(journal) }
            }
            val faultKeys = object : IdentityKeyStore {
                override fun aliases(): Set<String> = operation { keys.aliases() }
                override fun create(alias: String) = operation { keys.create(alias) }
                override fun publicKey(alias: String): ByteArray? = operation { keys.publicKey(alias) }
                override fun protection(alias: String): KeyProtection = operation { keys.protection(alias) }
                override fun sign(alias: String, message: ByteArray): ByteArray = operation { keys.sign(alias, message) }
                override fun delete(alias: String) = operation { keys.delete(alias) }
            }
            val service = IdentityService(faultMetadata, faultKeys, { "Pixel" })
            try { if (reset) service.resetIdentity() else service.getOrCreateIdentity() }
            catch (error: IdentityException) { assertEquals(IdentityErrorKind.STORAGE_UNAVAILABLE, error.kind) }
            if (boundary != null) assertTrue("Fault boundary was not exercised: $boundary", triggered)
            val measured = operations
            val committed = metadata.value?.active?.identity?.deviceId ?: metadata.value?.pending?.deviceId
            enabled = false
            val recovered = normal().getOrCreateIdentity()
            if (committed != null) assertEquals("reset=$reset, after=$after, boundary=$boundary", committed, recovered.identity.deviceId)
            assertEquals(1, keys.values.size)
            assertNull(metadata.value?.pending)
            return measured
        }
        for (reset in listOf(false, true)) {
            val boundaries = scenario(reset, false, null)
            assertTrue(boundaries > 0)
            for (after in listOf(false, true)) for (boundary in 1..boundaries) scenario(reset, after, boundary)
        }
    }
}
