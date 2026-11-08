<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Defines Android-to-Mac notification mirroring inside authenticated application DATA. -->
# Notification Mirroring v1

Notification mirroring sends selected Android app notifications to the connected trusted Mac over the existing authenticated DATA session. It adds no transport or durable store. The Android user explicitly grants Notification Access and selects apps; the picker starts empty and aniCe excludes its own package and the current default SMS app so the SMS relay remains the SMS path. A separate preference, enabled by default while preserving saved choices, can also include standard incoming CallStyle notifications from any source package. Android OS redaction is preserved.

Every plaintext is deterministic CBOR `["aniCe notifications", 1, kind, fields]` and at most 4,000 bytes. Both peers advertise kind 1 on every channel generation; a peer without the capability receives no feature records. Unknown tags are unrecognized; malformed records are discarded. Decode then re-encode to reject noncanonical CBOR. The Kotlin and Swift decoders enforce the same field shapes and byte limits from `notifications.cddl`.

| Kind | Fields | Direction |
| --- | --- | --- |
| 1 capability | `[maxActions: 8]` | Both |
| 2 notification | `[snapshotToken, id, epoch, sequence, packageName, appName, title, body, actions]` | Android → Mac |
| 3 removal | `[id, epoch, sequence]` | Android → Mac |
| 4 snapshot begin | `[token, epoch, highWaterSequence]` | Android → Mac |
| 5 snapshot end | `[token]` | Android → Mac |
| 6 action | `[requestId, id, epoch, sequence, index, replyText]` | Mac → Android |
| 7 action result | `[requestId, result]` | Android → Mac |
| 8 dismiss | `[requestId, id, epoch, sequence]` | Mac → Android |

`id` is the lowercase SHA-256 of Android's opaque notification key. `epoch` is a process-instance UUID; `sequence` increases for each observed update. Up to eight source actions with a live PendingIntent are included in order and assigned compact indices from zero. A free-form text RemoteInput is represented by a text-input action. Index `-1` invokes the notification's content intent. The phone resolves each request against the active id, epoch, sequence, the peer that received that revision and the action index. Request UUID results are retained in memory for ten minutes (at most 32 per peer), so duplicate requests return the prior outcome without firing the PendingIntent twice.

For an enabled incoming CallStyle notification, the phone uses Android's answer and decline PendingIntents directly and sends at most those two actions in Answer-then-Decline order, using platform-provided labels when present. This is a local action-selection rule; the wire record and action indices are unchanged. It does not grant aniCe call-control permission or route call audio.

Snapshots are bracketed and carry an epoch and high-water sequence. Each snapshot item carries its snapshot token. At snapshot end the Mac removes only same-epoch notifications at or below the high-water sequence that were absent from that snapshot; later live updates survive. Interrupted snapshots do not remove anything. A new epoch replaces the previous epoch for that peer. Updates/removals are idempotent by `(epoch, id, sequence)`, and older events cannot replace newer state.

Result codes are `0 submitted`, `1 stale`, `2 unsupported`, and `3 failed`. A successful PendingIntent send means Android accepted the dispatch, not that the source app completed its operation. The Mac does not retry an action after an uncertain send. Dismiss requests call `cancelNotification` only while the exact notification revision is active. OS-driven removals update the Mac; Mac programmatic cleanup never sends a dismissal.

Text is sanitized and truncated on UTF-8 codepoint boundaries before encoding: package name 255 bytes, app name 128, title 512, body 1,024, action label 48, reply placeholder 48 and reply input 1,024. At most eight action items are sent. Notification records stay under the standard 4,000-byte DATA bound. Bodies and action text are not written to aniCe storage or logs. A secure connection sends an active-state snapshot; there is no offline queue or notification history. The Mac notification center receives the displayed content and nonsecret revision metadata so stale system responses can be rejected; aniCe's action target and request-result state stay in memory.

## Verification

Cross-platform fixtures live under `protocol/test-vectors/notifications/`. They cover all eight message kinds, maximum notification fields, malformed types, IDs, duplicate actions, byte bounds, noncanonical encodings and unknown versions. Tests in both platform suites decode the same fixture bytes. Android and Mac hardware permission, listener redaction, BLE/LAN handoff and source-app PendingIntent behavior require device-level verification.
