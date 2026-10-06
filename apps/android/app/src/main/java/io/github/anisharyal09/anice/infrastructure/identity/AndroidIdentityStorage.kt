// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.identity

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.io.FileNotFoundException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import org.json.JSONArray
import org.json.JSONObject

/** Atomic, backup-excluded identity metadata. */
class AndroidIdentityMetadata(context: Context, filename: String = "identity-v1.json") : IdentityMetadataStore {
    private val file = AtomicFile(File(context.noBackupFilesDir, filename))
    override fun read(): IdentityJournal? {
        val bytes = try { file.readFully() } catch (error: FileNotFoundException) {
            if (!file.baseFile.exists()) return null
            throw IdentityException(IdentityErrorKind.STORAGE_UNAVAILABLE, error)
        } catch (error: Exception) { throw IdentityException(IdentityErrorKind.STORAGE_UNAVAILABLE, error) }
        try {
            val json = JSONObject(bytes.toString(Charsets.UTF_8))
            require(json.get("storageVersion") is Int && json.getInt("storageVersion") == 1)
            require(json.keys().asSequence().all { it in setOf("storageVersion", "active", "pending", "cleanup") })
            require(!json.has("active") || json.get("active") is JSONObject)
            require(!json.has("pending") || json.get("pending") is JSONObject)
            require(json.get("cleanup") is JSONArray)
            val active = json.optJSONObject("active")?.let {
                IdentityReference(it.getString("alias"), DeviceIdentity.fromJson(it.getJSONObject("identity")))
            }
            val pending = json.optJSONObject("pending")?.let { PendingIdentity(it.getString("alias"), it.getString("deviceId")) }
            val list = json.getJSONArray("cleanup")
            val cleanup = (0 until list.length()).map { list.getString(it) }
            fun validAlias(alias: String): Boolean = Regex("^anice\\.(identity|test)\\.[a-zA-Z0-9.-]+$").matches(alias)
            require(active == null || (validAlias(active.alias) && active.alias.endsWith(active.identity.deviceId)))
            require(pending == null || (validAlias(pending.alias) && pending.alias.endsWith(pending.deviceId) &&
                pending.deviceId.matches(Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))))
            require(cleanup.all(::validAlias) && cleanup.none { it == active?.alias || it == pending?.alias })
            require(active != null || pending != null)
            return IdentityJournal(active, pending, cleanup)
        } catch (error: Exception) { throw IdentityException(IdentityErrorKind.INCONSISTENT, error) }
    }
    override fun write(journal: IdentityJournal) {
        val json = JSONObject().put("storageVersion", 1).put("cleanup", JSONArray(journal.cleanup))
        journal.active?.let { json.put("active", JSONObject().put("alias", it.alias).put("identity", it.identity.toJson())) }
        journal.pending?.let { json.put("pending", JSONObject().put("alias", it.alias).put("deviceId", it.deviceId)) }
        var stream: java.io.FileOutputStream? = null
        try {
            stream = file.startWrite()
            stream.write(json.toString().toByteArray(Charsets.UTF_8))
            file.finishWrite(stream)
        } catch (error: Exception) {
            file.failWrite(stream)
            throw IdentityException(IdentityErrorKind.STORAGE_UNAVAILABLE, error)
        }
    }
}

/** Non-exportable signing keys without per-use authentication. */
class AndroidIdentityKeys : IdentityKeyStore {
    private fun store(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun <T> access(block: () -> T): T = try { block() }
        catch (error: IdentityException) { throw error }
        catch (error: android.security.keystore.KeyPermanentlyInvalidatedException) { throw IdentityException(IdentityErrorKind.KEY_MISSING, error) }
        catch (error: Exception) { throw IdentityException(IdentityErrorKind.STORAGE_UNAVAILABLE, error) }
    override fun aliases(): Set<String> = access { store().aliases().toList().toSet() }
    override fun create(alias: String): Unit = access {
        require(!store().containsAlias(alias))
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").run {
            initialize(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256).setUserAuthenticationRequired(false).build())
            generateKeyPair()
        }
        Unit
    }
    override fun publicKey(alias: String): ByteArray? = access {
        val store = store()
        if (!store.containsAlias(alias)) null else {
            val key = store.getCertificate(alias)?.publicKey ?: throw IdentityException(IdentityErrorKind.KEY_MISSING)
            IdentityCrypto.exportPublicKey(key)
        }
    }
    override fun protection(alias: String): KeyProtection = access {
        val key = store().getKey(alias, null) as? PrivateKey ?: throw IdentityException(IdentityErrorKind.KEY_MISSING)
        val info = KeyFactory.getInstance(key.algorithm, "AndroidKeyStore").getKeySpec(key, KeyInfo::class.java)
        if (Build.VERSION.SDK_INT >= 31) {
            when (info.securityLevel) {
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> KeyProtection.STRONGBOX
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT, KeyProperties.SECURITY_LEVEL_UNKNOWN_SECURE -> KeyProtection.HARDWARE
                KeyProperties.SECURITY_LEVEL_SOFTWARE -> KeyProtection.PLATFORM
                else -> KeyProtection.UNKNOWN
            }
        } else {
            @Suppress("DEPRECATION")
            if (info.isInsideSecureHardware) KeyProtection.HARDWARE else KeyProtection.PLATFORM
        }
    }
    override fun sign(alias: String, message: ByteArray): ByteArray = access {
        val key = store().getKey(alias, null) as? PrivateKey ?: throw IdentityException(IdentityErrorKind.KEY_MISSING)
        Signature.getInstance("SHA256withECDSA").run { initSign(key); update(message); sign() }
    }
    override fun delete(alias: String): Unit = access { store().deleteEntry(alias) }
}
