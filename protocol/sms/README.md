<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Defines SMS thread, history, live-event and reply delivery inside authenticated application DATA. -->
# SMS Relay v1

Each DATA plaintext is deterministic RFC 8949 CBOR `["aniCe sms", 1, kind, fields]`, at most 4,000 bytes. Reject non-minimal encoding, indefinite lengths, trailing bytes, invalid UTF-8, extra fields, wrong types, unknown versions/kinds and out-of-range integers. UUIDs are canonical lowercase text; `requestId`/`streamId` are 16 random bytes (RFC 9562 v4). Android produces thread and history data; either side may send a reply. Direction 0/1 in `messageBegin` is from the provider's perspective.

| Kind | Fields |
| --- | --- |
| 1 capability | `[maxBodyBytes: 24576, maxFragments: 8, maxThreadsPerPage: 50, maxMessagesPerPage: 50]` |
| 2 threadRequest | `[requestId: uuid]` |
| 3 threadRecord | `[requestId: uuid, threadId: tstr .size (1..80), address: tstr .size (1..64), snippet: tstr .size (0..160), dateMillis, unreadCount]` |
| 4 threadDone | `[requestId: uuid, result: 0..6]` |
| 5 historyRequest | `[requestId: uuid, threadId, beforeMillis, beforeMessageId: messageId / "", limit: 1..50]` |
| 6 messageBegin | `[streamId: uuid, requestId: uuid / "", messageId, threadId, address, dateMillis, direction: 0..1, unread: bool, totalBytes: 1..24576, fragmentCount: 1..8, sha256: bstr .size 32]` |
| 7 messageFragment | `[streamId: uuid, index: 0..7, bytes: bstr .size (1..3072)]` |
| 8 messageCommit | `[streamId: uuid]` |
| 9 messageResult | `[streamId: uuid, result: 0..6]` |
| 10 historyDone | `[requestId: uuid, result: 0..6, nextBeforeMillis, nextBeforeMessageId: messageId / ""]` |
| 11 sendBegin | `[requestId: uuid, threadId, address, totalBytes: 1..24576, fragmentCount: 1..8, sha256: bstr .size 32]` |
| 12 sendFragment | `[requestId: uuid, index: 0..7, bytes: bstr .size (1..3072)]` |
| 13 sendCommit | `[requestId: uuid]` |
| 14 sendResult | `[requestId: uuid, result: 0..6, messageId: messageId / "", dateMillis]` |

`dateMillis`, `unreadCount` and both cursors are epoch milliseconds or counts in 0..2^53−1. Message bodies are strict UTF-8 of 1..24,576 bytes with NUL replaced by U+FFFD before encoding; the digest is SHA-256 over the assembled body. `fragmentCount = ceil(totalBytes / 3072)` and all fragments except the last are exactly 3,072 bytes. `unread` is a CBOR boolean.

Capability fields 2 and 3 (`maxThreadsPerPage` and `maxMessagesPerPage`) are the advertiser's limits for the link they were sent on, each in 1..50 and never above the contract maximums; a peer must serve the thread list and requested history pages within the limits its peer advertised, so a slower link can announce smaller lists and pages than a local-network one. Both fields are re-sent on every new channel generation, and a request is never rejected for being smaller than the advertised limit.

`threadId` is the provider `thread_id` in decimal or `"addr:<normalized address>"` when no provider row exists; a normalized address is digits with one optional leading `+`, or the trimmed uppercase text for alphanumeric sender IDs (`addr:ACMEBANK`, `addr:AUTH XYZ`), so bank and service senders keep their own conversation. The Mac groups conversations by normalized address, not threadId, so a live-only thread and its later provider thread remain one card. An `addr:` history request selects no provider row, so v1 answers it with an empty terminal page (`nextBeforeMillis = 0` with `nextBeforeMessageId = ""`); the Mac re-requests with the provider threadId once the thread list reports one. `address` is transmitted as stored (raw), truncated on codepoint boundaries; `snippet` follows the same rule.

`messageId` is `"sms:<provider id>"` or `"mms:<provider id>"` for provider rows and `"live:<lowercase hex SHA-256(address || dateMillis || body)[0..31]>"` for live PDUs; the live form is deterministic so duplicate `SMS_RECEIVED` deliveries collapse. Implementations compare the full string byte-wise lexically (`"sms:100" < "sms:99"`) and never parse the numeric id. `sendResult.messageId` is a provider ID only on a successful READ_SMS lookup, otherwise `""` and always `""` when `result != 0`.

Results: 0 accepted, 1 disabled (required Android permission missing: READ_SMS for thread/history requests, SEND_SMS for a reply), 2 busy, 3 stale, 4 unsupported, 5 failed, 6 invalid. For a reply, 0 means every multipart `sentIntent` reported `RESULT_OK` — radio acceptance, not recipient delivery. Non-zero results never advance a cursor; only `result = 0` makes `historyDone`/`threadDone` cursors meaningful.

## Ordering and cursors

The thread list is ordered `(dateMillis DESC, threadId DESC)` and carries at most the `maxThreadsPerPage` limit the peer advertised on that link (50 at most) of the most recent threads with no cursor; `maxMessagesPerPage` bounds a requested history page the same way. History is ordered `(dateMillis DESC, messageId DESC)` with byte-wise lexical messageId comparison, and `(dateMillis, messageId)` exists because MMS seconds collapse to identical milliseconds and carriers split long SMS into rows sharing one timestamp. A row is older than the cursor when `dateMillis < beforeMillis`, or when equal and `messageId` compares less than `beforeMessageId`. An initial request uses `beforeMillis = 0` with `beforeMessageId = ""`; `nextBeforeMillis = 0` with `nextBeforeMessageId = ""` means no more pages. Android scans SMS and MMS with independent source positions, filters and orders by timestamp only in SQL and applies the messageId tie-break in Kotlin, because SQLite integer ordering (`99 < 100`) diverges from the lexical contract ordering. A tie group above 2,048 rows returns result 4 without advancing the cursor. An incomplete provider source read returns result 5; failure is never a terminal empty page.

## Flow, acks and failure

Capability must precede traffic on each channel generation: Android sends live events only after the Mac capability, the Mac requests only after the Android capability, and both re-send capability on every new channel. A capability record is idempotent, so a peer that has not received the other's capability may send it again, and the receiver answers a capability record with its own; a hello lost in either direction is therefore recovered without waiting for a new channel generation. One thread-list, one history page and one outgoing reply are in flight per peer, with 30-second LAN and 60-second BLE deadlines; stale request/stream IDs are ignored. A history page is a sequence of `messageBegin`/`messageFragment`/`messageCommit` records terminated by `historyDone`.

Live events are acknowledged with `messageResult`; only result 0 from an attempted authenticated peer/channel confirms receipt, transient errors remain retryable and disabled/unsupported/invalid results terminate the event; history pages are covered by `historyDone` alone and per-message history acks are omitted. A mid-page channel loss aborts the page with no `historyDone`; the Mac re-requests from its last completed cursor. Live delivery prefers LAN, falls back to an already-secured BLE channel, and retries once on the other live channel after failure. An unacknowledged event is offered again inside its pending lifetime (every few seconds) instead of waiting for the next channel generation, and a peer whose capability has not been received is asked to advertise again on that link. Replies are fragmented by the Mac and reassembled by Android under the transport-specific deadline before sending; Android emits `sendResult` only after every part `sentIntent` reports `RESULT_OK`, a part fails, or the request deadline expires. Result 5 after telephony submission is unconfirmed and must not trigger automatic resending. Completed reply request IDs retain at most 32 results per connected peer for ten minutes; duplicate commits return the recorded result, and the cache is cleared on the last channel retirement. A reply with no live channel fast-fails; replies are never queued or persisted.

Rows 1..24,576 bytes are transmitted; oversized provider bodies are skipped and counted, never truncated, and one skipped row must not fail a page. With no live channel, Android keeps at most 16 pending live events for 10 minutes and flushes them on the next channel; nothing survives process death on either platform, and an incoming SMS may request the existing bounded automatic LAN attempt.

## Deduplication and merge

Live events are deduplicated for 10 minutes by messageId; a one-to-one content key `(normalized address, direction, SHA-256 body, dateMillis ±5 s)` merges provider and live copies. Distinct live IDs are not collapsed solely because their bodies match. The content key lets a live PDU copy merge with the provider row the default SMS app writes asynchronously: the provider `sms:`/`mms:` record wins and replaces the `live:` copy in the Mac thread view, and an already-posted notification is left untouched. Notifications are posted exactly once per previously unknown live message; history refreshes post none.

## Permissions and privacy

Android live relay needs RECEIVE_SMS, threads/history need READ_SMS and replies need SEND_SMS; result 1 carries the distinction. Neither platform writes SMS content to disk and neither logs bodies or addresses; the Mac keeps peer data in memory only and clears it when the peer's last link retires, trust is removed or the app quits. No contacts lookup (no READ_CONTACTS) and no read-state mutation occur; `unreadCount` counts unread incoming provider rows (the threads view's `read` column is an all-read flag, never a count) and viewing history does not mark SMS read. MMS support is limited to text/plain parts: group MMS (more than one recipient) and attachment-only messages are detected and reported unsupported rather than guessed, and MMS send is impossible through public Android APIs.
