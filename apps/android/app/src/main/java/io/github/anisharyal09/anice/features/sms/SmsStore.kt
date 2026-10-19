// SPDX-License-Identifier: GPL-3.0-or-later
// Reads provider threads and history with timestamp-only SQL and in-memory lexical messageId ordering.
package io.github.anisharyal09.anice.features.sms

import android.Manifest
import android.content.ContentResolver
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Telephony
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Locale

class SmsStoreException : Exception()
class SmsPagingUnsupported : Exception()

data class SmsThreadRecord(val threadId: String, val address: String, val snippet: String, val dateMillis: Long, val unreadCount: Long)
class SmsThreadPage(
    val threads: List<SmsThreadRecord>,
    val skipped: Int,
    val partial: Boolean = false,
    val nextBeforeMillis: Long = 0,
    val nextBeforeThreadId: String = "",
    val more: Boolean = false,
)
data class SmsHistoryMessage(val messageId: String, val address: String, val dateMillis: Long, val direction: Long, val unread: Boolean, val text: String, val threadId: String = "", val subscriptionId: Int = 0)
class SmsHistoryPage(val messages: List<SmsHistoryMessage>, val nextBeforeMillis: Long, val nextBeforeMessageId: String, val more: Boolean, val skipped: Int, val partial: Boolean = false)

interface SmsStore {
    /** Returns null when READ_SMS is not granted; throws [SmsStoreException] when every source failed. */
    suspend fun threads(limit: Int, beforeMillis: Long, beforeThreadId: String): SmsThreadPage?

    /** Returns null when READ_SMS is not granted; throws [SmsStoreException] when every source failed. */
    suspend fun history(threadId: String, beforeMillis: Long, beforeMessageId: String, limit: Int): SmsHistoryPage?

    /** Substring search with the same page and tie semantics as [history]; the caller validates the 2..64-byte query. */
    suspend fun search(query: String, beforeMillis: Long, beforeMessageId: String, limit: Int): SmsHistoryPage?
}

data class SmsConversationRow(
    val threadId: Long,
    val dateMillis: Long?,
    val snippet: String?,
    val recipientIds: List<Long>,
    val messageCount: Long?,
    val read: Long?,
    val address: String? = null,
    val unread: Long? = null,
)
data class SmsConversationPage(val rows: List<SmsConversationRow>, val partial: Boolean = false)

data class SmsThreadFallback(val address: String, val dateMillis: Long, val snippet: String?, val unread: Boolean?)
data class SmsRawMessage(val id: Long, val dateMillis: Long, val address: String?, val body: String?, val direction: Long, val unread: Boolean, val supported: Boolean, val threadId: Long = 0L, val subscriptionId: Int = 0)

/** Raw provider surface. Implementations throw on provider failure; the store owns sanitization and paging. */
interface SmsProvider {
    fun conversations(limit: Int, beforeMillis: Long, beforeThreadId: String): SmsConversationPage
    /** At most 2,049 rows, including the overflow sentinel, from one clamped timestamp group. */
    fun conversationDateGroup(millis: Long): List<SmsConversationRow>
    /** Unread incoming SMS rows per provider thread; the threads view's `read` flag is not a count. */
    fun unreadCounts(): Map<Long, Long>
    fun canonicalAddresses(ids: List<Long>): Map<Long, String>
    fun newestThreadRow(threadId: Long): SmsThreadFallback?
    fun directThreads(limit: Int): SmsConversationPage
    fun smsHistory(threadId: Long, upperMillis: Long?, limit: Int): List<SmsRawMessage>
    fun smsDateGroup(threadId: Long, millis: Long): List<SmsRawMessage>
    fun mmsHistory(threadId: Long, upperMillis: Long?, limit: Int): List<SmsRawMessage>
    fun mmsDateGroup(threadId: Long, millis: Long): List<SmsRawMessage>
    /** SMS bodies containing the LIKE pattern (see the store for escaping), date-bounded and newest first. */
    fun smsSearch(pattern: String, upperMillis: Long?, limit: Int): List<SmsRawMessage>
    /** Rows of one exact timestamp whose bodies match, or one side of the contract's clamp bounds. */
    fun smsSearchGroup(pattern: String, millis: Long): List<SmsRawMessage>
    fun mmsSearch(pattern: String, upperMillis: Long?, limit: Int): List<SmsRawMessage>
    fun mmsSearchGroup(pattern: String, millis: Long): List<SmsRawMessage>
}

/** Canonical conversation key: digits with one optional leading `+`, or the trimmed uppercase text for alphanumeric sender IDs. */
fun smsNormalizedAddress(raw: String): String {
    val trimmed = raw.trim()
    if (trimmed.any { it.isLetter() }) return trimmed.uppercase(Locale.ROOT)
    val digits = trimmed.filter { it in '0'..'9' }
    return if (digits.isNotEmpty() && trimmed.startsWith("+")) "+$digits" else digits
}

/** Clamps provider milliseconds into the contract's 0..2^53-1 range. */
fun smsClampDate(value: Long): Long = value.coerceIn(0, SmsWireMessage.MAX_DATE)

private fun smsMmsDate(seconds: Long): Long = when {
    seconds <= 0 -> 0
    seconds > SmsWireMessage.MAX_DATE / 1000 -> SmsWireMessage.MAX_DATE
    else -> seconds * 1000
}

/** Replaces NUL and returns strict UTF-8 text, or null when the input cannot be encoded. */
fun smsSanitizeText(text: String): String? {
    val clean = text.replace('\u0000', '\uFFFD')
    return try {
        Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).encode(CharBuffer.wrap(clean))
        clean
    } catch (_: java.nio.charset.CharacterCodingException) {
        null
    }
}

/** Truncates to at most [maxBytes] UTF-8 bytes on codepoint boundaries. */
fun smsTruncate(text: String, maxBytes: Int): String {
    if (text.toByteArray(Charsets.UTF_8).size <= maxBytes) return text
    var end = 0
    var index = 0
    while (index < text.length) {
        val next = index + Character.charCount(text.codePointAt(index))
        val size = text.substring(0, next).toByteArray(Charsets.UTF_8).size
        if (size > maxBytes) break
        end = next
        index = next
    }
    return text.substring(0, end)
}

/** Byte-wise lexical comparison over the full messageId string (never the parsed numeric id). */
fun smsCompareMessageIds(a: String, b: String): Int {
    val left = a.toByteArray(Charsets.UTF_8)
    val right = b.toByteArray(Charsets.UTF_8)
    val shared = minOf(left.size, right.size)
    for (i in 0 until shared) {
        val c = (left[i].toInt() and 255).compareTo(right[i].toInt() and 255)
        if (c != 0) return c
    }
    return left.size.compareTo(right.size)
}

/** Provider failures become null so one source can fail without failing the page; cancellation propagates. */
private fun smsQueryOrEmpty(block: () -> List<SmsRawMessage>): List<SmsRawMessage>? =
    try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

private const val THREAD_LIMIT = 50
private const val TIE_ALLOWANCE = 32
private const val GROUP_CAP = 2048
/** Raw batches examined while looking for a page's worth of displayable rows. */
private const val SCAN_ROUNDS = 8

class AndroidSmsStore(
    private val provider: SmsProvider,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val hasReadPermission: () -> Boolean = { false },
) : SmsStore {
    constructor(context: Context) : this(
        provider = AndroidSmsProvider(context),
        dispatcher = Dispatchers.IO,
        hasReadPermission = { ContextCompat.checkSelfPermission(context, Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED },
    )
    override suspend fun threads(limit: Int, beforeMillis: Long, beforeThreadId: String): SmsThreadPage? {
        if (!hasReadPermission()) return null
        return withContext(dispatcher) { loadThreads(limit.coerceIn(1, THREAD_LIMIT), beforeMillis, beforeThreadId) }
    }

    override suspend fun history(threadId: String, beforeMillis: Long, beforeMessageId: String, limit: Int): SmsHistoryPage? {
        if (!hasReadPermission()) return null
        return withContext(dispatcher) { loadHistory(threadId, beforeMillis, beforeMessageId, limit.coerceIn(1, 50)) }
    }

    private fun loadThreads(limit: Int, beforeMillis: Long, beforeThreadId: String): SmsThreadPage {
        val firstPage = beforeMillis == 0L && beforeThreadId.isEmpty()
        val window = limit + TIE_ALLOWANCE
        var batch = try { provider.conversations(window, beforeMillis, beforeThreadId) }
            catch (e: CancellationException) { throw e }
            catch (_: Exception) {
                if (!firstPage) throw SmsStoreException()
                null
            }
        // The direct scan is a degraded first-page fallback only; it has no cursor of its own.
        val direct = firstPage && batch?.rows.isNullOrEmpty()
        if (direct) {
            batch = try { provider.directThreads(limit) }
                catch (e: CancellationException) { throw e }
                catch (_: Exception) { if (batch == null) throw SmsStoreException() else batch }
        }
        val unreadCounts = try { provider.unreadCounts() }
            catch (e: CancellationException) { throw e }
            catch (_: Exception) { null }
        val threads = mutableListOf<SmsThreadRecord>()
        var skipped = 0
        var examined: Pair<Long, String>? = null
        var exhausted = false
        var partial = false
        var rounds = 0
        while (batch != null && threads.size <= limit && rounds++ < SCAN_ROUNDS) {
            partial = partial || batch.partial
            val raw = batch.rows
            val oldest = raw.minOfOrNull { smsClampDate(it.dateMillis ?: 0) }
            val rows = raw.associateByTo(LinkedHashMap()) { it.threadId }
            exhausted = direct || raw.size < window || oldest == null || oldest == 0L
            // SQL orders numeric ids; complete the boundary group before applying the lexical cursor.
            if (!direct && raw.size >= window && oldest != null) {
                val group = provider.conversationDateGroup(oldest)
                if (group.size > GROUP_CAP) throw SmsPagingUnsupported()
                group.forEach { rows[it.threadId] = it }
            }
            val eligible = rows.values.filter { row ->
                val date = smsClampDate(row.dateMillis ?: 0)
                firstPage || date < beforeMillis ||
                    date == beforeMillis && smsCompareMessageIds(row.threadId.toString(), beforeThreadId) < 0
            }.sortedWith { a, b ->
                val date = smsClampDate(b.dateMillis ?: 0).compareTo(smsClampDate(a.dateMillis ?: 0))
                if (date != 0) date else smsCompareMessageIds(b.threadId.toString(), a.threadId.toString())
            }
            for (row in eligible) {
                examined = smsClampDate(row.dateMillis ?: 0) to row.threadId.toString()
                val record = threadRecord(row, unreadCounts)
                if (record == null) skipped++ else threads += record
                if (threads.size > limit) break
            }
            if (threads.size > limit || exhausted || partial || rounds >= SCAN_ROUNDS) break
            // A skipped batch still advances the raw scan; the next request can continue after its last row.
            batch = provider.conversations(window, oldest!! - 1, "0")
        }
        val ordered = threads.sortedWith { a, b ->
            val date = b.dateMillis.compareTo(a.dateMillis)
            if (date != 0) date else smsCompareMessageIds(b.threadId, a.threadId)
        }.take(limit)
        val more = threads.size > limit || !exhausted
        val cursor = ordered.lastOrNull()?.let { it.dateMillis to it.threadId } ?: examined
        val next = if (more) cursor ?: throw SmsPagingUnsupported() else 0L to ""
        return SmsThreadPage(ordered, skipped, partial, next.first, next.second, more)
    }

    private fun threadRecord(row: SmsConversationRow, unreadCounts: Map<Long, Long>?): SmsThreadRecord? {
        var address = row.address
        var date = row.dateMillis
        var snippet = row.snippet
        var unread = if (unreadCounts != null) unreadCounts[row.threadId] ?: 0L else row.unread
        if (address.isNullOrEmpty()) {
            address = try {
                row.recipientIds.firstOrNull()?.let { provider.canonicalAddresses(listOf(it))[it] }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }
        }
        if (address.isNullOrEmpty() || date == null || unread == null) {
            val fallback = try {
                provider.newestThreadRow(row.threadId)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }
            if (address.isNullOrEmpty()) address = fallback?.address
            if (date == null) date = fallback?.dateMillis
            if (snippet == null) snippet = fallback?.snippet
            if (unread == null) unread = fallback?.unread?.let { if (it) 1L else 0L }
        }
        val cleanAddress = address?.takeIf { it.isNotEmpty() }?.let { smsSanitizeText(it)?.let { text -> smsTruncate(text, 64) } }
        val cleanDate = date
        if (cleanAddress.isNullOrEmpty() || smsNormalizedAddress(cleanAddress).isEmpty() || cleanDate == null) {
            return null
        }
        val cleanSnippet = snippet?.let { smsSanitizeText(it) }?.let { smsTruncate(it, 160) } ?: ""
        return SmsThreadRecord(row.threadId.toString(), cleanAddress, cleanSnippet, smsClampDate(cleanDate), (unread ?: 0L).coerceIn(0, SmsWireMessage.MAX_DATE))
    }

    override suspend fun search(query: String, beforeMillis: Long, beforeMessageId: String, limit: Int): SmsHistoryPage? {
        if (!hasReadPermission()) return null
        return withContext(dispatcher) { loadSearch(query, beforeMillis, beforeMessageId, limit.coerceIn(1, 50)) }
    }

    /** The same bounded scan as history, over SMS bodies and text/plain MMS parts matching the escaped substring. */
    private fun loadSearch(query: String, beforeMillis: Long, beforeMessageId: String, limit: Int): SmsHistoryPage {
        val pattern = "%" + query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
        return loadPage(beforeMillis, beforeMessageId, limit, listOf(
            Source("sms", beforeMillis, beforeMessageId, limit, { bound, fetch -> provider.smsSearch(pattern, bound, fetch) }, { provider.smsSearchGroup(pattern, it) }),
            Source("mms", beforeMillis, beforeMessageId, limit, { bound, fetch -> provider.mmsSearch(pattern, bound, fetch) }, { provider.mmsSearchGroup(pattern, it) }),
        ))
    }

    private fun loadHistory(threadId: String, beforeMillis: Long, beforeMessageId: String, limit: Int): SmsHistoryPage {
        // `addr:` threads have no provider row; the Mac re-requests with the provider threadId once it appears.
        val providerId = threadId.toLongOrNull() ?: return SmsHistoryPage(emptyList(), 0, "", false, 0)
        return loadPage(beforeMillis, beforeMessageId, limit, listOf(
            Source("sms", beforeMillis, beforeMessageId, limit, { bound, fetch -> provider.smsHistory(providerId, bound, fetch) }, { provider.smsDateGroup(providerId, it) }),
            Source("mms", beforeMillis, beforeMessageId, limit, { bound, fetch -> provider.mmsHistory(providerId, bound, fetch) }, { provider.mmsDateGroup(providerId, it) }),
        ))
    }

    /** One scan position over a provider source: reads newest-first, then widens each fetched timestamp into its tie group. */
    private class Source(
        val prefix: String,
        val beforeMillis: Long,
        val beforeMessageId: String,
        val limit: Int,
        val history: (Long?, Int) -> List<SmsRawMessage>,
        val group: (Long) -> List<SmsRawMessage>,
    ) {
        val rows = ArrayDeque<SmsRawMessage>()
        var upper = beforeMillis.takeIf { it > 0 || beforeMessageId.isNotEmpty() }
        var exhausted = false
        var failed = false
        var rounds = 0

        fun fill() {
            while (rows.isEmpty() && !exhausted && rounds < SCAN_ROUNDS) {
                rounds++
                val fetch = limit + TIE_ALLOWANCE
                val initial = smsQueryOrEmpty { history(upper, fetch) }
                if (initial == null) { failed = true; exhausted = true; return }
                val result = initial.associateByTo(LinkedHashMap()) { it.id }
                val dates = mutableSetOf<Long>()
                if (initial.size == fetch) initial.minOfOrNull { it.dateMillis }?.let { dates.add(smsClampDate(it)) }
                upper?.let { dates.add(smsClampDate(it)) }
                for (date in dates) {
                    val tie = smsQueryOrEmpty { group(date) }
                    if (tie == null) { failed = true; exhausted = true; return }
                    if (tie.size > GROUP_CAP) throw SmsPagingUnsupported()
                    tie.forEach { result[it.id] = it }
                }
                exhausted = initial.size < fetch
                val ordered = result.values.filter { row ->
                    val date = smsClampDate(row.dateMillis)
                    beforeMillis == 0L && beforeMessageId.isEmpty() || date < beforeMillis ||
                        date == beforeMillis && smsCompareMessageIds("$prefix:${row.id}", beforeMessageId) < 0
                }.sortedWith { a, b ->
                    val date = smsClampDate(b.dateMillis).compareTo(smsClampDate(a.dateMillis))
                    if (date != 0) date else smsCompareMessageIds("$prefix:${b.id}", "$prefix:${a.id}")
                }
                rows.addAll(ordered)
                val oldest = initial.minOfOrNull { it.dateMillis }
                if (oldest == null || oldest <= 0) exhausted = true else upper = oldest - 1
            }
        }
    }

    private fun loadPage(beforeMillis: Long, beforeMessageId: String, limit: Int, sources: List<Source>): SmsHistoryPage {
        var skipped = 0
        val comparator = Comparator<SmsHistoryMessage> { a, b ->
            val d = b.dateMillis.compareTo(a.dateMillis)
            if (d != 0) d else smsCompareMessageIds(b.messageId, a.messageId)
        }
        fun sanitize(row: SmsRawMessage, prefix: String): SmsHistoryMessage? {
            if (!row.supported) {
                skipped++
                return null
            }
            val address = row.address?.takeIf { it.isNotEmpty() }?.let { smsSanitizeText(it) }?.let { smsTruncate(it, 64) }
            val text = row.body?.let { smsSanitizeText(it) }?.takeIf { it.isNotEmpty() }
            val size = text?.toByteArray(Charsets.UTF_8)?.size ?: 0
            if (row.id < 0 || address.isNullOrEmpty() || smsNormalizedAddress(address).isEmpty() || text == null || size > 24576) {
                skipped++
                return null
            }
            return SmsHistoryMessage(
                messageId = "$prefix:${row.id}",
                address = address,
                dateMillis = smsClampDate(row.dateMillis),
                direction = row.direction.coerceIn(0, 1),
                unread = row.unread,
                text = text,
                threadId = row.threadId.toString(),
                subscriptionId = row.subscriptionId.coerceIn(0, Int.MAX_VALUE),
            )
        }

        val accepted = mutableListOf<SmsHistoryMessage>()
        var examined: Pair<Long, String>? = null
        while (accepted.size <= limit) {
            sources.forEach { it.fill() }
            if (sources.any { it.rows.isEmpty() && !it.exhausted }) break
            val source = sources.filter { it.rows.isNotEmpty() }.maxWithOrNull { a, b ->
                val left = a.rows.first(); val right = b.rows.first()
                val date = smsClampDate(left.dateMillis).compareTo(smsClampDate(right.dateMillis))
                if (date != 0) date else smsCompareMessageIds("${a.prefix}:${left.id}", "${b.prefix}:${right.id}")
            } ?: break
            val row = source.rows.removeFirst()
            examined = smsClampDate(row.dateMillis) to "${source.prefix}:${row.id}"
            sanitize(row, source.prefix)?.let { accepted.add(it) }
        }
        if (sources.all { it.failed }) throw SmsStoreException()
        val partial = sources.any { it.failed }
        if (partial) skipped++
        val page = accepted.sortedWith(comparator).take(limit)
        val more = accepted.size > limit || sources.any { it.rows.isNotEmpty() || !it.exhausted }
        val cursor = page.lastOrNull()?.let { it.dateMillis to it.messageId } ?: examined
        if (!more) return SmsHistoryPage(page, 0, "", false, skipped, partial)
        if (cursor == null) throw SmsPagingUnsupported()
        return SmsHistoryPage(page, cursor.first, cursor.second, true, skipped, partial)

    }
}

internal class AndroidSmsProvider(context: Context) : SmsProvider {
    private fun dateGroupOperator(millis: Long) = when (millis) { 0L -> "<="; SmsWireMessage.MAX_DATE -> ">="; else -> "=" }
    private val resolver: ContentResolver = context.contentResolver
    private val smsUri: Uri = Telephony.Sms.CONTENT_URI
    private val mmsUri: Uri = Uri.parse("content://mms")
    /** `sub_id` is a hidden but universal SMS column; a provider that rejects it degrades to unknown attribution. */
    private var subIdProjection = true

    private fun query(uri: Uri, columns: Array<String>, selection: String?, args: Array<String>?, sort: String?): android.database.Cursor? =
        try {
            resolver.query(uri, columns, selection, args, sort)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }

    override fun conversations(limit: Int, beforeMillis: Long, beforeThreadId: String): SmsConversationPage {
        // The cursor is a contract threadId; only a date pushdown is safe for string tie ordering, so the
        // store applies the exact (date, threadId) filter in memory.
        val bounded = beforeMillis > 0 || beforeThreadId.isNotEmpty()
        return conversationRows(if (bounded) "date <= ?" else null,
            if (bounded) arrayOf(beforeMillis.toString()) else null, limit)
    }

    override fun conversationDateGroup(millis: Long): List<SmsConversationRow> =
        conversationRows("date " + dateGroupOperator(millis) + " ?", arrayOf(millis.toString()), GROUP_CAP + 1).rows

    private fun conversationRows(selection: String?, args: Array<String>?, limit: Int): SmsConversationPage {
        val cursor = query(Uri.parse("content://mms-sms/conversations?simple=true"), arrayOf("_id", "date", "snippet", "message_count", "recipient_ids", "read"), selection, args, "date DESC, _id DESC LIMIT $limit") ?: throw SmsStoreException()
        return cursor.use {
            val id = it.getColumnIndex("_id")
            val date = it.getColumnIndex("date")
            val snippet = it.getColumnIndex("snippet")
            val count = it.getColumnIndex("message_count")
            val recipients = it.getColumnIndex("recipient_ids")
            val read = it.getColumnIndex("read")
            if (id < 0 || date < 0 || recipients < 0) throw SmsStoreException()
            SmsConversationPage(buildList {
                while (it.moveToNext()) {
                    add(
                        SmsConversationRow(
                            threadId = it.getLong(id),
                            dateMillis = if (it.isNull(date)) null else it.getLong(date),
                            snippet = if (snippet < 0 || it.isNull(snippet)) null else it.getString(snippet),
                            recipientIds = if (it.isNull(recipients)) emptyList() else it.getString(recipients).split(' ', ',').mapNotNull { part -> part.trim().toLongOrNull() },
                            messageCount = if (count < 0 || it.isNull(count)) null else it.getLong(count),
                            read = if (read < 0 || it.isNull(read)) null else it.getLong(read),
                        )
                    )
                }
            })
        }
    }

    override fun unreadCounts(): Map<Long, Long> {
        val cursor = query(smsUri, arrayOf("thread_id"), "type = 1 AND read = 0", null, null) ?: throw SmsStoreException()
        return cursor.use {
            val thread = it.getColumnIndex("thread_id")
            if (thread < 0) throw SmsStoreException()
            buildMap {
                while (it.moveToNext()) {
                    if (it.isNull(thread)) continue
                    val id = it.getLong(thread)
                    put(id, (get(id) ?: 0L) + 1L)
                }
            }
        }
    }

    override fun canonicalAddresses(ids: List<Long>): Map<Long, String> {
        if (ids.isEmpty()) return emptyMap()
        val placeholders = ids.joinToString(",") { "?" }
        val cursor = query(Uri.parse("content://mms-sms/canonical-addresses"), arrayOf("_id", "address"), "_id IN ($placeholders)", ids.map { it.toString() }.toTypedArray(), null) ?: throw SmsStoreException()
        return cursor.use {
            val id = it.getColumnIndex("_id")
            val address = it.getColumnIndex("address")
            if (id < 0 || address < 0) throw SmsStoreException()
            buildMap {
                while (it.moveToNext()) {
                    val value = if (it.isNull(address)) null else it.getString(address)
                    if (!value.isNullOrEmpty()) put(it.getLong(id), value)
                }
            }
        }
    }

    override fun newestThreadRow(threadId: Long): SmsThreadFallback? {
        val sms = query(smsUri, arrayOf("address", "date", "body", "read"), "thread_id = ?", arrayOf(threadId.toString()), "date DESC LIMIT 1")
        sms?.use {
            val address = it.getColumnIndex("address")
            val date = it.getColumnIndex("date")
            val body = it.getColumnIndex("body")
            val read = it.getColumnIndex("read")
            if (it.moveToFirst() && address >= 0 && !it.isNull(address)) {
                val value = it.getString(address)
                if (!value.isNullOrEmpty()) {
                    return SmsThreadFallback(value, if (date < 0 || it.isNull(date)) 0 else it.getLong(date), if (body < 0 || it.isNull(body)) null else it.getString(body), if (read < 0 || it.isNull(read)) null else it.getLong(read) == 0L)
                }
            }
        }
        val mms = query(mmsUri, arrayOf("_id", "date", "msg_box", "read"), "thread_id = ?", arrayOf(threadId.toString()), "date DESC LIMIT 1")
        mms?.use {
            val id = it.getColumnIndex("_id")
            val date = it.getColumnIndex("date")
            val box = it.getColumnIndex("msg_box")
            val read = it.getColumnIndex("read")
            if (it.moveToFirst() && id >= 0) {
                val mmsId = it.getLong(id)
                val address = mmsAddress(mmsId, if (box < 0 || it.isNull(box)) 1L else it.getLong(box))
                if (!address.isNullOrEmpty()) {
                    val seconds = if (date < 0 || it.isNull(date)) 0 else it.getLong(date)
                    return SmsThreadFallback(address, smsMmsDate(seconds), null, if (read < 0 || it.isNull(read)) null else it.getLong(read) == 0L)
                }
            }
        }
        return null
    }

    override fun directThreads(limit: Int): SmsConversationPage {
        val byThread = LinkedHashMap<Long, SmsConversationRow>()
        val sms = query(smsUri, arrayOf("thread_id", "address", "date", "body", "read", "type"), "type != 3", null, "date DESC LIMIT " + (limit * 4))
        sms?.use {
            val thread = it.getColumnIndex("thread_id")
            val address = it.getColumnIndex("address")
            val date = it.getColumnIndex("date")
            val body = it.getColumnIndex("body")
            val read = it.getColumnIndex("read")
            if (thread < 0 || date < 0) throw SmsStoreException()
            while (it.moveToNext()) {
                if (it.isNull(thread) || it.isNull(date)) continue
                val id = it.getLong(thread)
                if (byThread.containsKey(id)) continue
                byThread[id] = SmsConversationRow(
                    threadId = id,
                    dateMillis = it.getLong(date),
                    snippet = if (body < 0 || it.isNull(body)) null else it.getString(body),
                    recipientIds = emptyList(),
                    messageCount = null,
                    read = if (read < 0 || it.isNull(read)) null else it.getLong(read),
                    address = if (address < 0 || it.isNull(address)) null else it.getString(address),
                    unread = if (read < 0 || it.isNull(read)) null else if (it.getLong(read) == 0L) 1L else 0L,
                )
            }
        }
        val mms = query(mmsUri, arrayOf("_id", "thread_id", "date", "msg_box", "read"), "msg_box IN (1,2)", null, "date DESC LIMIT " + (limit * 2))
        if (sms == null && mms == null) throw SmsStoreException()
        mms?.use {
            val id = it.getColumnIndex("_id")
            val thread = it.getColumnIndex("thread_id")
            val date = it.getColumnIndex("date")
            val box = it.getColumnIndex("msg_box")
            val read = it.getColumnIndex("read")
            if (id < 0 || thread < 0 || date < 0) return@use
            while (it.moveToNext()) {
                if (it.isNull(thread) || it.isNull(date)) continue
                val threadId = it.getLong(thread)
                val seconds = it.getLong(date)
                val existing = byThread[threadId]
                if (existing != null && (existing.dateMillis ?: 0) >= smsMmsDate(seconds)) continue
                val address = mmsAddress(it.getLong(id), if (box < 0 || it.isNull(box)) 1L else it.getLong(box))
                byThread[threadId] = SmsConversationRow(
                    threadId = threadId,
                    dateMillis = smsMmsDate(seconds),
                    snippet = null,
                    recipientIds = emptyList(),
                    messageCount = null,
                    read = if (read < 0 || it.isNull(read)) null else it.getLong(read),
                    address = address,
                    unread = if (read < 0 || it.isNull(read)) null else if (it.getLong(read) == 0L) 1L else 0L,
                )
            }
        }
        return SmsConversationPage(byThread.values.sortedWith(compareByDescending { it.dateMillis ?: 0 }).take(limit), sms == null || mms == null)
    }

    override fun smsHistory(threadId: Long, upperMillis: Long?, limit: Int): List<SmsRawMessage> = smsQuery("thread_id = ? AND type != 3" + if (upperMillis != null) " AND date <= ?" else "", (listOf(threadId.toString()) + listOfNotNull(upperMillis?.toString())).toTypedArray(), limit)

    override fun smsDateGroup(threadId: Long, millis: Long): List<SmsRawMessage> = smsQuery("thread_id = ? AND type != 3 AND date " + dateGroupOperator(millis) + " ?", arrayOf(threadId.toString(), millis.toString()), GROUP_CAP + 1)

    override fun smsSearch(pattern: String, upperMillis: Long?, limit: Int): List<SmsRawMessage> =
        smsQuery("type != 3 AND body LIKE ? ESCAPE '\\'" + if (upperMillis != null) " AND date <= ?" else "", (listOf(pattern) + listOfNotNull(upperMillis?.toString())).toTypedArray(), limit)

    override fun smsSearchGroup(pattern: String, millis: Long): List<SmsRawMessage> =
        smsQuery("type != 3 AND body LIKE ? ESCAPE '\\' AND date " + dateGroupOperator(millis) + " ?", arrayOf(pattern, millis.toString()), GROUP_CAP + 1)

    private fun smsQuery(selection: String, args: Array<String>, limit: Int): List<SmsRawMessage> {
        val base = arrayOf("_id", "date", "address", "body", "type", "read", "thread_id")
        var cursor = query(smsUri, if (subIdProjection) base + "sub_id" else base, selection, args, "date DESC LIMIT $limit")
        if (cursor == null && subIdProjection) {
            subIdProjection = false
            cursor = query(smsUri, base, selection, args, "date DESC LIMIT $limit")
        }
        cursor ?: throw SmsStoreException()
        return cursor.use {
            val id = it.getColumnIndex("_id")
            val date = it.getColumnIndex("date")
            val address = it.getColumnIndex("address")
            val body = it.getColumnIndex("body")
            val type = it.getColumnIndex("type")
            val read = it.getColumnIndex("read")
            val thread = it.getColumnIndex("thread_id")
            val subscription = it.getColumnIndex("sub_id")
            if (id < 0 || date < 0) throw SmsStoreException()
            buildList {
                while (it.moveToNext()) {
                    val messageType = if (type < 0 || it.isNull(type)) 1L else it.getLong(type)
                    add(
                        SmsRawMessage(
                            id = it.getLong(id),
                            dateMillis = if (it.isNull(date)) 0 else it.getLong(date),
                            address = if (address < 0 || it.isNull(address)) null else it.getString(address),
                            body = if (body < 0 || it.isNull(body)) null else it.getString(body),
                            direction = if (messageType == 1L) 0 else 1,
                            unread = read >= 0 && !it.isNull(read) && it.getLong(read) == 0L,
                            supported = messageType in 1L..6L,
                            threadId = if (thread < 0 || it.isNull(thread)) 0 else it.getLong(thread),
                            subscriptionId = if (subscription < 0 || it.isNull(subscription)) 0 else it.getInt(subscription).coerceIn(0, Int.MAX_VALUE),
                        )
                    )
                }
            }
        }
    }

    override fun mmsHistory(threadId: Long, upperMillis: Long?, limit: Int): List<SmsRawMessage> =
        mmsQuery("thread_id = ? AND msg_box IN (1,2)" + if (upperMillis != null) " AND date <= ?" else "", (listOf(threadId.toString()) + listOfNotNull(upperMillis?.div(1000)?.toString())).toTypedArray(), limit)

    override fun mmsDateGroup(threadId: Long, millis: Long): List<SmsRawMessage> =
        mmsQuery("thread_id = ? AND msg_box IN (1,2) AND date " + dateGroupOperator(millis) + " ?", arrayOf(threadId.toString(), (millis / 1000).toString()), GROUP_CAP + 1)

    override fun mmsSearch(pattern: String, upperMillis: Long?, limit: Int): List<SmsRawMessage> =
        mmsSearchRows(pattern, if (upperMillis != null) "date <= ?" else null, listOfNotNull(upperMillis?.div(1000)?.toString()), limit)

    override fun mmsSearchGroup(pattern: String, millis: Long): List<SmsRawMessage> =
        mmsSearchRows(pattern, "date " + dateGroupOperator(millis) + " ?", listOf((millis / 1000).toString()), GROUP_CAP + 1)

    /**
     * Matching ids come from text/plain part rows (which carry no date); the page window is then resolved
     * from the mms table newest-first so a page boundary never depends on part or insertion order.
     */
    private fun mmsSearchRows(pattern: String, dateClause: String?, args: List<String>, limit: Int): List<SmsRawMessage> {
        val ids = mmsSearchIds(pattern, dateClause, args)
        if (ids.isEmpty()) return emptyList()
        val rows = mutableListOf<SmsRawMessage>()
        for (chunk in ids.chunked(500)) {
            val selection = "_id IN (${chunk.joinToString(",")}) AND msg_box IN (1,2)" + if (dateClause != null) " AND $dateClause" else ""
            val cursor = query(mmsUri, arrayOf("_id", "date", "msg_box", "read", "thread_id"), selection, args.toTypedArray(), "date DESC LIMIT $limit") ?: throw SmsStoreException()
            cursor.use {
                val id = it.getColumnIndex("_id")
                val date = it.getColumnIndex("date")
                val box = it.getColumnIndex("msg_box")
                val read = it.getColumnIndex("read")
                val thread = it.getColumnIndex("thread_id")
                if (id < 0 || date < 0 || box < 0) throw SmsStoreException()
                while (it.moveToNext()) {
                    rows.add(mmsRow(it.getLong(id), if (it.isNull(date)) 0 else it.getLong(date), if (it.isNull(box)) 1L else it.getLong(box), if (read < 0 || it.isNull(read)) null else it.getLong(read), if (thread < 0 || it.isNull(thread)) 0 else it.getLong(thread)))
                }
            }
        }
        return rows.sortedWith(compareByDescending<SmsRawMessage> { it.dateMillis }.thenByDescending { it.id }).take(limit)
    }

    /** Scans matching text/plain parts once; a match set beyond the scan cap is reported as unresolvable paging. */
    private fun mmsSearchIds(pattern: String, dateClause: String?, args: List<String>): LinkedHashSet<Long> {
        val filter = if (dateClause == null) "" else " AND mid IN (SELECT _id FROM mms WHERE msg_box IN (1,2) AND $dateClause)"
        val cursor = query(Uri.parse("content://mms/part"), arrayOf("mid"), "ct = 'text/plain' AND text LIKE ? ESCAPE '\\'" + filter, (listOf(pattern) + args).toTypedArray(), "mid DESC")
            ?: throw SmsStoreException()
        return cursor.use {
            val mid = it.getColumnIndex("mid")
            if (mid < 0) throw SmsStoreException()
            val ids = LinkedHashSet<Long>()
            while (it.moveToNext()) {
                if (it.isNull(mid)) continue
                ids.add(it.getLong(mid))
                if (ids.size > GROUP_CAP) throw SmsPagingUnsupported()
            }
            ids
        }
    }

    private fun mmsQuery(selection: String, args: Array<String>, limit: Int): List<SmsRawMessage> {
        val cursor = query(mmsUri, arrayOf("_id", "date", "msg_box", "read", "thread_id"), selection, args, "date DESC LIMIT $limit") ?: throw SmsStoreException()
        return cursor.use {
            val id = it.getColumnIndex("_id")
            val date = it.getColumnIndex("date")
            val box = it.getColumnIndex("msg_box")
            val read = it.getColumnIndex("read")
            val thread = it.getColumnIndex("thread_id")
            if (id < 0 || date < 0 || box < 0) throw SmsStoreException()
            buildList {
                while (it.moveToNext()) {
                    add(mmsRow(it.getLong(id), if (it.isNull(date)) 0 else it.getLong(date), if (it.isNull(box)) 1L else it.getLong(box), if (read < 0 || it.isNull(read)) null else it.getLong(read), if (thread < 0 || it.isNull(thread)) 0 else it.getLong(thread)))
                }
            }
        }
    }

    private fun mmsRow(mmsId: Long, seconds: Long, messageBox: Long, read: Long?, threadId: Long): SmsRawMessage {
        val address = mmsAddress(mmsId, messageBox)
        val body = mmsBody(mmsId)
        return SmsRawMessage(
            id = mmsId,
            dateMillis = smsMmsDate(seconds),
            address = address,
            body = body,
            direction = if (messageBox == 1L) 0 else 1,
            unread = read != null && read == 0L,
            supported = address != null && body != null,
            threadId = threadId,
        )
    }

    /** Returns the single from/to address; group MMS (more than one recipient) is unsupported. */
    private fun mmsAddress(mmsId: Long, messageBox: Long): String? {
        val type = if (messageBox == 1L) 137 else 151
        val cursor = query(Uri.parse("content://mms/$mmsId/addr"), arrayOf("address", "type"), null, null, null) ?: return null
        return cursor.use {
            val address = it.getColumnIndex("address")
            if (address < 0) return null
            val kind = it.getColumnIndex("type")
            if (kind < 0) return null
            val values = mutableListOf<String>()
            val recipients = mutableSetOf<String>()
            while (it.moveToNext()) {
                if (it.isNull(address)) continue
                val value = it.getString(address)
                val rowType = it.getInt(kind)
                if (rowType == type) values.add(value)
                if (rowType == 151 || rowType == 130) recipients.add(smsNormalizedAddress(value))
            }
            if (recipients.size > 1 || values.size != 1 || values[0].isEmpty()) null else values[0]
        }
    }

    /** Concatenates text/plain parts in part order; attachment-only messages are unsupported. */
    private fun mmsBody(mmsId: Long): String? {
        val cursor = query(Uri.parse("content://mms/part"), arrayOf("_id", "ct", "charset", "text"), "mid = ?", arrayOf(mmsId.toString()), "_id ASC") ?: return null
        return cursor.use {
            val id = it.getColumnIndex("_id")
            val ct = it.getColumnIndex("ct")
            val charset = it.getColumnIndex("charset")
            val text = it.getColumnIndex("text")
            if (id < 0 || ct < 0) return null
            val pieces = mutableListOf<String>()
            while (it.moveToNext()) {
                val contentType = if (it.isNull(ct)) null else it.getString(ct)
                if (contentType == null || !contentType.startsWith("text/plain")) continue
                val raw = if (text >= 0 && !it.isNull(text)) it.getString(text) else null
                val decoded = raw ?: readPart(it.getLong(id), charsetOf(if (charset < 0 || it.isNull(charset)) null else it.getString(charset))) ?: return@use null
                pieces += decoded
            }
            if (pieces.isEmpty()) null else pieces.joinToString("\n")
        }
    }

    private fun charsetOf(value: String?): Charset = when (value?.trim()?.lowercase()) {
        null, "", "106", "utf-8", "utf8" -> StandardCharsets.UTF_8
        "3", "us-ascii", "ascii" -> StandardCharsets.US_ASCII
        "4", "iso-8859-1", "latin1" -> StandardCharsets.ISO_8859_1
        else -> try { Charset.forName(value) } catch (_: Exception) { StandardCharsets.UTF_8 }
    }

    private fun readPart(partId: Long, charset: Charset): String? {
        val stream = try {
            resolver.openInputStream(Uri.parse("content://mms/part/$partId"))
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        } ?: return null
        return stream.use {
            val buffer = java.io.ByteArrayOutputStream()
            val scratch = ByteArray(4096)
            while (buffer.size() <= SmsWireMessage.MAX_BODY_BYTES) {
                val read = it.read(scratch)
                if (read < 0) break
                buffer.write(scratch, 0, read)
            }
            if (buffer.size() > SmsWireMessage.MAX_BODY_BYTES) return null
            try {
                charset.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(buffer.toByteArray())).toString()
            } catch (_: java.nio.charset.CharacterCodingException) {
                if (charset == StandardCharsets.UTF_8) null
                else try { StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(buffer.toByteArray())).toString() } catch (_: java.nio.charset.CharacterCodingException) { null }
            }
        }
    }
}
