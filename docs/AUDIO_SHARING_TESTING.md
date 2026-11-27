<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Separates manual physical checks, read-only snapshots and explicitly authorized assisted preview runs. -->
# Audio Sharing physical checks

Use the isolated Transfer Previews on the Mac and phone, secured LAN and headphones connected to Android. Keep production apps separate. The checklist below uses manual Start/Stop and receiving consent; explicitly authorized assisted runs are described separately. At low volume, check each mode with the same source, network and headphones; Bluetooth adds downstream delay not captured by the app's backlog.

## Compare modes and interruptions

Speaker fallback is audible and can be disabled separately from receiving.
Check that headphone loss still stops with fallback off. With it enabled,
test Start without headphones and headphone loss during a stream. Audio should
resume only after silent route verification, and the panel and notification
should show that the phone speaker is in use. Test disabling fallback during playback,
unknown external-route rejection, focus interruption and notification Stop.
Record phone-speaker delay separately from Bluetooth; neither local backlog nor
removing Bluetooth proves imperceptible delay. Turn fallback off for
headphones-only checks.

1. Record phone model/OS, headphone model, buffering mode and app build/commit.
2. Listen foreground for two minutes; screenshot app backlog/target, underruns, gap recoveries and rebuffer counts.
3. Leave the app in the background for five minutes, then test screen-off for five minutes. Record audible gaps separately from the time the UI reports buffering.
4. Navigate between app panels and return from another app. Note whether brief navigation produces repeated silent preparations.
5. Send a large file in each direction; note actual file throughput before/during listening and verify file integrity. PHY link rates are not file speed.
6. Repeat with Balanced and Lower delay, stopping before switching mode.
7. With fallback off, verify headphone disconnect stops playback, transient focus re-verifies routing, and notification Stop works.
8. Stop from each platform while a source is still playing: Mac normal output should return, and cleanup should not claim success before completion. A source can become audible on Mac; seamless Bluetooth-to-Mac synchronization is not guaranteed.
9. In a longer session, check retained-channel LAN renewal resumes current audio without replay or a new Start.

Smaller buffers trade jitter reserve for delay. Neither a 20-ms target nor a platform-reported native buffer proves 20-ms source-to-ear latency. Report measured or perceived delay honestly, including the method and any downstream headphone buffering.

Keep a separate row for each mode and condition. Do not label a brief Buffering message as an audible gap unless you heard one.

| Mode | Condition | Audible gaps | App underrun/rebuffer change | Local backlog/target | File speed before/during |
| --- | --- | --- | --- | --- | --- |
| Balanced / Lower delay | Foreground / background / screen-off / navigation / transfer | Count and rough times, or not checked | Before → after, or unavailable | Frames or app-reported ms | Measured MB/s or MiB/s, or not checked |

For the HAVIT 360BT Bluetooth path, record its measured/perceived delay separately from the app backlog. If no wired/USB output is available, leave that comparison not checked; do not infer its performance. Verify receiving file bytes with a digest or equivalent integrity check, not only the progress UI.

## Physical test observations

Preview feedback from November 24, 2026, came from a Samsung Galaxy A34
(`SM-A346E`). Source apps, buffering mode, run duration and playback counters
were not recorded.

| Direction | Observation |
| --- | --- |
| Phone → Mac | Audio played on both devices with some delay. Crackling and stutter began in Recents, before returning to Home, and continued in the background. |
| Mac → phone | The built-in speaker sounded closer to lip sync than the HAVIT 360BT Bluetooth headphones. Delay was less noticeable when playing audio directly on the phone through those headphones. |

End-to-end latency was not measured, and the cause of the phone-to-Mac stutter
has not been confirmed.

### Phone-to-Mac timing sample

In a 331-second preview run on the Galaxy A34, Android captured 15,984 packets,
submitted 14,836 and dropped 1,148 (7.2%) while waiting to send. Sender wake-up
delay peaked at 8 ms; some capture reads and send submissions took multiple
seconds. The run had no Mac counters or timeline of app and output changes.
For a repeat run, collect [timing on both devices](#opt-in-reverse-path-timing-evidence)
and note when you enter Recents and hear gaps.

## Reverse Phone Audio (Android → Mac)

Reverse streaming is exposed behind explicit local consent. On the Mac, enable
"Allow audio from this phone"; on the phone, open Audio Sharing, choose
"Share phone audio" and approve the system screen-capture prompt. The
projection grant is single-use and is never saved. Verify:

- [ ] A source app that permits capture plays on the Mac and keeps playing on the phone.
- [ ] An opted-out/protected app yields silence without a crash or error loop.
- [ ] Call/microphone audio never appears in the captured stream; valid silence alone does not prove source capture policy.
- [ ] Revoking projection from the system UI stops locally and never auto-restarts.
- [ ] Stop, service kill, Mac sleep and Mac Quit release the projection and native output.
- [ ] Background, screen-off and Doze either retain the user-authorized operation under native policy or stop honestly; they never reuse a revoked projection.
- [ ] Bluetooth/A2DP changes do not disturb capture; Mac output re-prepare is required after a device change.
- [ ] Actual Wi-Fi/LAN loss stops both ends; reconnect never auto-restarts capture.
- [ ] Retained-channel renewal keeps the authorized operation and resumes only current audio without replay.
- [ ] Reverse Start is rejected while Mac-to-phone listening is active, and vice versa.
- [ ] Start without Mac receiving consent is refused, and disabling consent stops an active stream.
- [ ] A second phone Start while one stream is live is refused without replacing the bound stream.
- [ ] Cancelled consent, rotation/view disposal and LAN replacement cannot retarget a late projection grant.
- [ ] Rapid Stop/Start and notification Stop leave no orphaned service/record or reused stream.
- [ ] Queue overflow is reported as local drops/resyncs, not as measured latency.
- [ ] A concurrent transfer records audio drop rate and transfer deadline honestly.
- [ ] A 60-minute run keeps memory flat and leaves no orphaned native record.

Do not claim private output or source muting: Android playback capture does not
silence the phone, and Mac speakers are not private.

### Automated coverage

Controller/receiver fakes cover single-use and channel-bound consent, default-off
credential-scoped Mac preferences, early/late Ready, native preparation retirement,
bounded PCM and coalesced worker delivery, control-message backpressure, Stop,
output loss, sleep, replay fencing, mutual exclusion and retained-channel renewal.
The host Android gate also compiles instrumentation and checks the manifest with
lint; the Mac gate builds Release and runs hosted tests. These checks do not prove
the physical capture prompt, audio audibility, route changes, Doze, output-device
behaviour or end-to-end delay.

Audio-free UI regressions check compact action sizing, whole-row preference
activation, active Stop visibility, narrow-width reflow and both themes at
80%–120% text scale. Android runs only in the isolated listening UI emulator
package; Mac uses capture/output fakes. Native screen-capture permission and
physical audio remain separate acceptance checks.

The observations above cover only part of the physical checklist. Assisted
checks can inspect preview service/projection ownership, Stop/revocation, and
queue and memory counters after explicit authorization. The user must approve
native prompts and judge audibility. The host gates do not deploy apps, change
permissions or trust, start playback, or send test files.

## Optional read-only snapshots

While manually testing, run this from the repository root with an explicit phone serial:

```sh
python3 scripts/check-listening-health.py \
  --serial PHONE_SERIAL --stage background --mode balanced \
  --samples 30 --interval 10 \
  --output build/listening-health-background.json
```

Use a new filename for each run; existing files and symlinks are rejected, and a new report is owner-readable/writable only. Stages and the optional buffering mode are your labels, not automatic classification. Use `foreground`, `background`, `screen-off` or `transfer`; use `balanced` or `lower-delay` for `--mode`. Default sampling is one snapshot; repeated sampling is opt-in and bounded. The interval is 5–60 seconds, with at least five seconds of rest after slow queries. Each query has a fifteen-second deadline and bounded output; query failures retain a fixed status, not raw error text.

The script rechecks the exact isolated Android Transfer Preview package and UID before each snapshot. It saves filtered current audio focus/player state, CPU ticks when readable, device wakefulness and numeric Wi-Fi signal/link fields. An unavailable PID query means unknown, not proof that playback stopped. CPU accounting verifies the process owner UID; deltas require the same PID and process-start time, and use the process query's own observation times.

Add `--native-tracks` only when native buffer/counter evidence is needed. This opts into the heavier AudioFlinger dump and retains only current app-owned track rows, numeric track IDs and recognized named buffer/counter fields. Known normal/static/patch and fast-track prefixes are recognized; numeric buffer/counter decorations are stripped only for documented native markers. History rows, other apps and unsupported column layouts are ignored. Native counter deltas require a surviving track in the same process; vendor-reported underruns are not assumed to equal AudioTrack's app counter. App-owned tracks may include other preview sounds, so stream attribution is not inferred.

The tool does not install, launch or stop apps, reset/grant permissions, alter network/routing/power settings, open capture or start playback. It saves no audio, playback titles, SSIDs, MAC/IP addresses, keys, peer credentials or device serial. Do not upload raw system dumps; review even filtered reports before sharing.

Queries themselves can perturb scheduling. Restricted `/proc` or unsupported/vendor-specific fields are unavailable, not invented zeros. CPU ticks are not CPU percentage without a verified time-base conversion. Native buffer capacity is not total headphone latency; correlate counters with the app's screenshots and your audible-gap notes. If interrupted or if the selected preview changes/becomes unavailable, the partial report remains readable with `complete: false`. Even `complete: true` means sampling finished, not that playback passed acceptance.

This tool cannot prove speaker privacy, physical audibility, source-to-ear delay or file throughput. See the [Audio Sharing guide](features/AUDIO_SHARING.md) and [performance limits](PERFORMANCE.md).

## Opt-in reverse-path timing evidence

Android-to-Mac Phone Audio can emit bounded local timing counters without
recording audio. Both platforms require an explicit opt-in and the exact Transfer
Preview identity; ordinary and production builds emit nothing.

On Android, set the preview's diagnostic log tag before the process starts:

```sh
adb -s PHONE_SERIAL shell setprop log.tag.aniCePhoneAudioDiag DEBUG
adb -s PHONE_SERIAL shell am force-stop io.github.anisharyal09.anice.preview.transfer
adb -s PHONE_SERIAL logcat -c
adb -s PHONE_SERIAL logcat -s aniCePhoneAudioDiag:D > build/reverse-android.log
```

On the Mac, launch the preview with `ANICE_PHONE_AUDIO_DIAGNOSTICS=1` and collect
its unified log by the fixed prefix:

```sh
/usr/bin/log stream --predicate 'eventMessage CONTAINS "phone_audio_diag "' > build/reverse-mac.log
```

Use the absolute `/usr/bin/log`: zsh's `log` builtin shadows it in some shells.

Start capture before beginning the operation; both collection commands run until you
stop them with Ctrl-C, so start them before the phone operation and stop them after
Stop. An operation emits at most one
report per second, at most 600 reports, and no further reports after ten minutes,
plus one terminal report at Stop. Unknown rows and oversized inputs are rejected
rather than repaired. Summarize both logs into a new file; existing files and
symlinks are refused and the result is owner-readable only:

```sh
python3 scripts/summarize-phone-audio.py \
  --android-log build/reverse-android.log --mac-log build/reverse-mac.log \
  --output build/reverse-timing.json
```

The summary keeps only allowlisted counters, booleans and local maxima: Android
read time, capture interval, sender wake-up wait, queue age, encode and
submission; Mac arrival interval, receiver admission, sequence gaps and native
output backlog/resync/completion counters. It drops source titles, peer or stream
identifiers, addresses and raw lines. Each sample carries per-window maxima and
counter deltas, so a report alone does not identify the phase; pair it with your
own notes for foreground, Recents, Home and screen-off.

These are local observations, not a diagnosis. Phone and Mac clocks are not
synchronized, so arrival intervals cannot be subtracted from capture intervals.
Submission completion is not authenticated remote delivery, and Mac empty-queue
transitions and resyncs are not directly measured audible gaps. Reverse capture/output scheduling improvements (`THREAD_PRIORITY_AUDIO` capture worker, off-Main `Dispatchers.IO.limitedParallelism(1)` send queue, synchronous Mac buffer completion accounting, 3-packet prefill cushion and 5 ms boundary ramps) keep the existing counters intact and still require physical listening checks for acceptance. Diagnostics themselves can perturb scheduling, and
these counters never establish acceptance or measured source-to-ear delay.

## Non-playback device regressions

`AudioSharingDeviceRegressionTests` requires the explicitly selected Android
Transfer Preview. It checks the installed non-exported mediaPlayback declaration,
the accepted native audio-worker priority and worker shutdown, the static native
PCM minimum-buffer query, and controller credential/replay/Stop fencing through
in-memory fakes. It creates no AudioTrack, requests no audio focus, starts no
listening service and changes no saved consent or headphone confirmation.
These are on-device implementation checks, not physical playback acceptance.

Build instrumentation with `-PaniceTransferPreview=true` and verify its target
package before installation. Invoke only the selected class; the ordinary full
connected suite targets the normal app by default and includes state-changing
fixtures. Instrumentation restarts the preview process, so Stop real listening
before running it. Never replace an unrelated production installation to run
these checks.

## Explicit assisted physical runs

`PhysicalAudioSharingTest` is Debug instrumentation, gated by the exact
Transfer Preview package and a canonical UUID supplied as
`physicalPrivateListening`. Its preparation check opens a real AudioTrack with
existing confirmed headphones and granted audio focus, but writes silence only.
Its coordinated listening check uses the real application service, existing
credential-scoped consent and authenticated LAN. Native state, backlog,
underruns and file throughput are numeric evidence, not measured audibility.
Opt-in lifecycle commands can request real transient AudioManager focus and send
the current preview notification's immutable Stop PendingIntent; they do not
simulate focus callbacks or forge service tickets.
The coordinated test restores its launch-time buffering mode, or the explicitly
supplied `physicalRestoreBufferProfile` (`balanced` or `lower-delay`) when a
maintainer is restoring the mode recorded before a multi-run comparison.
Foreground windows use a temporary keep-screen-on flag; explicit background
stages clear it rather than silently counting screen-off as foreground.

Mac's `AudioSharingPhysicalRunner` exists only with both `DEBUG` and
`ANICE_TRANSFER_PREVIEW`; it remains inactive unless explicitly launched with
`ANICE_PRIVATE_LISTENING_PHYSICAL=<canonical UUID>`. Its per-run local directory
under the isolated preview support directory accepts bounded prepare/start/stop,
snapshot, connect and synthetic-file actions through the existing feature owners.
It adds no wire protocol, ignores ordinary builds and does not enable consent,
change headphone authorization or bypass native capture permission. Commands and
reports are local-only and a run has a 75-minute ceiling.

Run these only after explicit user authorization to activate real audio and
test-file sends. Instrumentation restarts the isolated phone preview. Review
and approve any native permission prompt manually; these fixtures never grant
permissions, reset identity/trust, switch Android user/work profiles or modify production data.
Use a fresh UUID each selected physical test; an existing run directory is
rejected so stale commands or reports cannot satisfy readiness or success.
Hash received synthetic test files independently, and retain failed setup or
timeout evidence instead of counting a later run as repairing earlier results.
