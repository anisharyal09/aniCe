// SPDX-License-Identifier: GPL-3.0-or-later
// Persists display-only peer names and private aliases and exchanges snapshots on existing secured DATA.
package io.github.anisharyal09.anice.infrastructure.connections

import android.content.Context
import androidx.compose.runtime.*
import io.github.anisharyal09.anice.AniCeApplication
import io.github.anisharyal09.anice.infrastructure.identity.DeviceIdentity
import io.github.anisharyal09.anice.infrastructure.session.*
import io.github.anisharyal09.anice.infrastructure.storage.AtomicJournal
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import io.github.anisharyal09.anice.infrastructure.identity.IdentityService
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustStore

internal data class NameReport(val revision: Long, val name: String)
internal object NameWire {
    const val TAG = "aniCe device names"
    fun valid(name: String) = name.isNotBlank() && name == name.trim() &&
        name.codePointCount(0, name.length) <= 64 && name.toByteArray().size <= 256
    fun encode(report: NameReport? = null): ByteArray = SessionCbor.encode(Cbor.Array(listOf(
        Cbor.Text(TAG), Cbor.Integer(1), Cbor.Integer(if (report == null) 1 else 2),
        Cbor.Array(if (report == null) listOf(Cbor.Integer(1)) else {
            require(report.revision >= 0 && valid(report.name))
            listOf(Cbor.Integer(report.revision), Cbor.Text(report.name))
        }))), 512)
    fun decode(bytes: ByteArray): Pair<Boolean, NameReport?>? {
        if (bytes.size > 512) return null
        val row = (SessionCbor.decode(bytes) as? Cbor.Array)?.value ?: return null
        if ((row.firstOrNull() as? Cbor.Text)?.value != TAG) return null
        require(row.size == 4 && row[1] == Cbor.Integer(1))
        val fields = (row[3] as? Cbor.Array)?.value ?: error("Invalid names fields")
        return when (row[2]) {
            Cbor.Integer(1) -> { require(fields == listOf(Cbor.Integer(1))); true to null }
            Cbor.Integer(2) -> {
                require(fields.size == 2)
                val revision = (fields[0] as? Cbor.Integer)?.value ?: error("Invalid revision")
                val name = (fields[1] as? Cbor.Text)?.value ?: error("Invalid name")
                require(revision >= 0 && valid(name))
                false to NameReport(revision, name)
            }
            else -> error("Unknown names kind")
        }
    }
}

internal data class PeerNameEntry(val report: NameReport? = null, val nickname: PeerNickname? = null)

class PeerNames internal constructor(
    private val identity: IdentityService,
    private val trust: () -> PeerTrustStore,
    private val read: () -> ByteArray?,
    private val write: (ByteArray) -> Unit,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val main: CoroutineDispatcher = Dispatchers.Main.immediate,
) : FeatureHandler {
    constructor(context: Context) : this(
        (context.applicationContext as AniCeApplication).identityService,
        { (context.applicationContext as AniCeApplication).trustStore },
        AtomicJournal(File(context.noBackupFilesDir, "peer_names.json"))::read,
        AtomicJournal(File(context.noBackupFilesDir, "peer_names.json"))::write,
    )
    companion object { internal var current: PeerNames? = null }
    init { current = this }
    private val mutex = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + main)
    @Volatile private var generation = 0
    private var localFingerprint: String? = null
    private var entries by mutableStateOf(emptyMap<String, PeerNameEntry>())
    var failed by mutableStateOf(false); private set
    private class Link(val channel: SecuredChannel) {
        val live = AtomicBoolean(true)
        var capability = false
        var remote = false
        var sending = false
        var pending: NameReport? = null
    }
    private val links = mutableMapOf<String, Link>()
    private var refreshing = false
    private var refreshAgain = false

    fun deviceName(peer: DeviceIdentity): String = entries[PeerNickname.credential(peer)]?.report?.name ?: peer.deviceName
    fun displayName(peer: DeviceIdentity): String =
        entries[PeerNickname.credential(peer)]?.nickname?.takeIf { it.enabled }?.name ?: deviceName(peer)
    internal fun nickname(peer: DeviceIdentity) = entries[PeerNickname.credential(peer)]?.nickname

    private suspend fun mutate(
        valid: () -> Boolean = { true },
        operation: (JSONObject, List<DeviceIdentity>) -> Unit,
    ): NameReport =
        mutex.withLock {
            val epoch = generation
            val result = withContext(io) {
                check(epoch == generation && valid())
                val local = identity.getOrCreateIdentity().identity
                val peers = trust().list(local.fingerprint).map { it.peer }
                val original = read()
                require(original == null || original.size <= 1_048_576)
                val loaded = original?.let { JSONObject(String(it, Charsets.UTF_8)) } ?: JSONObject()
                require(loaded.toString().toByteArray().size <= 1_048_576)
                val next = if (loaded.optString("local") == local.fingerprint) loaded else JSONObject()
                    .put("local", local.fingerprint).put("revision", 0L).put("name", local.deviceName)
                    .put("peers", JSONObject())
                require(next.getLong("revision") >= 0 && NameWire.valid(next.getString("name")))
                val rows = next.getJSONObject("peers")
                rows.keys().asSequence().toList().forEach { key ->
                    val row = rows.getJSONObject(key)
                    if (row.has("name")) require(row.getLong("revision") >= 0 && NameWire.valid(row.getString("name")))
                    if (row.optString("nickname").isNotEmpty())
                        PeerNickname(row.getString("nickname"), row.optBoolean("enabled", false))
                }
                val keep = peers.map(PeerNickname::credential).toSet()
                rows.keys().asSequence().toList().filter { it !in keep }.forEach(rows::remove)
                if (next.getString("name") != local.deviceName) {
                    val revision = next.getLong("revision")
                    check(revision >= 0 && revision < Long.MAX_VALUE)
                    next.put("revision", revision + 1).put("name", local.deviceName)
                }
                operation(next, peers)
                val data = next.toString().toByteArray()
                require(data.size <= 1_048_576)
                check(epoch == generation && valid())
                check(identity.getOrCreateIdentity().identity == local)
                val active = trust().list(local.fingerprint).map { PeerNickname.credential(it.peer) }.toSet()
                check(active == keep)
                if (original == null || !data.contentEquals(original)) write(data)
                next
            }
            check(epoch == generation && valid())
            localFingerprint = result.getString("local")
            val rows = result.getJSONObject("peers")
            entries = rows.keys().asSequence().associateWith { key ->
                val row = rows.getJSONObject(key)
                val report = if (row.has("name")) NameReport(row.getLong("revision"), row.getString("name")) else null
                require(report == null || report.revision >= 0 && NameWire.valid(report.name))
                val alias = row.optString("nickname").takeIf { it.isNotEmpty() }
                    ?.let { PeerNickname(it, row.optBoolean("enabled", false)) }
                PeerNameEntry(report, alias)
            }
            failed = false
            NameReport(result.getLong("revision"), result.getString("name"))
        }

    fun refresh() {
        refreshAgain = true
        if (refreshing) return
        refreshing = true
        scope.launch {
            try {
                while (refreshAgain) {
                    refreshAgain = false
                    try {
                        val report = mutate { _, _ -> }
                        links.values.forEach { it.pending = report; flush(it) }
                    } catch (_: Exception) { failed = true }
                }
            } finally { refreshing = false }
        }
    }
    fun invalidate() {
        generation++
        links.values.forEach { it.live.set(false) }
        links.clear()
        entries = emptyMap()
        localFingerprint = null
        refresh()
    }

    suspend fun saveNickname(peer: DeviceIdentity, name: String, enabled: Boolean) {
        val alias = PeerNickname(name.trim(), enabled)
        val local = localFingerprint
        mutate { root, peers ->
            check(local == null || root.getString("local") == local)
            check(peers.any { PeerNickname.credential(it) == PeerNickname.credential(peer) })
            val rows = root.getJSONObject("peers")
            val key = PeerNickname.credential(peer)
            val row = rows.optJSONObject(key) ?: JSONObject()
            row.put("nickname", alias.name).put("enabled", alias.enabled)
            rows.put(key, row)
        }
    }

    override fun available(channel: SecuredChannel) {
        links[channel.descriptor.transport]?.live?.set(false)
        links[channel.descriptor.transport] = Link(channel)
        refresh()
    }
    override fun retired(descriptor: ChannelDescriptor) {
        if (links[descriptor.transport]?.channel?.descriptor?.instance == descriptor.instance)
            links.remove(descriptor.transport)?.live?.set(false)
    }
    override fun capacityAvailable(descriptor: ChannelDescriptor) {
        links[descriptor.transport]?.takeIf { it.channel.descriptor.instance == descriptor.instance }?.let(::flush)
    }
    override suspend fun handle(descriptor: ChannelDescriptor, bytes: ByteArray): DataHandling {
        val link = links[descriptor.transport]?.takeIf { it.channel.descriptor.instance == descriptor.instance }
            ?: return DataHandling.DISCARDED
        val message = try { NameWire.decode(bytes) ?: return DataHandling.UNRECOGNIZED }
            catch (_: Exception) { return DataHandling.DISCARDED }
        if (message.first) { link.remote = true; flush(link); return DataHandling.HANDLED }
        if (!link.remote) return DataHandling.DISCARDED
        val report = message.second ?: return DataHandling.DISCARDED
        return try {
            mutate(valid = { link.live.get() }) { root, peers ->
                check(peers.any { PeerNickname.credential(it) == PeerNickname.credential(descriptor.peer) })
                val rows = root.getJSONObject("peers")
                val key = PeerNickname.credential(descriptor.peer)
                val row = rows.optJSONObject(key) ?: JSONObject()
                val previous = row.optLong("revision", -1)
                require(report.revision > previous ||
                    report.revision == previous && report.name == row.optString("name"))
                row.put("name", report.name).put("revision", report.revision)
                rows.put(key, row)
            }
            DataHandling.HANDLED
        } catch (_: Exception) { DataHandling.DISCARDED }
    }
    private fun flush(link: Link) {
        if (link.sending || links[link.channel.descriptor.transport] !== link) return
        link.sending = true
        scope.launch {
            try {
                while (links[link.channel.descriptor.transport] === link) {
                    val capability = !link.capability
                    val report = if (capability) null else if (link.remote) link.pending else break
                    if (!capability && report == null) break
                    try { link.channel.sendData(NameWire.encode(report)) } catch (_: Exception) { break }
                    if (capability) link.capability = true
                    else if (link.pending == report) link.pending = null
                }
            } finally { link.sending = false }
        }
    }
    internal suspend fun awaitRefresh() { mutate { _, _ -> } }
    internal fun close() {
        generation++
        links.values.forEach { it.live.set(false) }
        links.clear()
        scope.cancel()
        if (current === this) current = null
    }
}
