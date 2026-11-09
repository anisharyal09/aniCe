<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Defines Android-to-Mac notification mirroring inside authenticated application DATA. -->
# Notification Mirroring v1

Notification mirroring sends selected Android app notifications to the connected trusted Mac over the existing authenticated DATA session. It adds no transport or durable store. The Android user explicitly grants Notification Access and selects apps; the picker starts empty and aniCe excludes its own package and the current default SMS app so the SMS relay remains the SMS path. A separate preference, enabled by default while preserving saved choices, includes standard incoming CallStyle notifications and supported persistent system call notifications from any source package. If the dialer does not publish a live SIM-call notification, Android can synthesize one from telephony ringing state after the user grants `READ_PHONE_STATE` and `ANSWER_PHONE_CALLS`. Android OS redaction is preserved.

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
| 9 source app icon | `[packageName, pngBytes]` | Android → Mac, LAN only |

`id` is the lowercase SHA-256 of the source notification key or the in-memory synthetic SIM-call key. `epoch` is a process-instance UUID; `sequence` increases for each observed update. Up to eight source actions with a live PendingIntent are included in order and assigned compact indices from zero. A free-form text RemoteInput is represented by a text-input action. Index `-1` invokes the notification's content intent, or opens the phone's in-call screen for a synthetic SIM call. The phone resolves each request against the active id, epoch, sequence, the peer that received that revision and the action index. Request UUID results are retained in memory for ten minutes (at most 32 per peer), so duplicate requests return the prior outcome without firing the action twice.

For enabled incoming calls, the phone recognizes Android CallStyle metadata and supported system call notifications with Answer and Decline controls. When these controls are exposed, their PendingIntents are used and relayed in Answer-then-Decline order, using platform labels when present. If a SIM dialer publishes no actionable live notification, the phone instead creates two fixed actions against the current telephony ringing state. After authenticating the peer and checking the notification revision, Android calls `TelecomManager.acceptRingingCall()` or `endCall()` only while a SIM call remains ringing. The action is rejected if its call is stale. This fallback requires user-granted `READ_PHONE_STATE` and `ANSWER_PHONE_CALLS` and leaves audio routing on the phone. It sends no caller number. Dismissing a synthetic SIM-call alert hides the Mac copy for that call without rejecting it. The wire record and action indices are unchanged.

Snapshots are bracketed and carry an epoch and high-water sequence. Each snapshot item carries its snapshot token. At snapshot end the Mac removes only same-epoch notifications at or below the high-water sequence that were absent from that snapshot; later live updates survive. Interrupted snapshots do not remove anything. A new epoch replaces the previous epoch for that peer. Updates/removals are idempotent by `(epoch, id, sequence)`, and older events cannot replace newer state.

Result codes are `0 submitted`, `1 stale`, `2 unsupported`, and `3 failed`. A successful action call means Android accepted the PendingIntent or Telecom request, not that the call ultimately connected or was declined. The Mac does not retry an action after an uncertain send. Dismiss requests call `cancelNotification` only while the exact source notification revision is active; synthetic SIM-call dismissal only suppresses that Mac copy until the call ends. OS-driven removals update the Mac; Mac programmatic cleanup never sends a dismissal.

Text is sanitized and truncated on UTF-8 codepoint boundaries before encoding: package name 255 bytes, app name 128, title 512, body 1,024, action label 48, reply placeholder 48 and reply input 1,024. At most eight action items are sent. Notification records stay under the standard 4,000-byte DATA bound. Bodies and action text are not written to aniCe storage or logs. A secure connection sends an active-state snapshot; there is no offline queue or notification history. The Mac notification center receives the displayed content and nonsecret revision metadata so stale system responses can be rejected; aniCe's action target and request-result state stay in memory.

Kind 9 carries a PNG launcher icon separately from the notification record, capped at 3,000 bytes and 128 × 128 pixels. Android sends it before the first alert from that package on each LAN channel; it never sends icons over BLE. If LAN becomes available after a notification was received over BLE, the Mac silently enriches that same revision with the icon. The icon is transferred only in memory and held only for the active connection. The Mac attaches it to the native notification when macOS accepts the image. This record is an additive v1 extension: older Mac peers discard the unknown kind while continuing to receive kind 2 notification records. The native macOS sender icon remains aniCe's app icon; UserNotifications does not let an individual notification replace that sender identity. The Mac bundle therefore includes aniCe's current development mark as a fallback until final brand artwork is chosen.

Reconnect snapshots use passive interruption so old active alerts do not reappear as new banners. Live notification revisions use active interruption. macOS still follows the user's aniCe banner, Focus and Scheduled Summary settings; app code cannot force banners when those settings suppress them.

## Verification

Cross-platform fixtures live under `protocol/test-vectors/notifications/`. They cover all nine message kinds, maximum notification fields, malformed types, IDs, duplicate actions, byte bounds, noncanonical encodings and unknown versions. Tests in both platform suites decode the same fixture bytes. Android and Mac hardware permission, listener redaction, BLE/LAN handoff and source-app PendingIntent behavior require device-level verification.
