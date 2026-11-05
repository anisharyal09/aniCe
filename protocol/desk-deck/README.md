# Mac Desk Deck v1 and v2

Mac Desk Deck carries a foreground Android control panel's hardware snapshot and explicit Mac actions in existing authenticated DATA. It adds no pairing, transport, or background connection lease. V1 remains supported for older peers. V2 adds richer memory and power readings, renewable foreground subscriptions, and a Mac-approved app catalog. Records stay within the session's 4,000-byte plaintext limit; v1 envelopes are at most 512 bytes and v2 envelopes at most 3,800 bytes.

The Mac advertises capability when a secured channel becomes available. Android opens the panel immediately, then subscribes with a fresh random UUID. The Mac sends an immediate snapshot; CPU is `-1` until a second Mach counter reading establishes a baseline. Samples are produced at most once per second. Android renews a v2 subscription every five seconds; the Mac stops sampling after fifteen seconds without renewal. Stop, backgrounding, channel retirement, or trust change ends the local subscription. Commands are never replayed after a channel or subscription change.

## Envelope and messages

The deterministic CBOR envelope is `["aniCe desk deck", version, kind, fields]`.

| Kind | Direction | Version | Fields |
| --- | --- | --- | --- |
| 1 capability | Mac → Android | 1 or 2 | `[actionMask]` |
| 2 subscribe | Android → Mac | 1 or 2 | `[subscription]` |
| 3 sample | Mac → Android | 1 | See `v1-sample` in CDDL |
| 3 sample | Mac → Android | 2 | `[subscription, sequence, cpuPercent, activeBytes, wiredBytes, compressedBytes, physicalBytes, thermalState, actionMask, outputSupported, outputTarget, outputRevision, outputLevel, microphoneSupported, microphoneTarget, microphoneRevision, microphoneMuted, powerState, powerPercent, powerSource]` |
| 4 command | Android → Mac | 1 or 2 | `[subscription, commandID, action, target, revision, value]` |
| 5 result | Mac → Android | 1 or 2 | `[subscription, commandID, result]` |
| 6 stop | Android → Mac | 1 or 2 | `[subscription]` |
| 7 renew | Android → Mac | 2 | `[subscription]` |
| 8 catalog request | Android → Mac | 2 | `[subscription, page]` |
| 9 catalog page | Mac → Android | 2 | `[subscription, page, pageCount, catalogRevision, [[shortcutID, name]…]]` |
| 10 catalog changed | Mac → Android | 2 | `[subscription, catalogRevision]` |

Each v2 catalog page has at most eight entries. A catalog has at most 32 apps and four pages. Names are nonempty, control-free UTF-8 text no longer than 80 UTF-16 code units. IDs and revisions are canonical lowercase UUIDs. After an approval changes, the Mac sends kind 10 with the new revision. Android discards partial pages and requests page zero for that revision; pages from a different revision are ignored. A command using a previous revision cannot launch a revoked entry.

## Samples and power values

`cpuPercent` is `-1` when the first or native CPU sample is unavailable; otherwise it is `0..100`. V1 memory is used physical-memory bytes and total. V2 reports active, wired, compressed and total physical-memory bytes; the first three values cannot sum above total. `thermalState` is the macOS thermal-pressure state: nominal `0`, fair `1`, serious `2`, critical `3`. It is not a temperature reading.

V2 `powerState` values are unavailable `0`, no battery `1`, on battery `2`, charging `3`, fully charged `4`, and plugged in but not charging `5`. `powerPercent` is `-1` when unavailable or no battery is present; otherwise it is `0..100`. `powerSource` is unavailable `0`, battery `1`, AC `2`, or UPS `3`.

Unsupported output controls use `supported=false`, empty target and revision strings, and level `-1`. Microphone support is a separate boolean and identity pair. V1 retains its historical brightness fields for compatibility; v2 does not advertise brightness.

## Commands and approval

`actionMask` bit 0 is Lock Mac, bit 1 is the legacy Blender launch, bit 2 is the legacy Terminal launch, and bit 3 is area screenshot. Output-volume and microphone support are reported in each sample because the active hardware can change.

Action codes are lock `1`, set microphone mute `2`, launch Blender `3` (v1 compatibility only), launch Terminal `4` (v1 compatibility only), area screenshot `5`, set output volume `6`, brightness `7` (v1 compatibility only), and launch an approved app `8` (v2 only). V2 app launch carries the opaque approved `shortcutID` in `target`, the current catalog revision in `revision`, and value `-1`; it never carries a filesystem path, shell command, script, or URL. The Mac resolves the current locally approved bundle and verifies its bundle identifier, path, and resource identity immediately before launch.

Microphone and volume commands require a current nonempty hardware target and revision. Volume levels are integers `0..100`; microphone value `0` unmutes and `1` mutes. Lock and screenshot require empty target/revision and value `-1`. Commands use increasing IDs within one subscription and are not accepted twice. Results are applied `0`, stale `1`, unsupported `2`, permission-needed `3`, denied `4`, unavailable `5`, busy `6`, or failed `7`. A submitted request without a result remains unconfirmed; clients must not replay it automatically.

## Platform behavior

- CPU and memory use Mach host statistics; thermal pressure uses `ProcessInfo.thermalState`. The supported APIs used here do not provide a temperature in degrees.
- Output volume reuses the existing native default-output implementation and is available only for a settable output device.
- Microphone mute is available only when the current default input exposes a writable CoreAudio mute property. It is a system-device mute, not a hardware kill switch, and apps may use another input.
- Lock uses the public Control–Command–Q event sequence and requires Mac Event Posting permission. The action is advertised only when permission is available; an acknowledgement reports that the lock was requested.
- Area capture opens macOS's interactive screenshot selection. The user completes or cancels it on the Mac; the screenshot is not sent to the phone.
- App shortcuts are approved per trusted phone in Mac Settings → Desk Deck. Terminal and Blender are offered when installed. Replaced or removed apps fail identity checks and cannot be launched by stale catalog entries.
- Brightness is not included in v2. aniCe does not use a private display API or helper tool for it.

## Device power

Phone power is a separate shared capability in [`device-power`](../device-power/README.md). It uses only the already authenticated DATA channel and does not keep a connection alive. Mac Desk Deck v2 carries Mac power to the phone; the separate capability carries phone power to existing Mac device-status surfaces, including the menu-bar companion.

## CDDL

See [`desk-deck.cddl`](desk-deck.cddl) and [`../device-power/device-power.cddl`](../device-power/device-power.cddl) for exact bounded shapes. Cross-platform codec fixtures are in [`test-vectors/desk-deck-vectors.json`](../test-vectors/desk-deck-vectors.json) and [`test-vectors/device-power-vectors.json`](../test-vectors/device-power-vectors.json).
