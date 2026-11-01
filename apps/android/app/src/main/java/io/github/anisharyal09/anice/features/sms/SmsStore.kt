// SPDX-License-Identifier: GPL-3.0-or-later
// Reads provider threads and history with timestamp-only SQL and in-memory lexical messageId ordering.
package io.github.anisharyal09.anice.features.sms

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
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

internal fun smsMmsDate(seconds: Long): Long = when {
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
internal const val GROUP_CAP = 2048
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
