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

The Mac minimum is macOS 14.2. Android retains API 29 and later. Native low-latency playback is requested but normal AudioTrack playback remains usable. System-audio capture is governed by macOS permission and source behavior; silent buffers alone do not distinguish a paused source, mute, protected audio or denied capture.

## Volume and privacy

**Also play through Mac speakers** defaults off. While off, `.mutedWhenTapped` suppresses tapped-process output only while the tap reader remains active. Turning it on deliberately allows normal Mac output alongside Android playback. No system default output is changed.

Phone hardware volume buttons and the active media session control local phone/headphone media volume during listening ownership, including preparation, pauses and LAN maintenance. Previously queued remote Mac-volume callbacks are invalidated. Player transport commands remain scoped to current Mac playback capabilities.

Android approves explicitly identified wired headphones/headsets, USB headsets and BLE headsets. A2DP and generic USB are ambiguous and require confirmation. An actual speaker/unknown route is not approved by its product name. Routing changes and becoming-noisy events stop playback rather than intentionally falling back to phone speakers; asynchronous OS routing still governs what happens before notification delivery.

**Stop listening** is available in the feature panel, phone notification and active Mac companion row. Terminal cleanup restores normal Mac output. A still-playing source can become audible on Mac; the feature is not a crash-proof mute latch. No audio history, saved recording or offline queue is created.

## Delay and buffering

Choose a buffering mode on Android before starting:

- **Balanced** is the default: initially 200 ms of app-managed audio, adapting within 160–320 ms.
- **Lower delay** is opt-in: initially 80 ms, adapting within 80–160 ms. A busy connection or scheduler can cause more interruptions.

Late packet arrival and new native underruns raise the local target; sustained healthy playback lowers it slowly. The target includes software audio and pending AudioTrack writes once. The worker requests a smaller effective native buffer and startup threshold where Android permits, without assuming that the platform accepted those requests. Older Android versions and some outputs retain a larger native startup floor. Audio memory remains bounded to 800 ms in either mode; this is a ceiling, not a latency goal.

The panel shows current app backlog, target, pending AudioTrack audio (included in the backlog), skipped packets and native underruns. These are local diagnostics, **not measured end-to-end latency**. Bluetooth encoding, OS mixing and headphone buffering can add substantial delay beyond them; wired/USB headphones usually reduce that contribution. Neither mode guarantees video lip-sync. aniCe cannot remove downstream Bluetooth delay or delay video in an arbitrary Mac browser.

For a useful comparison, replay the same source on the same LAN with Balanced and Lower delay, then compare with wired/USB headphones if available. Note both perceived delay and interruptions; also check screen-off playback and transfer coexistence. Switch modes only after stopping, and keep headphone-route/privacy checks unchanged.

## Interruptions and renewal

Transient focus loss pauses/flushes phone playback for at most 90 seconds; Mac capture continues reading/discarding with the chosen mute behavior. Focus return silently re-primes and verifies routing before current audio resumes. Permanent focus loss and headphone route loss end listening.

Underflow produces local silence and bounded rebuffering on the same stream. Software queues retain a bounded newest-received window instead of replaying missed seconds. Already-submitted TCP bytes remain ordered; receiver trimming cannot retract them. Listening ownership paces future file-transfer chunks to 64 KiB and outstanding unacknowledged file data to 128 KiB within negotiated credit. Transfer data is never discarded to make room for audio.

Negotiated LAN renewal uses the existing channel maintenance interval. TCP, the feature-channel descriptor and listening stream remain intact while fresh EDHOC/readiness replace cryptographic keys. Mac keeps reading/discarding; Android keeps native service ownership and rechecks focus/routing afterward. **Renewing secure LAN…** distinguishes that bounded interruption from normal playback. Native phase/security deadlines are not extended.

Channel retirement, Disconnect, trust/identity changes, service destruction, Mac sleep or Quit invalidate listening. A new connection does not restart it automatically or replay audio. CPU/Wi-Fi locks are native playback resources, not permission to reconnect or proof of screen-off radio latency; Android 34+ low-latency Wi-Fi locks retain platform restrictions.

## Implementation boundaries

Application-scoped feature owners handle DATA, service/capture lifecycle and bounded logical audio queues. Connections owns LAN admission, encrypted records and renewal. The Mac C callback copies Float32 into a lock-free SPSC ring; conversion and sealing stay off that callback. Android's worker performs bounded cubic clock correction without native pitch-preserving timestretching.

See [wire contract](../../protocol/private-listening/README.md), [LAN maintenance](../../protocol/lan/RENEWAL.md), [Now Playing](NOW_PLAYING.md) and [performance budgets](../PERFORMANCE.md).
