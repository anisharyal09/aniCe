<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Describes SMS relay permissions, native presentation, delivery and provider access. -->
# Messages (SMS relay)

Messages relays incoming Android SMS to Mac notifications and lets the Mac browse conversations, search and reply over an existing secured LAN or Bluetooth connection. Android remains the source of truth. The Mac keeps received message content in memory and clears it when the phone's last channel retires, trust is removed or the app quits. Neither application logs message bodies, addresses or search queries.

Mac reply drafts and the selected phone/conversation remain in memory across panel navigation and temporary disconnection. Each phone's conversation and drafts are scoped to its full device credential. Switching phones restores only that phone's context. Trust removal, identity reset and Quit clear this presentation state; received messages must be loaded again after reconnection.

Android keeps each local conversation's draft, SIM choice and pending send in the SMS owner across panel navigation. Returning to a pending send does not submit it again. Successful sends clear only their submitted draft; failed or unconfirmed sends retain it. Identity reset clears this presentation state and fences late send results.

Open **Features → Messages** on either platform. Viewing messages never marks them read, and unread counts come from unread incoming SMS provider rows. No contacts permission or lookup is used.

## Permissions

Android requests only the missing SMS permissions from its Messages panel:

| Permission | Enables |
| --- | --- |
| RECEIVE_SMS | Incoming live relay |
| READ_SMS | Conversations, history, search and best-effort sent-row lookup |
| SEND_SMS | Replies |
| READ_PHONE_STATE | Optional active-SIM listing |

The SMS permission block disappears once all three SMS grants are present and returns when a grant is revoked. Settings shows a short missing-permission hint rather than a second permission flow. After a permanent denial, the panel links to App info and explains Android's **Allow restricted settings** option for sideloaded apps. SMS permissions are Play-restricted; store distribution is outside this build's scope.

Live relay works with RECEIVE_SMS alone. Without READ_SMS, messages use `live:` IDs and `addr:` conversation identities, with no provider history or unread counts. SIM listing is optional: receive, history, search and replies on the phone default work without READ_PHONE_STATE. A missing required permission returns result 1; a provider failure returns result 5.

## Conversations and replies

Both panels read from oldest to newest and keep the composer below the newest message at the bottom. Android places the SIM selector on the left and **Send SMS** at the far-right edge of the same row. The selector appears only when a second active subscription is available; long labels shorten to fit. The Mac places its SIM selector beside Send and supports Return or Command-Return to send, with Shift-Return for a newline. Android's keyboard Send action uses the same path as its button.

New sends and live receipts retain their local submit/receive order, including after a provider copy replaces them. A carrier timestamp that predates the send it answers cannot move that received reply below the send. Untouched provider history keeps its timestamp and byte-wise identifier order. Displayed timestamps remain the original provider or carrier values; this presentation ordering does not change wire timestamps or paging cursors.

The Mac paints a provisional **Sending** row using the wall-clock submit time; deadlines use monotonic time. History cannot consume that pending row before the phone confirms it. A successful result settles its identity and timestamp; a rejected or unconfirmed result removes it and retains the draft. Distinct provider IDs remain distinct even when their text matches. An echo without a provider ID cannot adopt a row older than the phone's send-queue time. Android performs one newest-page reread after two seconds when its sent provider row is not yet available.

Result 0 means every multipart `sentIntent` reported radio acceptance, not recipient delivery. Android can show a system confirmation for third-party sends; cancellation, carrier rejection or an expired confirmation window can produce result 5. An uncertain reply reads **Not confirmed; it may have been sent** and is never automatically resent.

Replies use the phone's default SMS subscription unless an active one is explicitly chosen. Unknown or inactive choices fail with result 4 and never fall back to another SIM. Notification inline replies always use the phone default. Choices remain in memory. A conversation labels message origins only when it contains two or more known subscriptions.

Conversations group by normalized address, including trimmed uppercase alphanumeric senders. A live-only conversation and its later provider thread share one card. Provider copies replace matching live rows one-to-one using address, direction, body digest, a five-second timestamp tolerance and compatible subscriptions. Two SIM copies retain separate rows. Messages sent from the phone's other messaging apps and incoming text MMS appear on the next refresh.

## Paging and search

Both panels start with 15 conversations and continue from the phone's `(dateMillis, threadId)` cursor. A visible load button remains available while another page exists. Opening a conversation requests the latest ten messages; **Show older messages** uses a separate older-history cursor. A newest-page refresh does not rewind that cursor on the Mac.

Android prefers `content://mms-sms/conversations`, resolves canonical addresses and falls back to direct SMS/MMS rows when the conversations view is unavailable. Provider dirt is skipped and counted. Thread scans read `limit + 32` windows, complete boundary timestamp groups up to 2,048 rows and apply the lexical cursor in memory. Up to eight windows are examined per request. Reaching that work limit returns a continuation; an oversized group returns result 4. Partial reads do not replace a completed snapshot or advance its cursor. The direct-thread fallback supplies a degraded first page only.

History merges independent SMS and MMS scans, converts MMS seconds to milliseconds and applies byte-wise message-ID ordering in memory. A terminal page carries `(0, "")`. Group MMS and attachment-only MMS are unsupported; text/plain MMS parts can be read. Oversized bodies are skipped rather than truncated.

Mac search matches a substring in SMS bodies and text/plain MMS parts on the phone. Queries are 2–64 UTF-8 bytes; matching is ASCII case-insensitive and treats `\\`, `%` and `_` literally. New queries cancel the page in flight. Results have their own cursors, remain separate from conversations and never notify or mark messages read. The Mac holds at most four pages and 200 results per phone; the phone caps MMS match scans at 2,048 message IDs. No index, query history or saved results are created.

## Notifications

Mac notifications name the sender, support inline Reply and open Messages on the default tap. Message text is hidden until **Show message text in notifications** is enabled for that phone. **Notifications** and **Play sound** default on; turning notifications off also suppresses sound and reply-failure alerts while relay and panel counters continue. These controls are available in Settings → Messages and behind the panel's gear.

Authorization is requested at Mac launch. Permission, alert availability and submission failures appear in the panel. Focus and macOS presentation settings can suppress an accepted notification. A provider row fetched before its live copy does not consume the notification; only successful notification submission suppresses repeat announcements. SMS notifications are cleared on quit and leftover identifiers are removed at startup.

## Connection and content limits

The [SMS v3 contract](../../protocol/sms/README.md) requires both applications to update together. It allows bodies of 1–24,576 UTF-8 bytes in up to eight digest-verified fragments. LAN is preferred; secured Bluetooth is the fallback. Bluetooth advertises 20 threads and ten messages per page, compared with up to 50 each on LAN. Request deadlines are 30 seconds on LAN and 60 seconds on Bluetooth.

A disconnected reply fails immediately. Live receipts can wait in memory for up to ten minutes, with at most 16 pending events, and retry while that window remains open. Capability negotiation and acknowledgements recover lost live delivery without waiting for a new connection. Mid-page connection loss aborts the page; retries start from the last completed cursor. Nothing replays after process death.

RCS, MMS send, group MMS content, attachments, contacts resolution, mark-as-read, durable Mac history and jumping from search results to a message are outside SMS v3. OEM providers can vary in column availability, timestamp handling and sent-row insertion.
