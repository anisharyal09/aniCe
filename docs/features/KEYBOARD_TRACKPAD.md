<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Usage and limitations for the native Mac keyboard and pointer feature. -->
# Keyboard & Trackpad

Keyboard & Trackpad lets the Mac send standard Bluetooth keyboard and mouse input to an Android phone that is trusted in aniCe. The Mac presents itself as a Bluetooth HID device. Android handles the reports through its system Bluetooth input support; the phone does not need an aniCe update.

## First-time setup

1. Pair the phone with the Mac in macOS Bluetooth Settings.
2. Open **Keyboard & Trackpad** from Features or Favourites. The authenticated BLE-connected phone is the default; use **Other devices…** to choose another trusted phone. A live HID session keeps its target until stopped or explicitly changed.
3. Choose the paired Bluetooth device and confirm **Link device** after checking its address and the aniCe fingerprint. Matching names appear first as suggestions. If the names differ, expand **Other paired Bluetooth devices**. Confirmation stores a local association for that aniCe identity and starts the HID connection.
4. On later visits, aniCe reconnects once to the saved paired device. Click the keyboard area or pointer pad to begin input; connecting never captures keyboard or pointer input by itself.

Use **Other devices…** to select another trusted aniCe phone. Use **Change Bluetooth device…** in that menu to replace the system-paired device associated with the selected phone. A removed aniCe trust or reset local identity clears these local associations. Forgetting a phone in macOS Bluetooth Settings also requires linking again.

## Keyboard and pointer

- Click the keyboard area to focus it. The click that starts control only arms keyboard input; it is not forwarded to the phone. Type with the Mac keyboard while the area has focus.
- Click the pointer pad to arm pointer input. Later clicks and held drags are sent as mouse-button reports. Move the pointer to move the phone's pointer.
- Vertical scrolling sends mouse-wheel reports. Select **Extra slow**, **Gentle**, **Standard** or **Fast** beside the keyboard controls. The speed preference is local to this Mac.
- Two-finger sideways movement sends a held primary-button drag, using aniKey's direction and distance thresholds. Inertia is ignored, and a physical held click owns its drag. Three-finger gestures stay with macOS.
- **Back** and **Home** send HID consumer-control actions when the phone uses report protocol. Scrolling and these actions are unavailable in boot protocol. **Recents** sends aniKey's staged Meta+Tab keyboard chord.
- Keyboard reports retain a neutral trailing byte for compatibility with Android’s cached composite keyboard layout.
- Direct typing sends physical key positions; the Android keyboard layout determines the resulting text. Clipboard typing uses US-layout ASCII.
- Preset keyboard and navigation buttons release held keyboard and mouse input before sending their action, then leave capture idle. Click the keyboard area or pad to resume direct input.
- **Stop controlling** releases held input but keeps the HID connection open. `⌘⇧Esc` stops input while a feature surface has keyboard focus. Leaving the feature, losing focus, opening a native menu or sheet, sleep, link loss and Quit also stop capture and attempt neutral releases.

The feature reports keyboard and mouse input, not touchscreen contacts. Android apps decide what pointer clicks, scrolling and dragging do. Touch-only edge gestures and pinch gestures are not available.

When the phone suspends HID, pending input is discarded. Held reports are released when the host resumes; capture remains stopped until another deliberate click.

## Type clipboard

Choose **Type clipboard** to read the Mac pasteboard once and type the complete validated snapshot. It accepts US-layout printable ASCII, Tab and line endings, normalizes CRLF, and stops before sending if the snapshot is empty, contains unsupported text, or exceeds 1,024 characters. Each character uses a 50 ms press/release interval. **Stop typing** cancels before the next report; check the phone after an interruption because the last character may already have arrived. Text is not logged or saved by this feature.

## Device and connection boundaries

- The target must be an aniCe-trusted Android identity and a separately paired macOS Bluetooth device. Names do not establish identity; linking requires an explicit user confirmation.
- HID uses aniKey's system-paired, authenticated Classic Bluetooth path. macOS manages link encryption; aniCe does not independently verify it. Pairing, successful authentication of the current connection and matching HID channels are required before input. The active BLE session selects the default phone; input itself does not use BLE, LAN, IP addresses, ADB or scrcpy.
- No global keyboard or pointer monitor is installed, and the feature does not request Accessibility permission.
- macOS Bluetooth pairing and radio state affect availability. If the saved device is no longer paired, open Bluetooth Settings and pair it again before linking.
- **Disconnect** keeps HID closed for the current feature visit. Choose **Connect** or reopen the feature to reconnect.
- A successful HID connection can remain idle while the feature is not capturing input. Individual aniCe BLE or LAN disconnects do not close HID; device-wide Disconnect closes HID for that phone.

The Bluetooth profile and exact report bytes are specified in the [Classic Bluetooth HID contract](../../protocol/bluetooth/classic-hid.md). The feature's ownership and security rationale are recorded in [ADR 0011](../decisions/features/keyboard-trackpad/0011-macos-classic-hid-input.md).
