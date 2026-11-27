<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Control Mac

**Control Mac** lets a phone send text and trackpad input to a trusted Mac. Text uses the phone's normal on-screen keyboard. Input travels over aniCe’s authenticated Bluetooth session.

## Use

1. On the Mac, open **aniCe Settings → Permissions**, request Events access, then allow it in **System Settings → Privacy & Security → Device Control and Data Access**.
2. Connect the trusted phone and Mac over Bluetooth.
3. On Android, open **Features → Control Mac** and tap **Start control**. If Mac permission is blocked, aniCe shows the recovery status on the phone.
4. Use one finger to move, tap to click, long-press and move to drag, and two fingers to scroll.
5. Stop on either device to release remote input and clear the temporary phone editor.

The phone shows compact Mac setup instructions after an actual access rejection or revocation. A successful Start clears them; stopping control or losing Bluetooth does not by itself mean Mac permission is missing.

The Mac checks `CGPreflightPostEventAccess()` before accepting a start. Accessibility trust alone does not confirm Event Posting. The Mac Settings permission section refreshes status when you return from System Settings. If access remains blocked after granting it, restart aniCe once. macOS tracks privacy grants by code identity: consistent certificate signing helps preserve permission across rebuilds; an old ad-hoc grant may require reapproval after signing changes. Input goes to the Mac app with keyboard focus.

Choose Live typing to send composing text immediately, or keyboard-committed typing to wait for the keyboard to commit it. Changing modes keeps the session active.

## Text and IME behavior

The phone editor uses the selected Android keyboard. In keyboard-committed mode, aniCe holds the editor snapshot locally while the IME is editing a composing range. Live typing also forwards composing snapshots. When reconciling an edit against already-sent text, shared prefixes and suffixes stay intact: mid-text edits navigate with standard Left/Right arrow key transitions (`0x50` / `0x4F`) rather than deleting and retyping trailing text, while tail corrections remove changed graphemes with Backspace transitions before sending replacement text. Use the **Clear** button in **Type on Mac** (or fullscreen trackpad) to reset only the phone's local buffer so you can keep typing fresh without deleting text on the Mac. Unicode commits remain separate from key transitions and are chunked at grapheme boundaries within the Mac's advertised limit, up to the protocol's 1,024-byte maximum.

The editor is temporary and capped at 64 KiB per session. AniCe does not log or persist typed text. The Android keyboard remains a system component, so its own settings and privacy behavior still apply. If an edit changes more than 256 already-sent graphemes at once or exceeds the session limit, the session stops rather than silently producing different text on the Mac.

Corrections assume the Mac caret remains at the insertion position established by the last phone edit. Moving the caret on the Mac, clicking into text with the phone trackpad, or changing documents can invalidate that position; stop and start a new session before typing again.

## Trackpad behavior

After the Mac accepts the session, the phone trackpad sends pointer movement, clicks, drag selection and two-finger scroll over the same BLE session. Expand the trackpad to full screen for more space. The full-screen view keeps a compact text field above the pad; tapping it starts control if needed and opens the phone keyboard. Motion and scroll deltas are coalesced while the BLE channel is busy. Leaving the feature stops input but keeps the shared Bluetooth connection available. Older Mac builds can still receive typing but must advertise pointer support for the trackpad.

## Session and interruption behavior

Only one accepted BLE session is active at a time. The phone sends `release-all` before `stop`, and the Mac receiver also releases held input locally on channel loss, capture loss or shutdown. Leaving Control Mac on Android stops input without directly disconnecting Bluetooth. Mac Settings → Permissions provides Stop receiving; leaving Settings is not a receiver toggle. Pausing connections retires the shared channel and releases input. The sender uses a bounded ordered queue, reserves room for terminal release messages and stops with visible status if discrete input cannot be queued; it never retries text automatically.

See the [Phone-to-Mac v1 contract](../../protocol/phone-input/README.md) for message bounds and lifecycle details.

## Permission recovery

If access stays blocked after a restart:

1. Use **Settings → Permissions → Show this app in Finder**, then quit aniCe with **Command-Q**.
2. Remove the old aniCe entry from System Settings → Privacy & Security → Device Control and Data Access (Accessibility on older macOS).
3. Add the revealed app, enable access and reopen it.

Run one aniCe copy at a time. Branch folders share app identity and device state. Development and distribution signatures can need separate approval.

Developer permission tools are documented in the [Mac setup](../../apps/macos/README.md).
