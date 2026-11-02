<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Specifies aniCe Mac's local system-authorized Bluetooth HID input profile. -->
# Classic Bluetooth HID input contract

This contract describes the Mac's standard Bluetooth HID device profile for local keyboard and pointer input to an Android phone. It is independent of aniCe's BLE discovery, pairing messages, authenticated BLE/LAN sessions and application DATA. It adds no aniCe network message and requires no Android application component.

## Roles and authorization

- macOS publishes the HID device service and sends input reports over the HID control and interrupt channels.
- The selected Android phone receives those reports through its system Bluetooth HID host support.
- The Mac must have a system-paired device, the current aniCe phone must be trusted, and the user must explicitly link that paired Bluetooth device to the full aniCe peer credential (`deviceId:fingerprint`). A Bluetooth name can only suggest a candidate. The confirmation is bound to the displayed full peer credential; changing the target invalidates that confirmation.
- Before opening HID channels, the adapter requires the selected device to remain paired and connected and Bluetooth authentication to succeed. Authentication belongs to that connection and is cleared on disconnect. Every report write rechecks authentication, pairing and connection. macOS owns link encryption; aniCe does not independently verify it through `getEncryptionMode`. This follows aniKey's system-paired, authenticated policy.
- The Classic HID connection has its own system pairing and channel lifecycle. It neither upgrades nor replaces aniCe BLE/LAN sessions.

## Published service

| Field | Required value |
| --- | --- |
| HID service class UUID | `0x1124` |
| HID control PSM | `0x0011` |
| HID interrupt PSM | `0x0013` |
| HID descriptor type | Report descriptor, `0x22` |
| HID profile version | `0x0101` |

The descriptor is the exact byte sequence in [`hid-vectors.json`](../test-vectors/bluetooth-hid/hid-vectors.json). Report IDs are fixed because paired Android hosts may cache this descriptor:

| Report ID | Input payload | Meaning |
| --- | --- | --- |
| `1` | 9 bytes | 1 modifier byte, 1 reserved byte, 6 keyboard usages, 1 constant-zero trailing byte; output carries 5 keyboard LED bits and padding |
| `2` | 2 bytes | Consumer controls: Back is bit 0; Home is bit 2 |
| `10` | 5 bytes | Mouse buttons, relative X, relative Y, neutral Z, vertical wheel |

Android can retain the Mac’s earlier 190-byte composite descriptor across application changes. Its keyboard input report includes a ninth byte for a vendor field. Report 1 retains this byte as constant zero, preserving the first eight keyboard bytes and keeping all vendor controls neutral. Sending only eight bytes can be rejected by hosts enforcing the cached report length. The restricted consumer controls and five-byte mouse layout retain their cached positions. Boot keyboard packets and GET_REPORT responses carry the standard eight-byte keyboard payload.

HIDP input packets use the `0xA1` DATA prefix. Report protocol uses IDs 1, 2 and 10. Boot mouse uses ID 2 and the first 3 mouse payload bytes; wheel input and consumer navigation are unavailable in boot mode. Motion reports are bounded to signed X/Y values `[-127, 127]`; wheel is `[-8, 8]`; only the first two button bits are defined.

The packaged adapter validates the published SDP record against the expected descriptor and both PSMs before opening a channel. Open callbacks must match both the selected device and requested PSM. A failed or mismatched callback, malformed HIDP request, failed authentication, channel close or failed write fails closed. No failed input report is retried.

The completed channel must also be the channel returned by the open request. State notifications carry the connection generation so an earlier connection cannot update the current owner. GET_REPORT retains held mouse buttons with zero relative movement and wheel values. Host suspend stops capture and queued actions; EXIT_SUSPEND releases held reports before publishing readiness, without rearming capture.

Recents uses five keyboard reports: neutral; Meta down; Meta+Tab; Tab up with Meta held; neutral. Waits after Meta down, Meta+Tab and Tab up are 35 ms, 50 ms and 20 ms respectively. The usages, modifier transitions and timing follow aniKey; report-mode packets include the constant-zero keyboard tail. Each step is separately scheduled and cancellation releases the modifier before another step can start.

## Shared fixtures

[`../test-vectors/bluetooth-hid/hid-vectors.json`](../test-vectors/bluetooth-hid/hid-vectors.json) contains the exact descriptor bytes and keyboard, neutral release, mouse, consumer and boot-mouse packet examples. The macOS protocol tests consume these fixtures and exercise the production descriptor/report encoder.
