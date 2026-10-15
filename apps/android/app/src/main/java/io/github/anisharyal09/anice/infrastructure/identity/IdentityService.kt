// SPDX-License-Identifier: GPL-3.0-or-later
// Serializes protected identity signing and atomic creation, replacement and recovery.
package io.github.anisharyal09.anice.infrastructure.identity

enum class IdentityErrorKind {
    STORAGE_UNAVAILABLE,
    KEY_MISSING,
    INCONSISTENT,
    CRYPTO_FAILURE,
}

/** Storage errors never trigger automatic key replacement. */
class IdentityException(val kind: IdentityErrorKind, cause: Throwable? = null) : Exception(kind.name, cause)

enum class KeyProtection(val label: String) {
    STRONGBOX("Hardware protected (StrongBox)"),
    HARDWARE("Hardware protected"),
    PLATFORM("Protected by Android Keystore"),
    UNKNOWN("Protection status unavailable"),
}

data class IdentitySnapshot(val identity: DeviceIdentity, val protection: KeyProtection)
data class IdentitySignature(val snapshot: IdentitySnapshot, val signature: ByteArray)
data class IdentityReference(val alias: String, val identity: DeviceIdentity)
data class PendingIdentity(val alias: String, val deviceId: String)
data class IdentityJournal(
    val active: IdentityReference? = null,
    val pending: PendingIdentity? = null,
    val cleanup: List<String> = emptyList(),
)

interface IdentityMetadataStore {
    fun read(): IdentityJournal?
    fun write(journal: IdentityJournal)
}

interface IdentityKeyStore {
    fun aliases(): Set<String>
    fun create(alias: String)
    fun publicKey(alias: String): ByteArray?
    fun protection(alias: String): KeyProtection
    fun sign(alias: String, message: ByteArray): ByteArray
    fun delete(alias: String)
}

/** Serializes creation, signing, and two-phase identity replacement. */
class IdentityService(
    private val metadata: IdentityMetadataStore,
    private val keys: IdentityKeyStore,
    private val deviceName: () -> String,
    private val aliasPrefix: String = "anice.identity.v1.",
) {
    @Volatile var onInvalidated: () -> Unit = {}
    @Volatile internal var identityLoads = 0L
        private set

    @Synchronized fun getOrCreateIdentity(): IdentitySnapshot {
        identityLoads++
        var journal = metadata.read()
        journal?.let(::validateJournal)
        if (journal == null) {
            if (keys.aliases().any { it.startsWith(aliasPrefix) }) throw IdentityException(IdentityErrorKind.INCONSISTENT)
            journal = IdentityJournal(pending = newPending())
            metadata.write(journal)
        }
        if (journal.active != null) {
            val snapshot = checkActive(journal.active, verifySigning = false)
            // An interrupted reset has not committed: the previous identity remains authoritative.
            if (journal.pending != null) {
                journal = journal.copy(pending = null, cleanup = journal.cleanup + journal.pending.alias)
                metadata.write(journal)
            }
            cleanup(journal)
            return snapshot
        }
        if (journal.pending == null) throw IdentityException(IdentityErrorKind.INCONSISTENT)
        val created = finishCreation(journal)
        return created
    }

    @Synchronized fun rename(value: String): IdentitySnapshot {
        val name = value.trim()
        require(name.isNotBlank() && name.codePointCount(0, name.length) <= 64)
        val snapshot = getOrCreateIdentity()
        val journal = metadata.read()?.also(::validateJournal) ?: throw IdentityException(IdentityErrorKind.INCONSISTENT)
        val active = journal.active ?: throw IdentityException(IdentityErrorKind.INCONSISTENT)
        if (active.identity != snapshot.identity) throw IdentityException(IdentityErrorKind.INCONSISTENT)
        val renamed = active.copy(identity = active.identity.copy(deviceName = name).validate())
        metadata.write(journal.copy(active = renamed))
        val updated = snapshot.copy(identity = renamed.identity)
        return updated
    }

    @Synchronized fun sign(message: ByteArray): IdentitySignature {
        val snapshot = getOrCreateIdentity()
        val journal = metadata.read()?.also(::validateJournal) ?: throw IdentityException(IdentityErrorKind.INCONSISTENT)
        val active = journal.active ?: throw IdentityException(IdentityErrorKind.INCONSISTENT)
        if (active.alias != aliasPrefix + snapshot.identity.deviceId ||
            active.identity.deviceId != snapshot.identity.deviceId ||
            active.identity.publicKey != snapshot.identity.publicKey ||
            active.identity.fingerprint != snapshot.identity.fingerprint) throw IdentityException(IdentityErrorKind.INCONSISTENT)
        // Verify the requested signature itself; an extra self-check would double private-key work.
        val signature = keys.sign(active.alias, message)
        if (!IdentityCrypto.verify(IdentityCrypto.decodeBase64(snapshot.identity.publicKey), message, signature)) {
            throw IdentityException(IdentityErrorKind.CRYPTO_FAILURE)
        }
        return IdentitySignature(snapshot, signature)
    }

    /** Called only after the UI confirms replacement. */
    @Synchronized fun resetIdentity(): IdentitySnapshot {
        onInvalidated()
        val previous = try { metadata.read()?.also(::validateJournal) } catch (error: IdentityException) {
            if (error.kind != IdentityErrorKind.INCONSISTENT) throw error
            null
        }
        val retired = keys.aliases().filter { it.startsWith(aliasPrefix) }
        val pending = newPending()
        val staged = IdentityJournal(previous?.active, pending, retired.filter { it != previous?.active?.alias })
        metadata.write(staged)
        val committed = finishCreation(staged)
        return committed
    }

    private fun newPending(): PendingIdentity {
        val id = DeviceIdentity.newId()
        return PendingIdentity(aliasPrefix + id, id)
    }

    private fun finishCreation(journal: IdentityJournal): IdentitySnapshot {
        val pending = journal.pending ?: throw IdentityException(IdentityErrorKind.INCONSISTENT)
        if (keys.publicKey(pending.alias) == null) keys.create(pending.alias)
        val bytes = keys.publicKey(pending.alias) ?: throw IdentityException(IdentityErrorKind.KEY_MISSING)
        val identity = DeviceIdentity(pending.deviceId, DeviceIdentity.displayName(deviceName()), "android",
            IdentityCrypto.encodeBase64(bytes), IdentityCrypto.fingerprint(bytes)).validate()
        val reference = IdentityReference(pending.alias, identity)
        // A pending key must prove signing access before the journal can make it authoritative.
        val snapshot = checkActive(reference, verifySigning = true)
        val committed = IdentityJournal(active = reference,
            cleanup = (journal.cleanup + listOfNotNull(journal.active?.alias)).distinct().filter { it != reference.alias })
        metadata.write(committed)
        cleanup(committed)
        return snapshot
    }

    private fun checkActive(reference: IdentityReference, verifySigning: Boolean): IdentitySnapshot {
        try { reference.identity.validate() } catch (error: Exception) { throw IdentityException(IdentityErrorKind.INCONSISTENT, error) }
        val bytes = keys.publicKey(reference.alias) ?: throw IdentityException(IdentityErrorKind.KEY_MISSING)
        if (IdentityCrypto.encodeBase64(bytes) != reference.identity.publicKey) throw IdentityException(IdentityErrorKind.INCONSISTENT)
        if (verifySigning) {
            val challenge = "aniCe identity self-check v1".toByteArray(Charsets.UTF_8)
            if (!IdentityCrypto.verify(bytes, challenge, keys.sign(reference.alias, challenge))) {
                throw IdentityException(IdentityErrorKind.CRYPTO_FAILURE)
            }
        }
        return IdentitySnapshot(reference.identity, keys.protection(reference.alias))
    }

    private fun validateJournal(journal: IdentityJournal) {
        try {
            require(journal.active != null || journal.pending != null)
            journal.active?.let {
                it.identity.validate()
                require(it.identity.platform == "android" && it.alias == aliasPrefix + it.identity.deviceId)
            }
            journal.pending?.let {
                require(it.deviceId.matches(DEVICE_ID))
                require(it.alias == aliasPrefix + it.deviceId && it.alias != journal.active?.alias)
            }
            require(journal.cleanup.distinct() == journal.cleanup)
            require(journal.cleanup.all { it.startsWith(aliasPrefix) && it != journal.active?.alias && it != journal.pending?.alias })
        } catch (error: Exception) { throw IdentityException(IdentityErrorKind.INCONSISTENT, error) }
    }

    private fun cleanup(journal: IdentityJournal) {
        val remaining = journal.cleanup.filter { alias ->
            if (alias == journal.active?.alias || !alias.startsWith(aliasPrefix)) return@filter true
            try { keys.delete(alias); false } catch (_: IdentityException) { true }
        }
        if (remaining != journal.cleanup) {
            // Cleanup is retryable. A committed reset must never be rolled back after this point.
            try { metadata.write(journal.copy(cleanup = remaining)) } catch (_: IdentityException) { }
        }
    }

    private companion object {
        // Compiled once: journal validation runs on every identity read, that is on every record.
        val DEVICE_ID = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    }
}
