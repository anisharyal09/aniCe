<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Describes the standalone native HFP probe, its operation and audio-exposure limits. -->
# Call-audio feasibility probe

`CallAudioProbe` is a standalone macOS diagnostic for a system-paired phone's
Bluetooth Classic Hands-Free Profile (HFP). The Mac acts as the Hands-Free unit
(HF); the phone acts as the Audio Gateway (AG). It uses
`IOBluetoothHandsFreeDevice` for service connection, call indicators and audio
transfer. It does not enter the aniCe application target or change production
permissions.

The probe checks native SCO connection and CoreAudio buffer availability. It does
not route speech between the phone and the Mac's built-in microphone or speakers.
A successful probe result alone does not complete Gate 1 for full calling.

## Build

On an Apple silicon Mac with the macOS SDK installed:

```sh
python3 scripts/build-call-audio-probe.py
```

The build targets arm64 macOS 14 or later and creates an ad-hoc-signed bundle at
`build/CallAudioProbe.app`, with Bluetooth and microphone usage descriptions and
an audio-input entitlement. The launcher preserves terminal input and output:

```sh
./build/run-call-audio-probe.sh --help
```

The builder's `--dry-run` prints compilation and signing commands while still
writing bundle metadata and the launcher. `--no-sign` skips signing; an unsigned
run cannot establish that microphone permission is configured correctly.

## Run

Pair the phone in **System Settings → Bluetooth**, then list its Classic address:

```sh
./build/run-call-audio-probe.sh --list-devices
```

Use the phone's address in place of the example below. The probe selects only
system-paired devices; it does not pair devices itself.

```sh
./build/run-call-audio-probe.sh \
  --device AA:BB:CC:DD:EE:FF \
  --interactive --request-mic --wait 120 \
  --log build/call-probe.log \
  --json build/call-probe.json
```

Grant microphone access when requested. Without `--request-mic`, the probe reads
permission state without prompting. Missing or denied permission produces an
inconclusive buffer check. Access can also be managed in **System Settings →
Privacy & Security → Microphone**.

After the native service connection completes, place or receive a real call.
Interactive commands are `answer`, `dial NUMBER`, `hangup`, `snapshot`, `status`
and `quit`. Commands and native callback state are confined to the main actor;
stdin reading runs separately. Answer logs receipt, native call state and command
submission. Submission is not an acknowledgement from the phone, and an active-call
indicator alone does not prove which device answered.

`--dial NUMBER` requests an outgoing call at startup. `--answer` waits up to ten
seconds for a ringing indicator and submits Answer if one arrives. `--wait`
controls the subsequent active-call wait, defaults to 45 seconds and accepts values
up to 600 seconds.

### Audio setup modes

By default, the probe requests native `transferAudioToComputer` once a call is
active. It keeps a 30-second routing window open even if that request reports an
error. During this window, select the Mac in the phone's in-call audio picker.

Add `--phone-audio-only` to wait for phone-initiated SCO without an explicit Mac
`transferAudioToComputer` or `connectSCO` request during setup. This mode retains
the native implementation's feature advertisement and codec handling. It does not
implement additional `AT+BAC`, `AT+BCC` or `AT+BCS` transactions. Cleanup still
requests transfer back to the phone and disconnects SCO.

After SCO is confirmed, the probe waits up to ten seconds for endpoint discovery.
It associates an endpoint only when its CoreAudio transport is Bluetooth Classic
and its UID contains the selected phone's complete address. Device names, a newly
appearing endpoint and unrelated headset audio are insufficient. UID formats that
do not expose the address remain inconclusive.

## Results

| Result | Meaning |
| :--- | :--- |
| `PASS` | Active call and native SCO confirmed; a phone-associated endpoint has both stream directions and delivers valid nonempty input and safely zero-filled output buffers. |
| `FAIL` | A phone-associated endpoint lacks a required stream direction or fails the buffer check. |
| `UNKNOWN` | Audio setup, endpoint association, permission, buffer checking or SCO release is incomplete. |

The buffer check discards input and writes silence. It does not demonstrate
intelligible two-way speech. `--no-audio-test` and `--skip-mic-test` skip the buffer
check and cannot produce audio-exposure acceptance.

The transcript includes paired-device selection, asynchronous SDP results, native
HF/AG feature masks, call/SCO state, CoreAudio inventories, stream formats and the
result table. JSON includes snapshots, results and `audioSetupMode` when the run
reaches audio evaluation. The AG codec-negotiation feature bit describes capability;
the probe does not verify the negotiated codec.

Cleanup requests phone audio routing, waits up to five seconds for SCO release and
closes the native client. A disconnected SCO link does not establish audible
handback; phone audio must be checked separately.

| Exit code | Meaning |
| :--- | :--- |
| `0` | Audio-exposure check passed and SCO release was confirmed. |
| `2` | Invalid arguments. |
| `3` | Phone address rejected, device absent or device not paired. |
| `4` | Hands-Free setup or service connection failed. |
| `5` | No active call reached the probe. |
| `6` | Phone-associated endpoint failed the stream/buffer check. |
| `7` | Inconclusive setup, association, permission, skipped check or audio release. |

## Interpretation and scope

`kIOReturnUnsupported` (`-536870201`, `0xE00002C7`) describes a native operation's
result. `HOST_REJ_RESOURCES` describes host-side SCO rejection. Neither identifies
the underlying cause or establishes a universal macOS prohibition. Without
confirmed SCO, an absent CoreAudio endpoint cannot establish an endpoint-exposure
limitation. A headset connected to the Mac exercises the opposite HFP role and
cannot validate phone call audio.

Full calling requires a separate duplex speech bridge, echo handling, mute,
phone-audio handback and disconnect recovery. Caller ID, reject, hang-up, DTMF and
hold require their own implementation and physical checks. An external Linux/USB
bridge is a possible experiment, not an implemented or validated transport.

## ADB-assisted alternative

The separate [ADB call-audio experiment](CALL_AUDIO_ADB.md) captures phone downlink
and injects Mac microphone audio through Android shell audio policy. It does not
require a Mac HFP endpoint and does not change this native probe's result semantics.

## Source and regression checks

Sources live in `apps/macos/CallAudioProbe/`:

| File | Responsibility |
| :--- | :--- |
| `main.swift` | Process entry and exit reporting. |
| `ProbeRun.swift` | Commands, snapshots, endpoint evaluation and JSON results. |
| `HFPProbe.swift` | Paired-device selection, SDP, native HFP state and audio release. |
| `ProbeDiagnostics.swift` | Logging, CoreAudio enumeration and synchronized buffer statistics. |
| `ProbeTypes.swift` | Snapshot types, address matching, CLI options and exit codes. |
| `ProbeMicrophone.swift` | Microphone authorization and permission guidance. |

Run isolated regressions without a phone or microphone access:

```sh
python3 scripts/test_call_audio_probe.py
```

The fixtures cover address association, unrelated headsets, permission and skipped
checks, invalid buffers and silent output initialization. Native HFP behavior and
physical speech are outside those fixtures.
