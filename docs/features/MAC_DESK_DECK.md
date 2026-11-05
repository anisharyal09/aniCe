<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Mac Desk Deck

Mac Desk Deck is an Android feature panel for a connected, trusted Mac. It becomes a responsive quick-control surface in landscape and remains usable in portrait. Open **Features → Mac Desk Deck**, choose a paired Mac, and connect if needed. The panel samples only while it is foreground and open, using the existing authenticated session.

## Meters

- **CPU** shows whole-system processor use from Mach host counters.
- **Memory** shows active, wired and compressed memory against physical memory.
- **Thermal pressure** shows macOS's nominal, fair, serious or critical state. It does not claim to report sensor temperatures in degrees; macOS does not expose a supported temperature reading through the APIs used here. See Apple's [thermal-state documentation](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum).

Meters refresh about once per second while the panel is open. Leaving the panel or backgrounding aniCe stops the subscription.

## Quick controls

- **Mute mic** sets mute on the current default input device only when that device exposes a writable CoreAudio mute property. The control is unavailable otherwise. This does not create a hardware kill switch and cannot guarantee that every app uses that input.
- **Lock Mac** starts the macOS session-lock action when the native service is present.
- **Launch Blender** appears when the Blender app bundle is installed. **Launch Terminal** uses the native Terminal app.
- **Take Screenshot** opens the macOS area-capture tool. The user completes or cancels the selection on the Mac; the screenshot is not sent to the phone.
- **Mac output volume** controls the current default output device when it exposes a writable system volume. It is separate from per-player volume in Now Playing.
- **Display brightness** is reported as unsupported in this version. aniCe does not inject brightness keystrokes or call a private display API.

Every action uses an explicit value and a subscription-bound command ID. Volume and microphone writes include a target and revision so a changed default device cannot silently receive a stale command. Commands are not replayed after a disconnect. The grid keeps slider cards free of swipe navigation and uses large Android touch targets.

## Protocol

The bounded deterministic-CBOR wire contract is [Mac Desk Deck v1](../../protocol/desk-deck/README.md). It adds no pairing, transport, permission, or dependency stack.
