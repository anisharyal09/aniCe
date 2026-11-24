<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Describes explicit Mac system-audio capture and credential-scoped headphone listening on Android. -->
# Private Listening

Private Listening sends Mac system audio to headphones connected to Android through an already-secured local-network connection. It uses the existing trusted-device session, not a cloud relay or Bluetooth audio transport between Mac and phone. Audio is fixed 48-kHz stereo PCM16. Music and podcasts are the primary use; arbitrary Mac video players are not synchronized to the phone's audio clock.

## Setup and start

1. Connect the trusted Mac and Android over LAN using Devices.
2. On Android, open **Features → Private Listening** and enable **Allow audio from this Mac**. Consent defaults off and is bound to both current device identities.
3. Connect headphones. Bluetooth A2DP and generic USB outputs require explicit **These are my headphones** confirmation when a usable route address is available; a name alone does not establish a private output.
4. On Mac, open **Features → Private Listening** and choose **Prepare system audio…**. macOS may request system-audio recording access. Preparation does not suppress Mac output.
5. Choose **Start listening**. The phone promotes a media playback service, requests focus and verifies the actual headphone route with silent audio before returning Ready. Only then does Mac tap suppression begin.

Start requires an already-secured LAN connection; it does not override Disconnect or connection Pause. An existing transfer may need to reduce outstanding bytes before Start. Android startup without a visible activity requires eligible native companion ownership; a rejected background start reports that aniCe must be opened on the phone.

Transfer-drain admission counts only a currently owned outgoing file. Historical
sent/acknowledged counters from a completed, cancelled or dismissed transfer do
not block a new listening operation; live outgoing files retain the same bound.

The Mac minimum is macOS 14.2. Android retains API 29 and later. Native low-latency playback is requested but normal AudioTrack playback remains usable. System-audio capture is governed by macOS permission and source behavior; silent buffers alone do not distinguish a paused source, mute, protected audio or denied capture.

## Volume and privacy

**Also play through Mac speakers** defaults off. While off, `.mutedWhenTapped` suppresses tapped-process output only while the tap reader remains active. Turning it on deliberately allows normal Mac output alongside Android playback. No system default output is changed.

Phone hardware volume buttons and the active media session control local phone/headphone media volume during listening ownership, including preparation, pauses and LAN maintenance. Previously queued remote Mac-volume callbacks are invalidated. Player transport commands remain scoped to current Mac playback capabilities.

Android approves explicitly identified wired headphones/headsets, USB headsets and BLE headsets. A2DP and generic USB are ambiguous and require confirmation. An actual speaker/unknown route is not approved by its product name. By default, route loss and becoming-noisy events stop playback; asynchronous OS routing still governs what happens before notification delivery.

**Use phone speaker when headphones are unavailable** is a separate Android
opt-in, off by default and bound to this Mac's full credential and the current
phone identity. Enable it before Start and confirm that audio can play aloud.
It uses confirmed headphones first, otherwise the built-in phone speaker, and
may switch to that speaker after headphone loss. Recovery pauses and flushes,
then silently verifies the route before current audio resumes. Unknown,
unconfirmed Bluetooth, HDMI and earpiece outputs remain unapproved. Speaker
playback is labelled **not private** in the panel/notification. Turning the
option off during listening stops it; enabling receiving alone never enables
speaker fallback.

Phone speakers avoid downstream Bluetooth encoding/headphone buffering, but
retain capture, LAN, app-buffer and OS-output delay. They do not guarantee
imperceptible latency, video lip-sync, or freedom from scheduling/network stalls.

**Stop listening** is available in the feature panel, phone notification and active Mac companion row. Terminal cleanup restores normal Mac output. A still-playing source can become audible on Mac; the feature is not a crash-proof mute latch. No audio history, saved recording or offline queue is created.

Mac restores the tap's unmuted output before dismantling native capture and shows **Restoring Mac audio…** until cleanup completes. This does not pause or rewind the source, synchronize the Bluetooth tail with Mac output, or guarantee a gapless switch on every output.

## Delay and buffering

Choose a buffering mode on Android before starting:

- **Balanced** is the default: initially 120 ms of app-managed audio, adapting within 60–240 ms.
- **Lower delay** is opt-in: initially 40 ms, adapting within 20–160 ms. A busy connection or scheduler can cause more interruptions.

Late packet arrival and new native underruns raise the local target; sustained healthy playback lowers it slowly. A stream remembers its underrun floor instead of repeatedly retrying an unsustainable lower target, but may cautiously probe one packet lower after two uninterrupted healthy minutes so a transient transfer/radio burst does not permanently add delay. Buffering or a new underrun resets that probe interval. A reduced target promptly trims obsolete software audio while already-written native audio drains normally. The target includes software audio and pending AudioTrack writes once. The worker requests a smaller effective native buffer and startup threshold where Android permits, without assuming that the platform accepted those requests. Older Android versions and some outputs retain a larger native startup floor. Audio memory remains bounded to 800 ms in either mode; this is a ceiling, not a latency goal.

The panel shows current app backlog, target, pending AudioTrack audio (included in the backlog), skipped packets and native underruns. These are local diagnostics, **not measured end-to-end latency**. Bluetooth encoding, OS mixing and headphone buffering can add substantial delay beyond them; wired/USB headphones usually reduce that contribution. Neither mode guarantees video lip-sync. aniCe cannot remove downstream Bluetooth delay or delay video in an arbitrary Mac browser.

For a useful comparison, replay the same source on the same LAN with Balanced and Lower delay, then compare with wired/USB headphones if available. Note both perceived delay and interruptions; also check screen-off playback and transfer coexistence. Switch modes only after stopping, and keep headphone-route/privacy checks unchanged.

With Bluetooth headphones, especially on Android 34+, leaving the app or switching the screen off can still increase Wi-Fi delivery jitter: the low-latency Wi-Fi lock is restricted by Android and is not a screen-off radio guarantee. The CPU/service lease remains separate. A 20-ms local target is only one PCM packet and offers little jitter reserve; if it underruns the adaptive player increases buffering. Do not interpret a larger native effective buffer or target as measured total headphone delay.

## Interruptions and renewal

Transient focus loss pauses/flushes phone playback for at most 90 seconds; Mac capture continues reading/discarding with the chosen mute behavior. Focus return silently re-primes and verifies routing before current audio resumes. Permanent focus loss ends listening. Headphone loss ends listening unless the separately enabled speaker fallback can be silently verified.

Silent priming accounts for delayed native playback-head resets and route-driven startup-threshold changes. A raised threshold tops up only its missing pending silent reservation, including when earlier silence has already drained. It retains the original preparation deadline and never opens audible writes before route verification.

Underflow produces local silence and bounded rebuffering on the same stream. Software queues retain a bounded newest-received window instead of replaying missed seconds. An isolated source gap resets interpolation and ramps the next current packet over 5 ms, without reopening route authorization or repeating silent preparation. Authenticated Audio admission and playback scheduling do not wait for UI rendering. Focus/maintenance recovery still requires silent route verification.

Already-submitted TCP bytes remain ordered; receiver trimming cannot retract them. Listening starts with future transfer chunks up to 64 KiB and 128 KiB of unacknowledged file credit. Fresh advancing playback health with no new underruns gradually permits up to 128-KiB chunks and 1 MiB of credit, always within the peer's negotiated chunk count/window and existing LAN qualification. Buffering, stale health or new underruns return to the initial small budget; already-submitted data drains normally. Transfer data is never discarded to make room for audio. This policy can still reduce file throughput on a congested path; it is not a guarantee of simultaneous maximum transfer speed and low audio latency.

Negotiated LAN renewal uses the existing channel maintenance interval. TCP, the feature-channel descriptor and listening stream remain intact while fresh EDHOC/readiness replace cryptographic keys. Mac keeps reading/discarding; Android keeps native service ownership and rechecks focus/routing afterward. **Renewing secure LAN…** distinguishes that bounded interruption from normal playback. Native phase/security deadlines are not extended.

Channel retirement, Disconnect, trust/identity changes, service destruction, Mac sleep or Quit invalidate listening. A new connection does not restart it automatically or replay audio. CPU/Wi-Fi locks are native playback resources, not permission to reconnect or proof of screen-off radio latency; Android 34+ low-latency Wi-Fi locks retain platform restrictions.

## Implementation boundaries

Android-to-Mac audio is implemented behind explicit local consent, but physical
behaviour is still being verified. [Phone Audio v1](../../protocol/private-listening/PHONE_AUDIO.md)
uses Android's user-authorized playback-capture API, which excludes
protected/opted-out apps, calls and other profiles and does not suppress the
source phone's output. The reverse layer includes canonical fixtures, bounded
packetization, graceful capture teardown, single-use MediaProjection consent, a
`mediaProjection` foreground service, Mac receiving consent bound to the local
identity and phone credential, stream admission that rejects duplicate, unbound
or stale streams, shared job-scoped LAN retention, bounded control retries and
output retirement on native device changes. Reverse
sending and Mac-to-phone listening are mutually exclusive in app assembly to
avoid feedback capture loops. Mac output is not promised to be private and the
phone's own playback is never muted.

In **Features → Private Listening**, enable **Allow audio from this phone** on
Mac, then choose **Share this phone's audio** on Android and approve the native
prompt. Each Android grant belongs to that local action and channel; cancellation,
view disposal, channel replacement and Stop discard it. Mac's receiving choice
persists only for the same identities. Neither reconnect nor that preference
automatically starts capture. Background/screen-off execution remains governed by
Android's native projection/service policy. Real LAN loss ends the stream;
retained-channel renewal keeps the authorized operation, discards older queues
and rechecks output/capture availability before current audio resumes.

Both directions use the shared compact Start/Stop and setup controls, with the
active direction first. Pending native consent and cleanup are labelled; Stop
stays ahead of secondary setup and diagnostics. Android retains 48 dp interaction
targets and whole-row receiving preferences; Mac actions reflow with text scale.
The UI clarifies audio-only sending without replacing the native consent prompt.

Application-scoped feature owners handle DATA, service/capture lifecycle and bounded logical audio queues. Connections owns LAN admission, encrypted records and renewal. The Mac C callback copies Float32 into a lock-free SPSC ring; conversion and sealing stay off that callback. Android's worker performs bounded cubic clock correction without native pitch-preserving timestretching.

See [wire contract](../../protocol/private-listening/README.md), [LAN maintenance](../../protocol/lan/RENEWAL.md), [Now Playing](NOW_PLAYING.md), [performance budgets](../PERFORMANCE.md) and the [physical-test guide](../PRIVATE_LISTENING_TESTING.md). Optional read-only diagnostics require an explicit isolated preview target and do not activate listening.
