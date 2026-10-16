# Find Device v1

[find-device.cddl](find-device.cddl) defines deterministic CBOR envelopes carried by existing authenticated DATA. Messages are at most 128 bytes: `["aniCe find device", 1, kind, fields]`. Non-minimal encodings, indefinite lengths, trailing bytes, wrong field types/counts, unknown versions/kinds and out-of-range integers are rejected. Session readiness, native identity/trust validation, framing and encryption remain unchanged.

| Kind | Fields | Meaning |
| --- | --- | --- |
| 1 | `[]` | Feature capability, sent by both platforms once per secured connection instance |
| 2 | `[requestId, sequence]` | Request one native alert |
| 3 | `[requestId, sequence, result]` | Correlated processing result |

`requestId` is a randomly generated UUID in canonical lowercase 36-character hyphenated syntax. Sequence increases from 1 through 4,294,967,295 across the sending peer’s coexisting secured channels, without wrapping. The receiver binds all mutations to authenticated device ID, fingerprint and connection instance. Results must match the pending request ID, sequence and originating instance. Feature capability is required on that instance before requests/results are processed. Absent capability leaves other features usable.

Results: `0 submitted`, `1 blocked`, `2 stale`, `3 busy`, `4 failed`. Submitted means the receiver's native notification API accepted submission after settings checks; Android also waits for native alarm-player startup. Audio/service startup errors return failed. It does not establish that the notification appeared, was seen or was heard. Blocked covers missing local permission or disabled app/channel presentation. A sender times out after ten monotonic seconds; missing/late results leave delivery unconfirmed. No automatic resend, reconnect replay or transport migration occurs.

## Routing and bounded ownership

Send through one compatible already-secured channel for the selected authenticated peer: LAN first, otherwise BLE. Connection replacement retires pending requests, unsent logical messages and alerts bound to that instance. Old callbacks cannot update a replacement operation. Connections and Session retain security and transport ownership; the feature never starts a connection or acquires a background lease.

Coexisting BLE/LAN channels for one authenticated peer share at most 32 completed request results, one send counter and a receive sequence high-water mark. Exact cached duplicates return the previous result without notification submission. An in-flight duplicate is ignored until its original completes. Reused cached UUIDs with a different sequence and sequence values below the high-water mark return stale. Evicted sequences cannot execute again. History survives retirement of one coexisting transport and ends when the last channel for that peer retires. Results and callbacks still bind to the originating connection generation; authenticated records cannot be transferred between generations. Requests must never be migrated or retried on another channel.

One outbound request exists per application owner. One native submission runs per authenticated peer, and at most one alert exists per authenticated peer across BLE/LAN. A different request during native submission returns busy. Android also returns busy while ringing. Mac replaces an existing submitted notification for a fresh admitted request, clearing its old local identifier before submitting the new one. Cached or stale requests never trigger replacement. Each channel has an eight-entry logical outbound queue with ten-second absolute deadlines. Duplicate queued replies coalesce. Capacity refusal waits for existing transport events; expired entries are removed without reconnect replay. Incoming work without response headroom is discarded without notification submission.

An accepted alert has a fixed sixty-second monotonic lifetime from initial admission. Duplicates never extend it. Dismiss, native swipe/Clear all, expiry and connection retirement clear the same identifier-bound alert. A later notification callback checks generation and alert identity; if retired/dismissed it removes any late native submission. Dismissal never lowers the replay floor. Notifications use independent opaque local identifiers so old native actions cannot dismiss replacement alerts.

## Native presentation

The receiving platform localizes the template `Your paired device <name> is looking for you.` using the authenticated peer's display name. Text/name is not supplied by the request. Mac provides Dismiss; Android provides Stop ringing and supports native deletion where its foreground-service notification is dismissible. Both use identifier-bound native actions. Permission requests are explicit local UI actions; remote requests never prompt.

Android uses a normal-importance notification channel, checks runtime/app/channel permission, and starts a non-exported mediaPlayback foreground service for one admitted local identifier. The service uses USAGE_ALARM/CONTENT_TYPE_SONIFICATION, transient audio focus, the current system alarm tone (ringtone fallback), asynchronous preparation, looping playback and a playback-scoped partial wake lock. Sound mode and stream volumes are never written. Zero/muted alarm volume, denied focus, service refusal or preparation failure returns failed. Native startup is bounded to four seconds and alert lifetime remains sixty seconds from admission. Stop/delete, disconnect, expiry, audio-focus loss and service destruction release player/focus/wake ownership. START_NOT_STICKY prevents service replay. Android's foreground app shows a localizable Stop dialog; no full-screen intent, background activity launch or DND bypass exists.

Mac retains UserNotifications with custom-dismiss callbacks, foreground banner/list/sound presentation, checked settings/submission and application-owned expiry. Neither platform promises audible delivery or changes global volume/settings. No location payload exists.

Android API 31+ background BLE still requires existing valid companion ownership; API 29–30 remain foreground/manual. LAN keeps its existing foreground/approved-work ownership. The ringing service acquires no network lease and does not initiate connections. Background service-start eligibility remains platform-controlled. Mac clears alerts on normal termination and at startup; expiry resumes with execution. An abruptly terminated or suspended Mac process cannot guarantee wall-clock removal of a delivered notification.


## Fixtures

[Independent fixtures](../test-vectors/find-device/find-device-vectors.json) contain eight valid and 24 invalid envelopes produced by a standalone Python encoder. Native suites assert inventory floors, canonical bytes, invalid bounds, generation correlation, dismissal replay, permission failure and monotonic deadlines. Native OS presentation and physical transport acceptance are separate checks.
