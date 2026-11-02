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

Text commits and key transitions are distinct. Text is UTF-8 Unicode committed by the phone editor; it is not a sequence of guessed hardware keycodes. Key transitions represent physical keys and shortcuts. Modifiers remain explicit so a shortcut can span multiple ordered transitions, and a modified pointer-button event can be synthesized before its modifier latch is cleared.

The Mac accepts a start only when its local input surface is explicitly armed, its event-posting access is available, and the authenticated BLE peer is the selected peer. The session binds to that authenticated peer and channel instance. Only one session may be active for a peer. A rejected start does not enable input. No input is accepted before a successful start result.

Each event sequence starts at one and increases within its UUID session. Sequences must be strictly increasing; gaps are expected when adjacent pointer or scroll deltas are coalesced. A session UUID is never reused. A channel replacement, session stop, local capture loss, or app shutdown ends the session and releases held input locally; the Mac does not wait for a remote release message before releasing.

## BLE pacing and failure behavior

The sender accumulates pending pointer motion and scroll separately, then flushes them when the secured channel reports capacity. It sends no round-trip acknowledgement for individual motion or scroll records. Accumulation preserves signed deltas and splits any flush that exceeds the on-wire range.

Text commits, key transitions, button changes and session controls are discrete events. Keep their queue bounded and ordered. Never drop a key-up, button-up, text commit, or session boundary silently. If the bounded discrete queue cannot accept an event, stop that session and release all input; do not let congestion build an unbounded backlog. Motion alone must not trip a queue circuit breaker during ordinary BLE connection intervals.

The Mac applies local pointer scaling and clamps the resulting absolute cursor position to a live display bound before posting an event. Secure Keyboard Entry and system privacy dialogs may block synthesized input; surface the local blocked state and stop the session rather than retrying or escalating permissions.

Text chunks are limited to 1,024 UTF-8 bytes per record. The Mac native adapter further splits commits on extended-grapheme boundaries, at no more than 16 UTF-16 units per key event, and rejects a single grapheme that exceeds that limit. It does not log or persist text.

## Implementation gate

Phase 1 locks the wire shapes and cross-platform codecs. Later phases connect them to the Android editor and Mac event adapter, then validate physical BLE pacing, interruption release, text corrections and modified mouse actions on real devices. Protocol fixtures live in [phone-input-vectors.json](../test-vectors/phone-input/phone-input-vectors.json).
