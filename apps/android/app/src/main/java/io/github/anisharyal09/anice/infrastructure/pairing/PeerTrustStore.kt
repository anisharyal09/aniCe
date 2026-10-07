// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.anisharyal09.anice.infrastructure.pairing

import android.util.AtomicFile
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.identity.IdentityCrypto
import java.io.File
import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject

data class PeerTrustRecord(
    val peer: DeviceIdentity,
    val localFingerprint: String,
    val method: PairingMethod,
    val pairedAt: Long,
    val transcriptHash: ByteArray,
    val receipt: ByteArray? = null,
    val active: Boolean = false,
) {
    fun json(): JSONObject =
        JSONObject()
            .put("peer", peer.toJson())
            .put("localFingerprint", localFingerprint)
            .put("method", method.wire)
            .put("pairedAt", pairedAt)
            .put("transcriptHash", Base64.getEncoder().encodeToString(transcriptHash))
            .put(
                "receipt",
                receipt?.let { Base64.getEncoder().encodeToString(it) } ?: JSONObject.NULL,
            )
            .put("active", active)
}

class TrustStoreCorruptException : Exception("Local trust records need recovery")

interface TrustPersistence {
    fun read(): ByteArray?

    fun write(bytes: ByteArray)

    fun quarantine() {
        throw IllegalStateException("Recovery unavailable")
    }
}

private class AndroidTrustPersistence(file: File) : TrustPersistence {
    private val file = AtomicFile(file)

    override fun read(): ByteArray? =
        if (file.baseFile.exists()) file.openRead().use { it.readBytes() } else null

    override fun quarantine() {
        val suffix = ".quarantined-" + java.util.UUID.randomUUID()
        for (source in listOf(file.baseFile, File(file.baseFile.path + ".bak"))) {
            if (source.exists()) check(source.renameTo(File(source.path + suffix)))
        }
    }

    override fun write(bytes: ByteArray) {
        val stream = file.startWrite()
        try {
            stream.write(bytes)
            file.finishWrite(stream)
        } catch (e: Exception) {
            file.failWrite(stream)
            throw e
        }
    }
}

class PeerTrustStore(private val persistence: TrustPersistence) {
    constructor(file: File) : this(AndroidTrustPersistence(file))

    companion object {
        fun recover(file: File): PeerTrustStore {
            val persistence = AndroidTrustPersistence(file)
            persistence.quarantine()
            return PeerTrustStore(persistence)
        }
    }

    private var records = mutableListOf<PeerTrustRecord>()

    init {
        val data = persistence.read()
        if (data != null) {
            try {
                require(data.size <= 1048576)
                val root = JSONObject(String(data, Charsets.UTF_8))
                require(root.getInt("version") == 1)
                val rows = root.getJSONArray("records")
                require(rows.length() <= 129)
                repeat(rows.length()) { i ->
                    val r = rows.getJSONObject(i)
                    val peer = DeviceIdentity.fromJson(r.getJSONObject("peer"))
                    val hash = Base64.getDecoder().decode(r.getString("transcriptHash"))
                    require(hash.size == 32)
                    val receipt =
                        if (r.isNull("receipt")) null
                        else Base64.getDecoder().decode(r.getString("receipt"))
                    val row =
                        PeerTrustRecord(
                            peer,
                            r.getString("localFingerprint"),
                            PairingMethod.entries.first { it.wire == r.getInt("method") },
                            r.getLong("pairedAt"),
                            hash,
                            receipt,
                            r.getBoolean("active"),
                        )
                    if (row.active) {
                        require(
                            receipt != null &&
                                IdentityCrypto.verify(
                                    IdentityCrypto.decodeBase64(peer.publicKey),
                                    PairingCodec.receipt(
                                        hash,
                                        if (peer.platform == "macos") 2 else 1,
                                    ),
                                    receipt,
                                )
                        )
                        records.add(row)
                    }
                }
                require(records.size <= 128)
            } catch (_: Exception) {
                throw TrustStoreCorruptException()
            }
        }
        write()
    }

    @Synchronized
    fun list(local: String) = records.filter { it.active && it.localFingerprint == local }

    @Synchronized
    fun prepare(row: PeerTrustRecord) {
        val isExisting = records.any { it.peer.deviceId == row.peer.deviceId }
        require(!row.active && row.transcriptHash.size == 32 && (isExisting || records.size < 128))
        row.peer.validate()
        require(
            records.none {
                it.peer.deviceId == row.peer.deviceId && it.peer.publicKey != row.peer.publicKey
            }
        )
        mutate {
            removeAll { !it.active && it.peer.deviceId == row.peer.deviceId }
            add(row)
        }
    }

    @Synchronized
    fun activate(id: String, hash: ByteArray, receipt: ByteArray) {
        val row =
            records.firstOrNull {
                !it.active && it.peer.deviceId == id && it.transcriptHash.contentEquals(hash)
            } ?: throw PairingException()
        require(
            IdentityCrypto.verify(
                IdentityCrypto.decodeBase64(row.peer.publicKey),
                PairingCodec.receipt(hash, if (row.peer.platform == "macos") 2 else 1),
                receipt,
            )
        )
        mutate {
            removeAll { it.peer.deviceId == id }
            add(row.copy(receipt = receipt, active = true))
        }
    }

    @Synchronized fun remove(id: String) = mutate { removeAll { it.peer.deviceId == id } }

    @Synchronized fun discardPending() = mutate { removeAll { !it.active } }

    private fun mutate(block: MutableList<PeerTrustRecord>.() -> Unit) {
        val old = records
        records = records.toMutableList().apply(block)
        try {
            write()
        } catch (e: Exception) {
            records = old
            throw e
        }
    }

    private fun write() {
        val data =
            JSONObject()
                .put("version", 1)
                .put("records", JSONArray().apply { records.forEach { put(it.json()) } })
                .toString()
                .toByteArray()
        persistence.write(data)
    }
}
