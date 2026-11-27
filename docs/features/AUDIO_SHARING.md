<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Describes the setup, output choices and constraints for local audio in both directions. -->
# Audio Sharing

Audio Sharing is **Experimental**. Send Mac system audio to Android or share
eligible phone audio from media and games to your Mac. Audio travels over an
encrypted local connection between trusted devices, one direction at a time.

## Connect the devices

Open **Features → Audio Sharing** on both devices and join the same local network. With secured Bluetooth and **Use local network automatically** enabled on both ends, opening the feature requests the local connection. Otherwise choose **Allow local-network connections** on the Mac, then **Connect local network** on Android. Use **Open Devices** to choose a peer, pair, or resume a paused connection. Connecting never starts audio.

## Mac → Android

1. On Android, **Allow audio from this Mac** and **Use phone speaker when headphones are unavailable** default to on for trusted Macs. Saved choices still apply.
2. Connect headphones or use the phone speaker. For some Bluetooth and USB outputs, use **Refresh audio outputs** and **These are my headphones**. Outputs Android cannot identify cannot be confirmed by name alone.
3. On the Mac, choose **Prepare system audio…** and grant system audio recording access if prompted. Then choose **Start listening**. The Mac can suppress its output only after Android has verified the output route.

Start requires an already-secured LAN connection; it does not override Disconnect or connection Pause. An existing transfer may need to reduce outstanding bytes before Start. Android startup without a visible activity requires eligible native companion ownership; a rejected background start reports that aniCe must be opened on the phone.

Transfer-drain admission counts only a currently owned outgoing file. Historical
sent/acknowledged counters from a completed, cancelled or dismissed transfer do
not block a new listening operation; live outgoing files retain the same bound.

The Mac minimum is macOS 14.2. Android retains API 29 and later. Native low-latency playback is requested but normal AudioTrack playback remains usable. System-audio capture is governed by macOS permission and source behavior; silent buffers alone do not distinguish a paused source, mute, protected audio or denied capture.

## Volume and privacy

**Also play through Mac speakers** is off by default. Turn it on to hear the
audio on both devices. Use the phone's media volume to adjust playback on
Android; it doesn't change the Mac's output volume.

Android prefers approved headphones. Some Bluetooth and USB devices need
confirmation. If headphones are unavailable or disconnect, Android can switch
to its built-in speaker after checking the new output. The app and notification
show when the phone speaker is in use. With fallback off, disconnecting
headphones stops playback. Turning fallback off during playback also stops it.
When you re-enable fallback, aniCe asks you to confirm that audio can play aloud.

Choose **Stop listening** in the feature panel, phone notification or active
Mac companion row. Normal Mac output returns, so any source that's still
playing may become audible on the Mac.

## Delay and buffering

Before sending Mac audio to Android, open **Show playback options** on Android
to choose a buffering mode:

- **Balanced** (default): starts at a 120 ms buffer target and adapts within 60–240 ms.
- **Lower delay**: starts at 40 ms and adapts within 20–160 ms. It can stutter
  more when audio arrives unevenly.

The target rises when audio arrives late or playback runs out, then falls
gradually as playback stabilizes. Android or the output device can require a
larger buffer. The values in Playback options show local buffering, not the
total time it takes to hear the audio.

Bluetooth headphones can add delay. Try the phone speaker or wired/USB
headphones if video and audio fall out of sync.

## Interruptions and renewal

Transient focus loss pauses/flushes phone playback for at most 90 seconds; Mac capture continues reading/discarding with the chosen mute behavior. Focus return silently re-primes and verifies routing before current audio resumes. Permanent focus loss ends listening. Headphone loss ends listening unless the separately enabled speaker fallback can be silently verified.

Silent priming accounts for delayed native playback-head resets and route-driven startup-threshold changes. A raised threshold tops up only its missing pending silent reservation, including when earlier silence has already drained. It retains the original preparation deadline and never opens audible writes before route verification.

Underflow produces local silence and bounded rebuffering on the same stream. Software queues retain a bounded newest-received window instead of replaying missed seconds. An isolated source gap resets interpolation and ramps the next current packet over 5 ms, without reopening route authorization or repeating silent preparation. Authenticated Audio admission and playback scheduling do not wait for UI rendering. Focus/maintenance recovery still requires silent route verification.

Already-submitted TCP bytes remain ordered; receiver trimming cannot retract them. Listening starts with future transfer chunks up to 64 KiB and 128 KiB of unacknowledged file credit. Fresh advancing playback health with no new underruns gradually permits up to 128-KiB chunks and 1 MiB of credit, always within the peer's negotiated chunk count/window and existing LAN qualification. Buffering, stale health or new underruns return to the initial small budget; already-submitted data drains normally. Transfer data is never discarded to make room for audio. This policy can still reduce file throughput on a congested path; it is not a guarantee of simultaneous maximum transfer speed and low audio latency.

Negotiated LAN renewal uses the existing channel maintenance interval. TCP, the feature-channel descriptor and listening stream remain intact while fresh EDHOC/readiness replace cryptographic keys. Mac keeps reading/discarding; Android keeps native service ownership and rechecks focus/routing afterward. **Renewing secure LAN…** distinguishes that bounded interruption from normal playback. Native phase/security deadlines are not extended.

Channel retirement, Disconnect, trust/identity changes, service destruction, Mac sleep or Quit invalidate listening. A new connection does not restart it automatically or replay audio. CPU/Wi-Fi locks are native playback resources, not permission to reconnect or proof of screen-off radio latency; Android 34+ low-latency Wi-Fi locks retain platform restrictions.

## Android → Mac: Phone Audio

1. On the Mac, enable **Allow audio from this phone**. This choice is off by default and scoped to both current device identities.
2. On Android, choose **Share phone audio** and approve Android’s screen-capture prompt. The Android app uses the permission for audio only; it sends no screen pixels or video.
3. Play media in an app that allows playback capture. Use **Stop phone audio** on either device or in the Android notification.

- Adjust media volume on your phone and output volume on your Mac. The phone’s media volume can also affect the audio sent to your Mac.
- **Calls, the microphone and protected or opted-out apps are excluded.** If Android reports call mode, the phone shows that call audio is excluded. A call can also pause or duck the media app.
- **If audio stutters:** Keep aniCe open on the phone. Stutter was observed when
  switching apps or leaving aniCe in the background. If it continues, try
  another capture-eligible media app or pause large file transfers.
- Start sharing again after changing the Mac output device or reconnecting to
  the local network. Android asks for capture consent each time.

## Implementation boundaries

[Phone Audio v1](../../protocol/audio-sharing/PHONE_AUDIO.md) uses a
`mediaProjection` foreground service and single-use consent bound to the current
local action and channel. Cancellation, view disposal, channel replacement and
Stop discard pending consent. Android’s native service and projection policies
govern background use. Retained-socket renewal clears stale audio and rechecks
capture and output availability before resuming.

Audio uses bounded 48-kHz stereo PCM16 buffers in memory. Connections owns
encrypted record admission and renewal; the feature owners control capture,
playback and user consent. No audio is saved.

See the [Mac-to-Android audio contract](../../protocol/audio-sharing/README.md), [LAN maintenance](../../protocol/lan/RENEWAL.md), [Now Playing](NOW_PLAYING.md), [performance budgets](../PERFORMANCE.md) and the [physical-test guide](../AUDIO_SHARING_TESTING.md). Optional read-only diagnostics require an explicit isolated preview target and do not activate listening.
