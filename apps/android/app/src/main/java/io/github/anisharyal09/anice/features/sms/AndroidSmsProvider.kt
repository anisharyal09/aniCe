// SPDX-License-Identifier: GPL-3.0-or-later
// Reads Android SMS/MMS provider rows behind the feature's bounded store contract.
package io.github.anisharyal09.anice.features.sms

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.Telephony
import kotlinx.coroutines.CancellationException
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

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
