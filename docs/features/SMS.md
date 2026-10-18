<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Describes SMS relay from Android to macOS: permissions, delivery, limits and acceptance. -->
# Messages (SMS relay)

Messages relays incoming SMS from the paired Android phone to the Mac and lets you read the phone's conversations and reply from the Mac. Traffic uses the existing authenticated LAN or Bluetooth session; nothing reaches a cloud service, and the Mac keeps SMS content in memory only. Android remains the source of truth: the Mac reads provider lists on demand and never polls or writes SMS storage.

Open Features → Messages on either platform. On Android the panel requests SMS permissions, lists conversations, shows a conversation with its composer and reports unread counts and skipped rows. On the Mac the panel selects a connected phone, lists conversations, opens a conversation with its history and a composer, and reports status inline. Mac notifications carry the address as their title, the message text as their body when preview is enabled (a generic “New message” otherwise), an inline Reply action and the default tap that opens Messages.

## Permissions

Android needs three permissions with distinct roles: RECEIVE_SMS for live relay, READ_SMS for conversations and history (and for provider message IDs after a reply), and SEND_SMS for replies. Features → Messages → Allow SMS access requests exactly the missing ones and explains each. If Android permanently denied a permission, or the app was sideloaded on Android 13+, the panel links to App info and explains **Allow restricted settings**. Shared results name the missing permission (result 1) separately from a provider or store failure (result 5), and the Mac shows the same distinction.

With only RECEIVE_SMS, live messages still arrive but carry `live:` message IDs and `addr:` conversation identities, no unread counts and no provider history; granting READ_SMS adds provider threads, message IDs and paging. SMS permissions are Play-restricted and this build is GPL/sideloaded, so store distribution is not claimed.

## Delivery

A send requires an already-secured SMS-capable peer. LAN is preferred; an already-secured Bluetooth channel is used when LAN is unavailable, and a live event retries once on the other live channel after a failure. Mid-page channel loss aborts that page without a completion record, and the Mac asks again from its last completed cursor; stale request and stream IDs are discarded.

Messages are 1..24,576 UTF-8 bytes in up to eight fragments of 3,072 bytes, verified against a SHA-256 digest before display; NUL is replaced by U+FFFD and never transmitted. One thread list, one history page and one reply may be in flight per peer at a time, each with a 30-second deadline.

Nothing queues: a reply with no live channel fast-fails with a banner alert instead of waiting, and live events that arrive with no channel are kept in memory for at most 10 minutes (16 events) and flushed on the next channel. Neither platform replays anything after process death.

Replies are fragmented by the Mac, reassembled and sent by the phone under the same 30-second deadline, using the default SMS subscription only (dual SIM does not offer a per-reply choice). Result 0 means every part was accepted by the radio, not that the recipient received it, and short-code billing or concatenation limits can surface as result 5. The Mac keeps an in-memory echo of each sent reply and merges it with the provider row after the next refresh when the default SMS app records it.

## On the Mac

Notifications are posted exactly once per previously unknown live message and grouped by normalized address. Message text stays hidden until **Show message text in notifications** is enabled per phone in Settings → Messages (default off); the banner then shows the text while Reply keeps working either way. Reply text is clamped to 24,576 bytes on codepoint boundaries. A reply that fails to send or is never confirmed posts a follow-up **Message to <address> failed to send** alert and shows the same error inline. SMS notifications are cleared on quit, and startup clears leftovers under the reserved identifier prefix.

Conversations are grouped by normalized address, so a live-only conversation and its later provider thread remain one card; the list shows at most the 50 most recent provider threads with no older-thread paging in v1. History pages carry 50 rows ordered newest first with a byte-wise messageId tie-break. A provider record that matches a live copy (same normalized address, body digest and a ±5 second timestamp tolerance) replaces it, and an already-posted notification is left untouched. Viewing history never marks SMS read; unread counts are provider values. Nothing is written to disk, and peer data is dropped when the phone's last channel retires, when trust is removed or when the app quits.

## Android specifics

Thread metadata prefers the semi-internal `content://mms-sms/conversations` view with `canonical-addresses` resolution; any provider failure falls back to the newest `content://sms`/`content://mms` row for that thread, and a thread that cannot be resolved is skipped and counted instead of transmitting a placeholder. History queries `content://sms` and `content://mms` directly, decodes text/plain MMS parts with a UTF-8 fallback, sanitizes provider dirt (drafts, empty or undecodable addresses, NUL, oversized bodies, date clamping) and converts MMS seconds to milliseconds. No contacts lookup is performed, so addresses are shown as stored.

SQL paging filters and orders by timestamp only; rows sharing a boundary timestamp are over-included in memory (up to a 2,048-row cap per tie group) and the byte-wise messageId tie-break is applied in Kotlin. A page whose tie group exceeds that cap ends with a cursor so the next request continues. An `addr:` conversation has no provider row, so its history request returns an empty terminal page until the thread list reports a provider thread ID and the Mac re-requests with it.

Skipped rows are totaled and shown as **n rows could not be read** on both the list and the conversation; one unreadable legacy row never fails a page. Group MMS (more than one recipient) and attachment-only MMS are reported unsupported rather than guessed, and MMS cannot be sent through public Android APIs.

## Limits

v1 excludes RCS, MMS send, group MMS content, attachments, contacts resolution, a durable Mac history or search, mark-as-read, dual-SIM reply selection and any background Android SMS reader beyond the manifest receiver (a non-default app receives no MMS broadcast, so incoming MMS text appears on the next refresh). Relay requires the Mac app running with a secured session, and queued events do not survive process death.

OEM telephony providers vary: the conversations view can throw or omit columns, timestamp handling can differ, and an app that is not the default SMS app is not guaranteed to have its sent rows inserted into the provider. A provider that rewrites timestamps outside the ±5 second merge window can leave a duplicate until the next history refresh.

## Verification

- Emulator: grant the three SMS permissions, inject inbound SMS with `adb emu sms send <number> "text"`, verify the Mac notification, the conversation and its history, and a reply; confirm the sent row appears in `content://sms/sent`.
- Physical: real SMS receive and reply, permission-denied states including RECEIVE_SMS without READ_SMS, OEM provider reads through both the conversations view and the direct fallback, live→provider merge after the default SMS app inserts the row, no-live-channel queueing, Mac quit and relaunch behavior, dual-SIM send, and group MMS and attachment-only MMS rejection.

The [wire contract](../../protocol/sms/README.md) defines exact bounds, results and ordering; [DESIGN.md](../design/DESIGN.md) records the panel rules.
