# Mac Desk Deck v1

Mac Desk Deck carries a foreground Android control panel's hardware snapshot and explicit Mac actions in existing authenticated DATA. It uses the normal trusted-device session and does not add a pairing or transport path. Records remain within the standard 4,000-byte plaintext limit; each Desk Deck envelope is at most 512 bytes.

The Mac advertises a capability mask when a secured channel becomes available. The Android panel subscribes only while open and sends a fresh random subscription UUID. The Mac samples CPU, memory, thermal pressure and supported controls at most once per second while subscribed. Android sends explicit, bounded commands; closing the panel sends `stop`. A retired channel cancels the subscription. Commands are never replayed after a disconnect or across a replacement channel.

## Envelope

Deterministic CBOR is `["aniCe desk deck", 1, kind, fields]`.

| Kind | Direction | Fields |
| --- | --- | --- |
| 1 capability | Mac → Android | `[actionMask]` |
| 2 subscribe | Android → Mac | `[subscription]` |
| 3 sample | Mac → Android | `[subscription, sequence, cpuPercent, memoryUsed, memoryTotal, thermalState, actionMask, outputSupported, outputTarget, outputRevision, outputLevel, microphoneSupported, microphoneTarget, microphoneRevision, microphoneMuted, brightnessSupported, brightnessTarget, brightnessRevision, brightnessLevel]` |
| 4 command | Android → Mac | `[subscription, commandID, action, target, revision, value]` |
| 5 result | Mac → Android | `[subscription, commandID, result]` |
| 6 stop | Android → Mac | `[subscription]` |

`actionMask` bit 0 is Lock Mac, bit 1 is Launch Blender, bit 2 is Launch Terminal, and bit 3 is Screenshot. Output volume, microphone mute and brightness support are reported separately in each sample because the active hardware can change.

`cpuPercent` is `-1` when the first or native CPU sample is unavailable; otherwise it is `0..100`. Memory values are physical-memory bytes in use and total. `thermalState` is the macOS thermal-pressure state: nominal `0`, fair `1`, serious `2`, critical `3`. It is not a temperature reading. Unsupported control values use `supported=false`, empty target/revision strings, and level `-1`.

Action codes are lock `1`, set microphone mute `2`, launch Blender `3`, launch Terminal `4`, area screenshot `5`, set output volume `6`, and set display brightness `7`. The Mac currently advertises brightness as unsupported. Microphone and volume commands require a current nonempty target and revision; other actions require empty target/revision and value `-1`. Levels are integers `0..100`; microphone value `0` unmutes and `1` mutes.

Result values follow the media command result codes: applied `0`, stale `1`, unsupported `2`, permission-needed `3`, denied `4`, unavailable `5`, busy `6`, failed `7`. Command IDs start at 1, increase within a subscription, and are never accepted twice. A command addressed to a retired channel, subscription, input device, or output device is discarded or returns stale; it is never silently redirected.

## Platform behavior

- CPU and memory are sampled from Mach host statistics; thermal pressure uses `ProcessInfo.thermalState`. macOS does not provide a supported temperature-in-degrees field here.
- Output volume reuses the existing native default-output implementation and is available only for a settable output device.
- Microphone mute is available only if the current default input device exposes a writable CoreAudio mute property. It is a best-effort system-device mute, not a hardware kill switch and not a guarantee that every application uses that input.
- Lock, application launch and area screenshot use the Mac's native session/app/screenshot services. Blender is available only when its application bundle is installed. Screenshot selection and cancellation remain under Mac user control.
- Display brightness is not currently supported. Neither a private display API nor synthetic brightness-key presses are used.

## CDDL

See [`desk-deck.cddl`](desk-deck.cddl) for the bounded field shapes and result codes.
