<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Defines opt-in Android playback capture to Mac without reinterpreting the existing Mac-to-phone protocol. -->
# Phone Audio v1 — Android → Mac

Phone Audio is the Android-to-Mac direction of Audio Sharing. It uses the existing authenticated LAN DATA channel, identity/trust and
ordered encrypted records. It adds no pairing or network stack. Its separate
`"aniCe phone audio"` tag prevents older Mac-to-phone listeners from mistaking
reverse Audio or Start for their own stream. See [phone-audio.cddl](phone-audio.cddl).

The fixed format is 48-kHz stereo little-endian PCM16, 960 frames/20 ms per packet.
Every message is canonical CBOR, at most 4,000 bytes. UUIDv4, checked sequence
limits, offsets and PCM lengths match the existing [audio timeline](README.md).

| Kind | Direction | Fields |
| --- | --- | --- |
| 0 capability | Mac → Android | `[48000, 2, 16, 960, enabled]` |
| 1 start | Android → Mac | `[streamId, 48000, 2, 16, 960]` |
| 2 result | Mac → Android | `[streamId, result: 0..9]` |
| 3 audio | Android → Mac | `[streamId, sequence, sampleOffset, pcm]` |
| 4 stop | Either | `[streamId, reason: 0..7]` |

Mac receiving consent defaults off and binds its current local identity and the
full phone credential. Android Start must be a local user action on a secured
LAN channel with enabled capability. Android requests RECORD_AUDIO and native
MediaProjection consent; a grant is single-use for this operation, never saved,
replayed after restart, or requested by a remote message. The foreground service
must own `mediaProjection` before acquiring the projection on modern Android.
Every projection registers a native revocation callback before capture begins.
No virtual display, screen pixels, microphone or audio file is needed.

Capture uses AudioPlaybackCapture (API 29+), matching MEDIA, GAME and UNKNOWN
usages. Android still enforces the source app's capture policy and same-user
boundary. Calls, microphone audio and protected/opted-out apps are not supported.
Silence is valid PCM, not evidence that a source permitted capture.
This API does **not** mute source-app output; reducing phone media volume can
affect capture too. Do not claim private or gapless source suppression.

Start/result and Android native preparation have a five-second budget, excluding
only the negotiated channel-maintenance interval. Result codes retain Ready=0,
disabled=1, busy=2, unsupported format=3, blocked native startup=4,
focus denied=5, unavailable output=6, notification setup=7,
native failure=8 and timeout=9. Mac output can be speakers or the selected system
headphones; user-approved receiving is not a promise of private output.
Stop uses the [Mac-to-Android audio reason codes](README.md#stop-reasons);
projection revocation is consent withdrawal (0).

Owners bind full credentials, channel instance, stream UUID and generation.
Duplicate Start coalesces only for the same live operation; retired IDs stay
retired. Projection revocation, Stop, trust loss, channel retirement, service
destruction, sleep and Quit stop locally first, never await network cleanup.
No reconnect starts capture automatically. Stale completion cannot revive output.

Source sequence advances even for packets dropped before sealing. Keep only
bounded current audio: three unsent packets plus one send; Mac's native output
reservation is at most six packets/120 ms, not an end-to-end latency estimate.
Already sealed records remain session-owned and ordered, never replayed.
Overflow drops obsolete unsealed PCM; underflow is silence, not historical replay.
Control messages survive pre-seal backpressure and wait for capacity rather than
spinning or silently losing Start/Stop. The capture worker wakes a serialized
sender; the bounded audio window owns all unsent PCM.
Mac output treats a native configuration/device change as unavailable: it stops
the operation and requires an explicit new Start. Playback starts or resumes
with up to three packets of prefill; an 80-ms fallback starts playback with fewer.
At the six-packet cap of audio waiting to render it clears queued older PCM
and begins a new prefill, counting that resync. The player fades in new PCM at
startup, after a sequence gap, or after re-buffering. Android capture reports
LOCAL, REVOKED or FAILURE teardown; Stop/close unblocks reads normally, empty
reads retry and persistent native failures end with a failure cause.

Retained-socket renewal closes capture forwarding and clears obsolete PCM while
keeping the user-authorized operation. Resume must recheck native projection and
output ownership, discard older native output and play current audio only.
Ordinary security deadlines remain
absolute. Reverse sending and Mac-to-phone listening are mutually exclusive in
app assembly to prevent feedback capture loops.

The Android foreground-service owner holds a job-scoped lease through shared LAN
infrastructure, not a feature-specific reconnect policy. Native destruction and
Mac output cleanup fence the next operation and the opposite direction. Pending
projection consent is bound to the initiating channel and is discarded on
replacement, cancellation or view disposal. Mac receiving consent persists for
the same local identity and full phone credential; that preference alone never
starts capture.

The preview may additionally emit bounded local timing counters on each side.
They add no envelope kind or field, never carry PCM or peer/stream identity, stop
after ten minutes and do not change consent, routing or acceptance. Their local
clocks are not synchronized, so they identify where time is lost, not why.
