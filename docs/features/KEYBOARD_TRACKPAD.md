<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Usage and limitations for the native Mac keyboard and pointer feature. -->
# Keyboard & Trackpad

Keyboard & Trackpad lets the Mac send standard Bluetooth keyboard and mouse input to an Android phone that is trusted in aniCe. The Mac presents itself as a Bluetooth HID device. Android handles the reports through its system Bluetooth input support; the phone does not need an aniCe update.

## First-time setup

1. Add and approve the phone in **aniCe → Devices** using a QR code or six-digit code. This establishes aniCe trust; it is separate from system Bluetooth pairing.
2. Pair the phone with the Mac in **Bluetooth Settings on both devices**.
3. Open **Keyboard & Trackpad** from Features or Favourites. The authenticated BLE-connected phone is the default; **Other devices…** lists aniCe-trusted phones, not arbitrary nearby Bluetooth devices. A live HID session keeps its target until stopped or explicitly changed.
4. Choose **Refresh** after system pairing, select the corresponding Bluetooth device and confirm **Link device**. This list contains only system-paired devices. A matching name appears first; if the phone uses a different name, open **Phone has a different name?** and choose its pairing. Confirmation stores a local association for that trusted aniCe phone and starts the HID connection. Other Bluetooth accessories may also appear in the expanded list.
5. On later visits, aniCe reconnects once to the saved paired device over Bluetooth HID. The connection stays idle until you click the keyboard area or pad; connecting never captures input by itself. Two-finger scrolling over an inactive pad scrolls this panel. Once you click the pad to activate it, two-finger scrolling controls the phone.

Press **⌥⌘K** anywhere while aniCe is running to show or hide **Floating Key**. Hover its button for direct-typing and trackpad guidance.

Use **Other devices…** to select another trusted aniCe phone. Use **Change Bluetooth device…** in that menu to replace the system-paired device associated with the selected phone. A removed aniCe trust or reset local identity clears these local associations. Forgetting a phone in macOS Bluetooth Settings also requires linking again.

## Keyboard and pointer

- Click the keyboard area to focus it. The click that starts control only arms keyboard input; it is not forwarded to the phone. Type with the Mac keyboard while the area has focus.
- Click the pointer pad to arm pointer input. While inactive, scrolling over it scrolls this panel; once active, scrolling controls the phone. Later clicks and held drags are sent as mouse-button reports. Move the pointer to move the phone's pointer.
- Drag the handle below the pointer pad up or down to resize the pad; the keyboard stays the same height. The saved pad height is shared by the main feature and expanded floating controls, and resizing keeps the input surface and its focus.
- Pointer motion and vertical scrolling retain fractional deltas between reports so slow movement accumulates without loss. Stopping control discards unsent fractions.
- **Pointer** and **Scroll** have independent, saved speeds: **Extra slow** (⅛×), **Gentle** (½×), **Standard** (1×) and **Fast** (2×). Pointer defaults to Standard; Scroll defaults to Extra slow. Scroll speed applies to both precise trackpad scrolling and mouse-wheel steps. Android's input settings also affect the resulting movement.
- Vertical pointer movement follows the native trackpad direction by default. Turn on **Reverse vertical pointer** in the Pointer menu to invert it; this preference is saved locally.
- The pad stays active when the pointer leaves; movement and scrolling reach the phone only while the pointer is inside the visible pad. Return to the pad to continue without clicking again. **Full-screen trackpad** opens a separate native full-screen pad on one display, with a keyboard area above it. Click the keyboard area to type with the Mac keyboard; click once on the pad to arm pointer input, then move, click, drag or scroll anywhere within it. **Stop controlling** and **Done** remain local controls; Done or leaving full-screen releases held input and closes the pad. `⌘⇧Esc` also stops capture. Other applications and displays keep their own input.
- Use two fingers up/down to scroll. A left/right swipe moves the phone pointer while holding its primary button, so it can pan content or drag/select items. Inertia ends the gesture and releases any drag without forwarding its movement. A physical held click takes precedence. Three-finger gestures stay with macOS.
- **Back** and **Home** send HID consumer-control actions when the phone uses report protocol. Scrolling and these actions are unavailable in boot protocol. **Recents** sends a staged Meta+Tab keyboard chord.
- Keyboard reports retain a neutral trailing byte for compatibility with Android’s cached composite keyboard layout.
- Direct typing sends physical key positions; the Android keyboard layout determines the resulting text. Clipboard typing uses US-layout ASCII.
- Preset keyboard and navigation buttons release held keyboard and mouse input before sending their action, then leave capture idle. Click the keyboard area to resume typing, or click the pad to resume pointer input.
- **Stop controlling** releases held input but keeps the HID connection open. `⌘⇧Esc` stops input while a feature surface has keyboard focus. Leaving the feature, losing focus, opening a native menu or sheet, sleep, link loss and Quit also stop capture and attempt neutral releases.

The feature sends mouse input, not touchscreen gestures; pinch and edge swipes are not supported.

When the phone suspends HID, pending input is discarded. Held reports are released when the host resumes; capture remains stopped until another deliberate click.

## Floating Key

Choose **Keyboard** in the menu-bar companion or **Show Floating Key** from its right-click menu. The draggable 48-point keyboard button stays above regular windows across Spaces and full-screen apps. Hover explains that clicking types directly on Android; right-click opens the full keyboard and trackpad controls. Its accessibility label includes the selected phone and current state.

Click once to toggle phone typing on or off. The button uses the accent fill and a contrasting keyboard icon while active; its status dot also reflects activity. If the HID link is disconnected, aniCe connects first and starts typing only if the button still has focus when the connection completes. Clicking again, losing focus, switching apps, opening a menu or sheet, or hiding the widget cancels pending activation and releases held input. The HID link may remain connected and idle.

Right-click the button for **Show trackpad too** or **Hide**. Expanded controls show the phone name, **Open in app**, the keyboard/navigation/clipboard action row and then the input areas. Routine Bluetooth status, helper text and connection buttons stay out of the way while HID is ready; setup and recovery actions remain visible when needed. **Open in app** collapses the floating panel and opens aniCe. **Collapse** returns to the button's saved position. Drag the grip at the top-left to move the expanded panel; collapsing uses that new position. A small Floating label identifies the expanded window, and its phone header omits repeated pairing details. Expanding, collapsing or hiding releases input, so a fresh click is required to resume. The widget remembers whether it was visible and its compact position across hiding and reopening. After a restart it restores collapsed and idle without connecting; **Hide** saves it as hidden. Saved positions are clamped to the available display after display changes.

## Type clipboard

Choose **Type clipboard** to read the Mac pasteboard once and type the complete validated snapshot. It can start during direct control: validation happens first, then held input is released and clipboard typing takes over. Invalid text leaves direct control active. It accepts US-layout printable ASCII, Tab and line endings, normalizes CRLF, and stops before sending if the snapshot is empty, contains unsupported text, or exceeds 1,024 characters. Each character uses a 50 ms press/release interval. **Stop typing** cancels before the next report; check the phone after an interruption because the last character may already have arrived. Text is not logged or saved by this feature.

## Device and connection boundaries

- The target must be an aniCe-trusted Android identity and a separately paired macOS Bluetooth device. Names do not establish identity; linking requires an explicit user confirmation.
- HID uses a system-paired, authenticated Classic Bluetooth connection. macOS manages link encryption; aniCe does not independently verify it. Pairing, successful authentication of the current connection and matching HID channels are required before input. The active BLE session selects the default phone; input itself does not use BLE, LAN, IP addresses, ADB or scrcpy.
- No global keyboard or pointer monitor is installed, and the feature does not request Accessibility permission.
- macOS Bluetooth pairing and radio state affect availability. If the saved device is no longer paired, open Bluetooth Settings and pair it again before linking.
- **Disconnect** keeps HID closed for the current feature visit. Choose **Connect** or reopen the feature to reconnect.
- A successful HID connection can remain idle while the feature is not capturing input. Individual aniCe BLE or LAN disconnects do not close HID; device-wide Disconnect closes HID for that phone.

The Bluetooth profile and exact report bytes are specified in the [Classic Bluetooth HID contract](../../protocol/bluetooth/classic-hid.md). The feature's ownership and security rationale are recorded in [ADR 0011](../decisions/features/keyboard-trackpad/0011-macos-classic-hid-input.md).

## Implementation and idle behavior

The Objective-C adapter adapts aniKey’s GPL transport and report conventions. aniCe adds a bounded run-loop worker, current-connection authentication and channel checks, generation-tagged callbacks, and failure handling without replaying input. The Swift model owns trusted-phone selection, input ownership, motion pacing and cancellation; native views own focus and gesture capture. See the [adaptation record](../decisions/features/keyboard-trackpad/0011-macos-classic-hid-input.md#anikey-adaptation).

Stopping input or hiding controls releases held reports and cancels pending motion and typing jobs. The independent HID connection can remain idle. Its Bluetooth worker waits on its run loop rather than polling; connection setup uses bounded callback waits. An idle connection still uses system Bluetooth resources. Quit shuts the adapter down. Android decides whether ordinary HID input is accepted on its lock screen; aniCe does not bypass phone authentication or guarantee lock-screen control.
