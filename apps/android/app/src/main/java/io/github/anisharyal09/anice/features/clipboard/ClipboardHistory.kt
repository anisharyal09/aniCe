// SPDX-License-Identifier: GPL-3.0-or-later
// Serializes bounded, opt-in local clipboard history outside backup storage.
package io.github.anisharyal09.anice.features.clipboard

import androidx.compose.runtime.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

data class ClipboardHistoryEntry(val id: String, val text: String, val origin: String, val timestamp: Long, val credential: String? = null)
interface ClipboardHistoryStorage {
    fun load(): List<ClipboardHistoryEntry>?
    fun save(entries: List<ClipboardHistoryEntry>)
    fun delete()
}
class ClipboardHistoryFile(private val file: File) : ClipboardHistoryStorage {
    private fun clearTemporary() {
        file.parentFile?.listFiles()?.filter { it.name.matches(Regex("clipboard-[0-9]+\\.tmp")) }?.forEach { check(it.delete()) }
    }
    override fun load(): List<ClipboardHistoryEntry>? {
        clearTemporary()
        if (!file.exists()) return null
        require(file.length() <= 8_000_000)
        val bytes = file.inputStream().use { input ->
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (output.size() <= 8_000_000) {
                val count = input.read(buffer, 0, minOf(buffer.size, 8_000_001 - output.size()))
                if (count < 0) break
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
        require(bytes.size <= 8_000_000)
        val root = JSONObject(Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString())
        require(root.getInt("version") == 1)
        val rows = root.getJSONArray("entries"); require(rows.length() <= 20)
        val result = (0 until rows.length()).map { i -> rows.getJSONObject(i).let {
            ClipboardHistoryEntry(it.getString("id"), it.getString("text"), it.getString("origin"), it.getLong("timestamp"), if (it.has("credential")) it.getString("credential") else null)
        } }
        require(result.map { it.id }.toSet().size == result.size)
        require(result.all { validHistoryText(it.text) && it.origin in setOf("mac", "phone") && it.timestamp >= 0 && runCatching { UUID.fromString(it.id).toString() == it.id }.getOrDefault(false) && (it.credential?.length ?: 0) <= 512 })
        return result
    }
    override fun save(entries: List<ClipboardHistoryEntry>) {
        val rows = JSONArray()
        entries.forEach { entry -> rows.put(JSONObject().put("id", entry.id).put("text", entry.text).put("origin", entry.origin).put("timestamp", entry.timestamp).apply { entry.credential?.let { put("credential", it) } }) }
        val bytes = JSONObject().put("version", 1).put("entries", rows).toString().toByteArray(Charsets.UTF_8)
        val directory = file.parentFile!!; check(directory.isDirectory || directory.mkdirs())
        val temp = File.createTempFile("clipboard-", ".tmp", directory)
        try {
            check(temp.setReadable(false, false) && temp.setWritable(false, false) && temp.setReadable(true, true) && temp.setWritable(true, true))
            java.io.FileOutputStream(temp).use { it.write(bytes); it.fd.sync() }
            Files.move(temp.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally { if (temp.exists()) check(temp.delete()) }
    }
    override fun delete() { clearTemporary(); if (file.exists()) check(file.delete()) }
}
internal fun validHistoryText(text: String): Boolean = text.isNotEmpty() && '\u0000' !in text && text.length <= 65536 && try {
    Charsets.UTF_8.newEncoder().encode(java.nio.CharBuffer.wrap(text)).remaining() <= 65536
} catch (_: java.nio.charset.CharacterCodingException) { false }

class ClipboardHistory(private val storage: ClipboardHistoryStorage? = null, dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate) {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val lock = Mutex()
    var enabled by mutableStateOf(false); private set
    var entries by mutableStateOf<List<ClipboardHistoryEntry>>(emptyList()); private set
    var error by mutableStateOf<String?>(null); private set
    private data class Capture(val sample: ClipboardSample, val origin: String, val credential: String?)
    private val captures = ArrayDeque<Capture>()
    private var recording = false
    private var preferenceRevision = 0
    var onChanged: () -> Unit = {}
    init { command { val saved = withContext(Dispatchers.IO) { storage?.load() }; if (preferenceRevision == 0) { enabled = saved != null; entries = saved ?: emptyList() }; onChanged() } }
    private fun command(block: suspend () -> Unit) { scope.launch { lock.withLock {
        try { block(); error = null } catch (_: java.io.IOException) { error = "Could not update clipboard history. Clear history or try again." }
        catch (_: IllegalArgumentException) { error = "Clipboard history could not be read. Clear history to reset it." }
        catch (_: IllegalStateException) { error = "Could not update clipboard history. Clear history or try again." }
        catch (_: org.json.JSONException) { error = "Clipboard history could not be read. Clear history to reset it." }
        catch (_: SecurityException) { error = "Clipboard history storage is unavailable." }
    } } }
    fun setKeepingHistory(value: Boolean) {
        error = null
        val revision = ++preferenceRevision
        if (!value) { enabled = false; captures.clear(); onChanged() }
        command {
            val rows = entries
            withContext(Dispatchers.IO) { if (value) storage?.save(rows) else storage?.delete() }
            if (revision == preferenceRevision) enabled = value; if (!value) entries = emptyList(); onChanged()
        }
    }
    fun record(sample: ClipboardSample, origin: String, credential: String? = null) {
        if (!enabled || sample.sensitive || sample.excluded || !validHistoryText(sample.text)) return
        if (captures.size == 20) captures.removeFirst()
        captures.addLast(Capture(sample, origin, credential))
        if (recording) return
        recording = true
        command {
            try {
                while (enabled && captures.isNotEmpty()) {
                    val capture = captures.removeFirst()
                    val first = entries.firstOrNull()
                    val row = ClipboardHistoryEntry(if (first?.text == capture.sample.text && first.origin == capture.origin) first.id else UUID.randomUUID().toString(), capture.sample.text, capture.origin, System.currentTimeMillis(), capture.credential)
                    val next = (listOf(row) + entries.filter { it.id != row.id }).take(20)
                    withContext(Dispatchers.IO) { storage?.save(next) }; if (enabled) entries = next
                }
            } finally { recording = false; captures.clear() }
        }
    }

    fun delete(id: String) = replace { it.filterNot { row -> row.id == id } }
    fun clear() = command { val keep = enabled; withContext(Dispatchers.IO) { if (keep) storage?.save(emptyList()) else storage?.delete() }; entries = emptyList() }
    fun reset() { entries = emptyList(); setKeepingHistory(false) }
    fun prune(credentials: Set<String>) = replace { it.filter { row -> row.credential == null || row.credential in credentials } }
    private fun replace(transform: (List<ClipboardHistoryEntry>) -> List<ClipboardHistoryEntry>) = command {
        val next = transform(entries)
        val keep = enabled
        if (next != entries) { withContext(Dispatchers.IO) { if (keep) storage?.save(next) else storage?.delete() }; if (enabled) entries = next else if (!keep) entries = emptyList() }
    }
}
