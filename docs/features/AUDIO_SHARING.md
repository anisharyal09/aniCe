<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Describes the setup, output choices and constraints for local audio in both directions. -->
# Audio Sharing

Audio Sharing is **Experimental**. Send Mac system audio to Android or share
eligible phone media and game audio to your Mac over an encrypted local
connection. Requires trusted devices, macOS 14.2+ and Android 10+.

## Connect the devices

Join the same network and open **Features → Audio Sharing** on both devices.
With Bluetooth connected and **Use local network automatically** enabled on
both, aniCe requests the local connection. Otherwise, choose **Allow
local-network connections** on the Mac, then **Connect local network** on
Android. Use **Open Devices** to pair, select a device or resume a paused
connection. Start audio separately.

## Mac → Android

1. On Android, **Allow audio from this Mac** and **Use phone speaker when headphones are unavailable** default to on for trusted Macs. Saved choices still apply.
2. Connect headphones or use the phone speaker. For some Bluetooth and USB outputs, use **Refresh audio outputs** and **These are my headphones**. Outputs Android cannot identify cannot be confirmed by name alone.
3. On the Mac, choose **Prepare system audio…** and grant system audio recording access if prompted. Then choose **Start listening**. The Mac can suppress its output only after Android has verified the output route.

If an active file transfer delays startup, wait for it to clear. If Android
blocks startup in the background, open aniCe on the phone and try again.

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

## Android → Mac: Phone Audio

1. On the Mac, enable **Allow audio from this phone**. This choice is off by default and scoped to both current device identities.
2. On Android, choose **Share phone audio** and approve Android’s screen-capture prompt. The Android app uses the permission for audio only; it sends no screen pixels or video.
3. Play media in an app that allows playback capture. Use **Stop phone audio** on either device or in the Android notification.

- Adjust media volume on your phone and output volume on your Mac. The phone’s media volume can also affect the audio sent to your Mac.
- **Calls, the microphone and protected or opted-out apps are excluded.** If Android reports call mode, the phone shows that call audio is excluded. A call can also pause or duck the media app.
- **If audio stutters:** Phone audio can still cut out when switching apps or
  leaving aniCe in the background. Try keeping aniCe open on the phone or
  pausing large file transfers.
- Start sharing again after changing the Mac output device or reconnecting to
  the local network. Android asks for capture consent each time.

## Interruptions

Only one direction can run at a time. Temporary loss of audio focus can
pause Mac-to-phone playback for up to 90 seconds. Either direction may pause
briefly during **Renewing secure LAN…** and resume with current audio. If the
connection drops or the Mac sleeps, start again. No audio is saved.

See the [protocol](../../protocol/audio-sharing/README.md) and
[performance notes](../PERFORMANCE.md) for technical details.
