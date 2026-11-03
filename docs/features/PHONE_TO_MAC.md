<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Control Mac

**Control Mac** lets a phone send text and trackpad input to a trusted Mac. Text uses the phone's normal on-screen keyboard. Input travels over aniCe’s authenticated Bluetooth session.

## Use

1. Connect the trusted phone and Mac over Bluetooth.
2. Allow aniCe's **Event Posting** request in **System Settings → Privacy & Security → Device Control and Data Access** on the Mac.
3. On Android, open **Features → Control Mac** and tap **Start control**. While aniCe is running, the authenticated phone request arms the Mac receiver for that session; the Mac feature page does not need to be open.
4. Use one finger to move, tap to click, long-press and move to drag, and two fingers to scroll.
5. Stop on either device to release remote input and clear the temporary phone editor.

The Mac checks `CGPreflightPostEventAccess()` before accepting a start. A phone request cannot grant or bypass macOS permission; if access is missing, the phone reports that setup is needed. The Settings switch and Accessibility trust are not treated as proof that Event Posting is available. When you return from System Settings, aniCe refreshes the status and stays open. If Event Posting still appears blocked after you allow it, **Restart aniCe** is available as an explicit recovery action. If it remains blocked after restart, remove aniCe from **Privacy & Security → Device Control and Data Access** and add the current stable signed copy again. Input goes to the Mac app with keyboard focus.

Choose Live typing to send composing text immediately, or keyboard-committed typing to wait for the keyboard to commit it. Changing modes stops the session.

## Text and IME behavior

The phone editor uses the selected Android keyboard. In keyboard-committed mode, aniCe holds the editor snapshot locally while the IME is editing a composing range. Live typing also forwards composing snapshots. Once composition ends, aniCe reconciles the committed snapshot with text already sent, so autocorrect and suggestion-range replacements remove changed graphemes with Backspace transitions before sending replacement text. Unicode commits remain separate from key transitions and are chunked at grapheme boundaries within the Mac's advertised limit, up to the protocol's 1,024-byte maximum.

The editor is temporary and capped at 64 KiB per session. AniCe does not log or persist typed text. The Android keyboard remains a system component, so its own settings and privacy behavior still apply. If an edit changes more than 256 already-sent graphemes at once or exceeds the session limit, the session stops rather than silently producing different text on the Mac.

Corrections assume the Mac caret remains after the text sent by the phone. After moving the caret or changing documents, stop and start a new session before typing again.

## Trackpad behavior

After the Mac accepts the session, the phone trackpad sends pointer movement, clicks, drag selection and two-finger scroll over the same BLE session. Hide the on-screen keyboard from the trackpad header for more space, or expand the trackpad to full screen. The full-screen view keeps a compact text field above the pad; tapping it starts control if needed and opens the phone keyboard. Motion and scroll deltas are coalesced while the BLE channel is busy. Older Mac builds can still receive typing but must advertise pointer support for the trackpad.

## Session and interruption behavior

Only one accepted BLE session is active at a time. The phone sends `release-all` before `stop`, and the Mac receiver also releases held input locally on channel loss, capture loss or shutdown. Leaving the feature or pausing aniCe stops the session. The sender uses a bounded ordered queue, reserves room for terminal release messages and stops with visible status if discrete input cannot be queued; it never retries text automatically.

See the [Phone-to-Mac v1 contract](../../protocol/phone-input/README.md) for message bounds and lifecycle details.
