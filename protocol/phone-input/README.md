<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Phone-to-Mac input v1

Phone-to-Mac input sends text and control events from Android to the Mac over aniCe's existing authenticated BLE session. It adds no pairing, transport, permission, or session-security mechanism. It is separate from the Mac-to-phone Classic Bluetooth HID feature.

The exact deterministic-CBOR message shapes are in [phone-input.cddl](phone-input.cddl). Messages are bounded by the authenticated DATA record limit of 4,000 bytes. Both devices must support v1. Unknown versions and malformed messages are rejected.

## Message roles

| Kind | Direction | Purpose |
| --- | --- | --- |
| 1 capability | Both | Advertises maximum committed-text bytes and supported event classes: bit 0 text, bit 1 key transitions, bit 2 pointer and scroll |
| 2 start | Android → Mac | Requests one input session with a fresh UUID |
| 3 start result | Mac → Android | Accepts or rejects the request: 0 accepted, 1 busy, 2 local input unavailable, 3 unsupported |
| 4 text commit | Android → Mac | Inserts literal committed Unicode text |
| 5 key transition | Android → Mac | Sends a USB HID keyboard-page usage, modifier snapshot and pressed state |
| 6 pointer motion | Android → Mac | Sends relative signed movement deltas |
| 7 pointer buttons | Android → Mac | Sets the current three-button mask and modifier snapshot |
| 8 scroll | Android → Mac | Sends signed horizontal and vertical scroll deltas |
| 9 release all | Android → Mac | Releases every held key, modifier and pointer button |
| 10 stop | Android → Mac | Ends the input session |
| 11 session ended | Mac → Android | Ends a session after a local stop, access loss or invalid input |

Text commits and key transitions are distinct. Text is UTF-8 Unicode committed by the phone editor; it is not a sequence of guessed hardware keycodes. Key transitions represent physical keys and shortcuts. The modifier byte uses USB HID bits 0–7 for left Control, Shift, Alt, GUI, then right Control, Shift, Alt and GUI; it describes the active modifiers after that transition. Pointer-button bits 0, 1 and 2 represent left, right and middle. The button event carries the current modifier snapshot so a modified click is applied before a modifier latch is cleared.

The Mac accepts a start only when its local input surface is explicitly armed, its event-posting access is available, and the authenticated BLE peer is the selected peer. The session binds to that authenticated peer and channel instance. Only one session may be active for a peer. A rejected start does not enable input. No input is accepted before a successful start result.

Each event sequence starts at one and increases within its UUID session. Sequences must be strictly increasing; gaps are expected when adjacent pointer or scroll deltas are coalesced. A session UUID is never reused. A channel replacement, session stop, local capture loss, or app shutdown ends the session and releases held input locally; the Mac does not wait for a remote release message before releasing.

The Mac sends `session ended` when a live session ends locally so Android can clear its active editor state. Its reason is 0 for a local stop, 1 for event-posting access loss, 2 for malformed or unsupported input, and 3 for local capture loss. A retired channel already informs Android through transport state and does not carry this message.

## BLE pacing and failure behavior

Implementations that send pointer motion or scroll should accumulate those deltas separately and flush them when the secured channel reports capacity. They should not wait for a round-trip acknowledgement per motion or scroll record; accumulation preserves signed deltas and splits any flush that exceeds the on-wire range. The current Android sender advertises only text and key transitions; it does not send pointer, button or scroll events.

Text commits, key transitions, button changes and session controls are discrete events. Keep their queue bounded and ordered. Never drop a key-up, button-up, text commit, or session boundary silently. If the bounded discrete queue cannot accept an event, stop that session and release all input; do not let congestion build an unbounded backlog. Motion alone must not trip a queue circuit breaker during ordinary BLE connection intervals.

The Mac checks `CGPreflightPostEventAccess` without prompting, adds relative pointer deltas to the live cursor position in global display coordinates, and clamps the absolute position to a live display bound before posting an event. System privacy dialogs can block synthesized input. macOS has no documented API that reliably identifies another app's secure text field, so event-access preflight cannot guarantee delivery; do not retry automatically or escalate permissions.

Text chunks may not exceed the receiver's advertised limit, up to 1,024 UTF-8 bytes per record. The Mac native adapter further splits commits on extended-grapheme boundaries, at no more than 16 UTF-16 units per key event, and rejects a single grapheme that exceeds that limit. It does not log or persist text.

The Android editor keeps the IME's active composing range local and reconciles the committed editor snapshot against the text already sent. A replacement or autocorrect edit becomes grapheme-counted Backspace key transitions followed by a new literal text commit; ordinary text is never guessed from a keyboard layout. Android chunks commits on grapheme boundaries within the receiver's advertised limit. The editor and its current session text are transient, capped at 64 KiB, and are cleared on stop or presentation exit. The editor does not insert a sentinel.

## Implementation gate

Phase 1 locks the wire shapes and cross-platform codecs. Phase 2 adds the Mac receiver and native event adapter behind an explicitly armed owner, with no permission prompt. Phase 3 adds the Android in-app editor and bounded BLE sender for text and key transitions. User-facing Mac receiver controls and end-to-end acceptance remain pending. Protocol fixtures live in [phone-input-vectors.json](../test-vectors/phone-input/phone-input-vectors.json).
