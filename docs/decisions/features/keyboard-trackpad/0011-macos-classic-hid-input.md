<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# ADR 0011: macOS Classic Bluetooth HID input

## Context

aniCe needs to send keyboard and pointer input from its Mac app to a trusted Android phone over native Bluetooth HID, following aniKey's tested Classic Bluetooth HID protocol behavior. aniCe already has authenticated BLE and LAN owners, but those protocols carry aniCe application records and do not provide system keyboard or mouse input.

The phone must be selected through aniCe's current trust inventory while macOS supplies Classic Bluetooth pairing, authentication and link encryption. A matching Bluetooth name cannot prove that a paired system device belongs to a particular aniCe identity.

## Decision

Implement the Mac presentation in SwiftUI/AppKit and isolate public IOBluetooth Classic HID operations in a small Objective-C adapter. Keep report IDs, PSMs, key fields and navigation behavior aligned with aniKey. Preserve a constant-zero ninth keyboard byte in report protocol to satisfy Android hosts retaining the Mac’s earlier composite descriptor; boot keyboard payloads remain eight bytes. Require a current trusted aniCe target, explicit one-time association to a system-paired Bluetooth address and successful authentication of the current connection before sending input. macOS manages link encryption; aniCe does not independently verify link encryption via `getEncryptionMode`, matching aniKey's system-paired and authenticated transport policy. Reconnect once when the feature opens or the user confirms a new association; leave the link idle until a surface is deliberately focused. Prefer the authenticated BLE-connected phone when choosing an automatic target, retain a live HID target, and honor explicit Other devices selection.

Store the local association in an injected namespaced UserDefaults preference keyed by the complete peer credential (`deviceId:fingerprint`). Remove mappings when trust is removed or the Mac identity is reset. Device names may suggest which system pairing to link, but never establish the association without confirmation.

Treat Classic HID as an independent system-authorized transport. Do not add an Android service, permission, dependency, Rust component, ADB/scrcpy path, aniCe network message or reuse of the aniCe LAN/BLE session as an input tunnel. A feature-level stop releases local capture and retains HID; device-wide Disconnect closes the HID connection for the affected phone. Sleep, focus loss, navigation, modal surfaces and Quit release input and close the appropriate owner.

Clipboard typing is an explicit local action. Validate the complete snapshot before sending, bound it to 1,024 supported characters, schedule press/release reports with aniKey's 50 ms pacing, and never persist or log clipboard text. On interruption, tell the user to check the phone and do not retry or resume.

## Consequences

- Android system HID support receives ordinary Bluetooth keyboard and mouse input without an aniCe update.
- The Mac must be paired with the phone separately in macOS Bluetooth Settings and the user must link the selected system-paired device once.
- BLE/LAN data features remain independently authenticated and can run alongside HID; radio coexistence and Android device recognition still require physical validation.
- The adapter's protocol fixtures protect exact descriptor and report bytes, but cannot prove system-level pairing, Android recognition, or radio reliability.

See [Keyboard & Trackpad usage](../../../features/KEYBOARD_TRACKPAD.md) and the [Classic Bluetooth HID contract](../../../../protocol/bluetooth/classic-hid.md).

## aniKey adaptation

Reference reviewed: [aniKey Sources/Anikey.m](https://github.com/anishcreations/aniKey/blob/0dc7480509c15f43ba0e7fafd3b9072b6c0fa393/Sources/Anikey.m), GPL-3.0-or-later, copyright 2026 Anish Aryal. The adapter retains that copyright and license notice. This is adapted source, with compatibility-sensitive report conventions intentionally retained.

| Boundary | aniCe implementation |
| --- | --- |
| HID transport and reports | Retain SDP/HIDP conventions, Classic channel PSMs and the staged Recents chord; validate the descriptor and channel identity, retain Android’s cached keyboard tail, and never retry failed input. |
| Native work | Isolate IOBluetooth on a run-loop worker with bounded admission, serial operations during nested callbacks, cancellable connection waits and bounded shutdown. |
| App lifecycle | Tag events by connection generation; Swift owns trusted-peer associations, registered presentations, input owners and neutral releases. |
| Interaction | Reuse native keyboard and pointer capture across the feature, full-screen pad and floating panel; preserve fractional motion and independent saved speeds. |

The Objective-C layer does not decide aniCe trust, install global input hooks or add a phone service. Hardware checks remain necessary for Bluetooth interoperability, lock-screen behavior and Spaces/full-screen presentation.
