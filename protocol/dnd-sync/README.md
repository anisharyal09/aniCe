<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Do Not Disturb sync v1

This capability sends explicit Android Do Not Disturb state changes to macOS over existing authenticated DATA. Mac-to-phone state changes are not supported. The v1 envelope remains unchanged and adds no pairing, transport or connection lease.

The deterministic CBOR envelope is `["aniCe dnd sync", 1, kind, fields]`, at most 128 bytes.

| Kind | Fields | Meaning |
| --- | --- | --- |
| 1 | `[sendEnabled: bool, receiveEnabled: bool]` | Each peer's send consent and receive readiness. Android sends only when its switch and Notification Policy access are enabled, and always advertises `receiveEnabled = false`. Mac always advertises `sendEnabled = false`; `receiveEnabled` is true only when separate On and Off Shortcuts are available. |
| 2 | `[eventID: uuid, enabled: bool]` | Android's explicit desired DND state. Mac accepts it only after Android advertises sending and Mac Shortcut setup is available. Android drops incoming kind 2 records. |
| 3 | `[eventID: uuid, result: 0..4]` | Mac's result for a phone-originated event: Shortcut finished `0`, setup unavailable `1`, failed or unconfirmed `2`, busy `3`, or superseded `4`. Result `0` does not verify Focus state. |

UUIDs are canonical lowercase, 36 characters. Mac retains a bounded 128-event replay window per phone. Channel retirement cancels obsolete work. Native Shortcut actions are serialized, with at most one latest incoming event waiting while an action is running. Results are channel-instance bound and commands are not automatically retried. Android feedback expires after eight seconds as unconfirmed.

Android observes `ACTION_INTERRUPTION_FILTER_CHANGED` only while a secured channel exists. Its send switch controls phone-originated changes. Notification Policy access is required to observe those changes. Mac applies them by running the locally selected On or Off Shortcut by identifier. aniCe does not poll Focus or inspect the resulting Mac state.

Changes are sent only while a secured channel exists; no state is queued or replayed after reconnecting. Apple Focus may separately sync across Apple devices when Share Across Devices is enabled. The Desk Deck DND button is a Mac-local toggle and is independent of this capability.
