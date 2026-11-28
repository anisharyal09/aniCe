<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Defines private audio admission, bounded PCM timelines and retained-channel LAN maintenance behavior. -->
# Audio Sharing v1 — Mac → Android

The reverse Android-to-Mac direction is defined separately in
[Phone Audio v1](PHONE_AUDIO.md); it does not reinterpret these v1 messages.
Mac system audio travels to one authenticated Android peer through existing secured LAN DATA. This contract adds no pairing, transport, key exchange or BLE feature messages. Each feature message uses deterministic CBOR, is at most 4,000 bytes, and has exactly the shape defined in [audio-sharing.cddl](audio-sharing.cddl).

## Messages and format

The envelope is `["aniCe private listening", 1, kind, fields]`. Kind and fields are bound alternatives, not independent unions.

| Kind | Direction | Fields |
| --- | --- | --- |
| 0 capability | Android → Mac | `[48000, 2, 16, 960, enabled]` |
| 1 start | Mac → Android | `[streamId, 48000, 2, 16, 960]` |
| 2 start result | Android → Mac | `[streamId, result]` |
| 3 audio | Mac → Android | `[streamId, sequence, sampleOffset, pcm]` |
| 4 stop | Either | `[streamId, reason]` |
| 5 status report | Either | `[streamId, side, state, lastSequence, positionFrames, queuedFrames, underruns]` |

Audio is signed PCM16, little-endian, interleaved left then right, at 48,000 stereo frames per second. Each packet contains exactly 960 frames / 20 ms / 3,840 PCM bytes. Maximum-width sequence and offset fields produce a 3,927-byte Audio message, within the existing small-record admission class. Plain PCM consumes 192,000 bytes per second. Larger negotiated LAN record budgets do not enlarge this feature's 4,000-byte bound.

Stream IDs are canonical lowercase UUIDv4 text: 36 ASCII bytes, version nibble `4`, variant nibble `8`, `9`, `a` or `b`. Senders generate a fresh ID for each new listening operation; decoders reject uppercase rather than normalizing it. Integers are limited to signed-64-bit-compatible nonnegative values. Indefinite/nonminimal encoding, wrong types or arities, invalid UTF-8, trailing data, unknown versions/kinds and invalid field values are rejected. Structurally valid messages with a different tag remain available to other handlers.

## Admission and ownership

Android publishes capability once per secured LAN channel and coalesces updates when its receiving preference changes. `enabled` is bound to the current local identity and full trusted Mac credential and defaults to true when no choice is saved. It does not prove service startup authorization, audio focus or headphone routing. The preference alone creates no native execution or connection lease.

Mac requires an already-secured LAN channel and enabled capability. Local system-audio permission and unmuted capture preparation precede Start. Waiting for existing transfer backlog has a separate cancellable ten-second preparation budget before sending Start. Start-to-result is five seconds; Ready-to-first-Audio is five seconds. Local preparation does not mute Mac output before Ready.

Android prepares only one operation. It checks consent and current native startup eligibility, promotes its mediaPlayback service before requesting audio focus, silently primes playback and verifies the actual approved output route before returning Ready. A missing/unconfirmed private route fails preparation rather than launching a background confirmation dialog. Notification permission denial alone does not prohibit a foreground service; result 7 denotes an actual required-notification setup failure.

Android may additionally permit its built-in speaker according to the separate,
local/full-peer-credential-scoped speaker-fallback preference. It defaults to
true when no choice is saved. This
exception is audible, not private, and grants neither receiving consent nor
authorization to unknown/external outputs. The choice is frozen for each Start;
revocation stops the stream. Without it, headphones-only admission is unchanged.
Route fallback pauses/flushes obsolete audio and silently verifies the built-in
speaker before current PCM resumes on the same stream. No new wire field or
Ready replay is introduced; ordinary deadlines, focus and retirement still win.

A duplicate Start with the same ID and channel coalesces during preparation or repeats its live Ready result without extending deadlines. A different ID while preparing or active returns busy. A stopped/rejected/timed-out ID cannot be reused on that channel. A late result cannot revive an aborted operation.

Every mutation binds to the full peer credential, authenticated channel instance, stream ID and local operation generation. Capability is channel-scoped; every other message is stream-scoped. Unknown or retired stream traffic is discarded. Traffic with a valid shape but the wrong direction cannot change the receiving owner's state. Stop for an inactive ID is idempotently ignored. Readiness/submission is not proof of physical audibility.

### Start results

| Code | Meaning |
| --- | --- |
| 0 | Ready |
| 1 | Receiving consent disabled |
| 2 | Another operation is preparing or active |
| 3 | Format or native playback unsupported |
| 4 | Background service startup blocked |
| 5 | Audio focus denied |
| 6 | Headphones missing, unsafe or not confirmed |
| 7 | Required notification setup failed |
| 8 | Native preparation failed |
| 9 | Preparation timed out |

### Stop reasons

| Code | Meaning |
| --- | --- |
| 0 | User stopped, including consent withdrawal |
| 1 | Permanent audio-focus loss |
| 2 | Approved output route lost |
| 3 | Network or peer-health failure |
| 4 | LAN renewal failed |
| 5 | Protocol error |
| 6 | Native capture/playback failure |
| 7 | Preparation or native ownership expired |

Stop cancels local work immediately; cleanup never waits for its remote submission. Explicit Disconnect, channel retirement, trust/identity invalidation, service destruction, Mac sleep and Quit invalidate the operation. A later connection does not restart listening or replay audio. Ending the tap reader restores normal Mac output; a still-playing source can become audible.

## Audio timeline and buffering

Sequence starts at 1 and sampleOffset at 0. Each 960-frame source slot advances sequence even when discarded before submission. `sampleOffset == (sequence - 1) * 960`; both multiplication and `sampleOffset + 960` are checked before allocation or playback. The maximum sequence is `floor((2^63 - 1) / 960) = 9607679205057058`, so the final packet's end position fits the native timeline. Gaps are legal; sequence/offset values never wrap or reset within a stream. Old/duplicate packets are discarded without replay.

Silence is valid PCM, not an underrun or evidence of denied recording permission. Missing audio causes local silence and rebuffering rather than immediate session death. After a delivery burst, Android retains the newest bounded received-sequence window and discards obsolete software audio. Rebuffering resets interpolation history and may pause/flush obsolete native audio. It never pads the entire missing source interval or requests a new stream ID. Already-submitted TCP bytes remain ordered; receiver queue trimming cannot retract them or prove absolute end-to-end freshness.

While post-focus or post-maintenance silent priming verifies routing, the nonzero-PCM write gate stays closed. Valid Audio for the active stream enters the bounded software queue instead of becoming a protocol error. During an extended focus pause or active maintenance, incoming audio is discarded; resume takes current audio, not that pause's history.

The default Android combined software/interpolation/partial-write/native-write backlog target is 5,760 source-rate frames / 120 ms, adapting within 2,880–11,520 frames / 60–240 ms. An explicitly selected local lower-delay profile starts at 1,920 frames / 40 ms and adapts within 960–7,680 frames / 20–160 ms; it changes no negotiated PCM or message bytes. Either profile retains the hard ceiling of 38,400 frames / 800 ms / 153,600 PCM16 bytes. `queuedFrames` reports equivalent 48-kHz stereo frames and has an independent wire ceiling of 48,000 / one second. Native buffering is included once, not added again to the combined target. A platform-mandated startup floor can exceed the local target without exceeding the hard ceiling. Downstream Bluetooth buffers and physical playback latency are outside this accounting. A lower target is not a promise of total 20-ms latency.

Mac's source-format handoff capacity is bounded to 200 ms and its unsealed packet queue to at most ten packets / 9,600 frames / 38,400 PCM bytes. Native workers may retain less: the current Mac consumer trims stalled capture to the newest 60 ms, and the model keeps three unsent packets plus at most one owned by a send. A ring producer never overwrites consumer-owned slots; it drops incoming frames on overflow. Only the consumer discards stale slots. Pre-seal stale audio may be discarded; sealed records retain shared Session/transport nonce and completion ownership.

## Status and focus

`side` is 0 for Mac and 1 for Android and must match the sender's role. States are 0 idle, 1 preparing, 2 streaming, 3 transient-focus-pause, 4 renewing-LAN, and 5 rebuffering. State 5 is health feedback only: it does not authorize Start, stream replacement or renewal. Status may carry idle once on completion; later traffic cannot revive a stopped operation.

Mac `lastSequence` is the highest successfully submitted Audio sequence, or zero before submission. Android `lastSequence` is the highest validated Audio sequence consumed for this active stream, including intentionally discarded packets, or zero before receipt. Mac `positionFrames` is its complete 960-frame source timeline; Android `positionFrames` is its source-frame playback progress mapped through the local resampler/track accounting, not a synchronized wall clock. `queuedFrames` counts the sender's local bounded backlog. `underruns` counts Android native playback underruns, saturating at `2^32 - 1`; Mac reports zero rather than inventing an Android underrun count.

Owners coalesce status changes and report health once per second while owned and outside maintenance. Successfully validated Audio or Status from the current stream confirms feature-peer activity. Missing such activity for ten seconds outside maintenance ends listening. Native transport/security deadlines remain independent. Legitimate silent Audio confirms activity. Slow focus/routing/preparation work must not block the shared DATA dispatcher.

Transient focus loss, including a duck request under pause-on-duck policy, pauses/flushes playback for at most 90 seconds while Mac reads/discards and preserves its selected mute behavior. Focus gain requires silent re-priming and actual route verification. Permanent focus loss ends listening. Route loss ends listening unless the separately consented built-in speaker fallback passes fresh silent verification; unknown outputs never authorize writes. Merely retaining a focus request does not establish granted focus.

## Retained-channel LAN renewal

[In-flight LAN renewal](../lan/RENEWAL.md) owns authenticated barriers, fresh keys/readiness and native phase deadlines. The audio stream uses the existing channel maintenance interval; it adds no renewal messages or cryptographic/session state machine.

Successful renewal preserves TCP, feature-channel identity, stream ID and advancing source timeline. Both owners clear obsolete audio and exclude only the published maintenance interval from ordinary feature timeout accounting. Mac keeps the tap reader active and discards capture. Android retains native service/focus-request ownership. Completion rechecks actual focus/routing and resumes current audio on the same stream. A coalesced maintenance update must still invalidate previously queued audio through cumulative maintenance accounting. No capability or Start/Ready replay marks renewal success.

Native bounds remain ten-second quiescence, thirty-second EDHOC and ten-second encrypted readiness. Stop, native owner loss, network/trust failure and actual channel retirement outrank maintenance. Failure never rolls back keys or restarts the listening operation.

## Transfer and volume integration

App assembly connects listening ownership to existing transfer pacing and native LAN work leases without adding feature imports into Connections. Initial listening-mode transfer limits are future chunks up to 65,536 bytes and outstanding unacknowledged file data up to 131,072 bytes. Fresh advancing streaming health without new underruns may increase local pacing credit in 131,072-byte steps no more often than every four seconds, up to 1,048,576 bytes; chunk size remains at most `max(65536, credit / 8)`, capped by the negotiated chunk limit, and credit never exceeds the negotiated count of those chunks. Existing delayed-path qualification remains authoritative. Buffering, nonadvancing/stale health or new underruns reset the local pacing budget. Already submitted bytes drain normally; reducing a window never discards valid file data. Final listening-lease release restores normal transfer policy. These byte limits do not establish elapsed latency on a congested path.

Android's existing media session uses local media-stream volume throughout listening ownership, including preparation, pauses and maintenance. Already-posted remote Mac volume callbacks are fenced by ownership/provider generation. Remote volume handling returns only after listening ends and current capabilities permit it.
