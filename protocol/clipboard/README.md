<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Defines text clipboard delivery inside authenticated application DATA. -->
# Clipboard v1

Each DATA plaintext is deterministic RFC 8949 CBOR `["aniCe clipboard", 1, kind, fields]`, at most 4,000 bytes. Reject non-minimal encoding, invalid UTF-8, extra fields, unknown kinds and out-of-range integers. UUIDs are canonical lowercase text. No URI dereferencing or rich text.

| Kind | Fields |
| --- | --- |
| 1 capability | `[senderEpoch: uuid, maxItemBytes: 65536, maxFragmentBytes: 3072]` |
| 2 settings | `[revision: 1..2^32-1, automaticReceive: bool]` |
| 3 begin | `[epoch: uuid, revision: 1..2^32-1, itemId: uuid, mode: 0..1, sensitive: bool, totalBytes: 1..65536, fragmentCount: 1..22, sha256: bstr .size 32]` |
| 4 fragment | `[itemId: uuid, index: 0..21, bytes: bstr .size (1..3072)]` |
| 5 commit | `[itemId: uuid]` |
| 6 result | `[itemId: uuid, result: 0..7]` |
| 7 cancel | `[itemId: uuid]` |

Results: 0 applied, 1 disabled, 2 busy, 3 stale, 4 conflict, 5 write failed, 6 invalid, 7 cancelled. Mode 0 is manual; mode 1 automatic. Capabilities precede item data on each channel generation. Settings follow capability, update on preference changes, and higher revisions supersede lower revisions across both channels. Equal settings revisions must agree. An epoch is shared across a sender's simultaneous transports; overlapping channels must advertise the same epoch. After all channels retire, a new epoch may be admitted. Manual receiving needs no automatic preference; automatic receiving requires the local preference. Sending automatically also requires the destination's advertised permission.

## Assembly and ordering

One incoming assembly per pinned credential, one outgoing item and one latest pending automatic copy. The count is `ceil(totalBytes/3072)`; all fragments except the last are exactly 3,072 bytes. Fragments are contiguous. Repeated fragment indexes must contain identical bytes. Duplicate begin metadata must match exactly; reuse of a UUID with different metadata is invalid. Assemble in bounded memory, verify digest and strict UTF-8 (reject NUL), and write only the complete item. Reserve terminal-cache capacity before accepting begin. Native writes and terminal-result recording are serialized without suspension between them.

Each peer shares assembly, revision floors and results across transports. An accepted higher begin revision advances the floor; older/reused revisions cannot apply. A receiver retains at most 32 terminal results for 60 seconds and never evicts an unexpired entry to admit another item. Duplicate begin/commit returns the cached result without another write. Duplicate fragments for a terminal item are ignored. First-begin conflict baselines and deadlines survive retries. Cache exhaustion returns busy without accepting the item.

The sender starts a 30-second monotonic deadline before its first submission attempt. The receiver starts its own fixed 30-second deadline at first begin. Capacity refusal waits for transport events, never polling. Once commit submission returns, wait two seconds for a result. On channel failure or missing result retry the same logical item once on the other already-secured capable transport, under the original deadline. Fresh records use each channel's own keys/counters. A result must match the peer, item and an attempted live channel generation. Do not reconnect for retry. With no alternative, report delivery unconfirmed. Complete session loss abandons outgoing items, incomplete input and pending automatic copies; no replay after reconnection. At-most-once applies to the live receiver process, not durable recovery.

Cancel is best effort: stop future submissions and discard incomplete assembly on receipt. It cannot undo a completed native write. Disabling automatic mode cancels pending automatic work and rejects automatic input at commit as well as begin. Selecting another peer cancels outgoing work without removing preferences.

## Native clipboard and privacy

Android reads only with actual input focus, sampling once on focus gain and observing while focused. The Android Quick Settings entry uses a focused explicit-read panel: one capture, metadata-only presentation and explicit Send, with sensitivity preserved in the existing begin flag. This manual focus does not enable automatic observation; the TileService itself has no clipboard access. Foreground service ownership is no exemption. Android background input writes immediately without conflict detection or readback. Focused Android and Mac compare the first-begin native change token immediately before applying; a changed clipboard returns conflict. A successful Android write means `setPrimaryClip` returned without throwing. Mac checks the native write result. Neither result proves a later paste.

Automatic sending skips Android `android.content.extra.IS_SENSITIVE` and `android.content.extra.IS_REMOTE_DEVICE`; Mac `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, `org.nspasteboard.AutoGeneratedType`, `com.apple.is-remote-clipboard`. Manual sensitive content requires explicit confirmation. Received content carries remote/generated and, where needed, sensitivity markers. Markers and native own-write tokens prevent echoes, including on Android focus regain. These conventions do not detect unmarked secrets. Content stays out of logs, notifications and saved UI state. Delivery assemblies, retries and terminal results remain process-local. Separately enabled device-local history may persist eligible text after local capture or successful native application; sensitive-marked and recognized transient/generated content is excluded. History is not a durable delivery queue and is never replayed automatically. Mac uses one changeCount observer at 500-ms intervals for automatic sharing with an opted-in compatible live peer or for enabled local history, respecting OS access behavior and sleep. Automatic-sharing preference keys include device ID and fingerprint; trust removal and identity reset prune them. Local history consent is device-scoped and off by default.

Native recent-activity presentation is separate from delivery state and optional history. It retains at most one eligible item in process memory for five minutes following result 0 on outgoing work or a successful incoming native write. Eligible samples expose a bounded two-line text preview and explicit full-item Copy on Android Home and the Mac overview/companion. Sensitive/excluded samples retain metadata only. Expiry, dismissal and trust/identity invalidation clear it; duplicate delivery must not refresh it. Copying activity is a local marked write, not an automatic send or replay. No additional DATA messages, wire fields or protocol version are introduced.
