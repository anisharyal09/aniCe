<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Type to Mac

**Type to Mac** lets a phone send text and trackpad input to a trusted Mac. Text uses the phone's normal on-screen keyboard. It uses aniCe's existing authenticated Bluetooth session and the Phone-to-Mac input v1 contract; it does not install a custom keyboard or create a separate pairing path.

## Use

1. Connect the trusted phone and Mac over Bluetooth.
2. On the Mac, open **Features → Type to Mac** and turn on phone input.
3. On Android, open **Features → Type to Mac** and start typing.
4. Use one finger to move, tap to click, long-press and move to drag, and two fingers to scroll.
5. Stop on either device to release remote input and clear the temporary phone editor.

The Mac receiver is limited to the currently authenticated Bluetooth phone. It checks macOS event-posting access without opening a permission prompt; if access is off, the Mac panel explains where to review it in System Settings. The start response indicates whether the receiver accepted the session; the phone does not type before acceptance.

## Text and IME behavior

The phone editor uses the selected Android keyboard. While the IME is editing a composing range, aniCe holds the editor snapshot locally. Once composition ends, aniCe reconciles the committed snapshot with text already sent, so autocorrect and suggestion-range replacements remove changed graphemes with Backspace transitions before sending replacement text. Unicode commits remain separate from key transitions and are chunked at grapheme boundaries within the Mac's advertised limit, up to the protocol's 1,024-byte maximum.

The editor is temporary and capped at 64 KiB per session. AniCe does not log or persist typed text. The Android keyboard remains a system component, so its own settings and privacy behavior still apply. If an edit changes more than 256 already-sent graphemes at once or exceeds the session limit, the session stops rather than silently producing different text on the Mac.

AniCe does not insert a sentinel into the editor. It keeps active composition local and reconciles the committed snapshot, allowing replacement edits without changing the phone's normal keyboard behavior.

## Trackpad behavior

After the Mac accepts the session, the phone trackpad sends pointer movement, clicks, drag selection and two-finger scroll over the same BLE session. Hide the on-screen keyboard from the trackpad header before using it; tap to click, long-press then move to drag, and use two fingers to scroll. Motion and scroll deltas are coalesced while the BLE channel is busy. Older Mac builds can still receive typing but must advertise pointer support for the trackpad.

## Session and interruption behavior

Only one accepted BLE session is active at a time. The phone sends `release-all` before `stop`, and the Mac receiver also releases held input locally on channel loss, capture loss or shutdown. Leaving the feature or pausing aniCe stops the session. The sender uses a bounded ordered queue, reserves room for terminal release messages and stops with visible status if discrete input cannot be queued; it never retries text automatically.

See the [Phone-to-Mac v1 contract](../../protocol/phone-input/README.md) for message bounds and lifecycle details.
