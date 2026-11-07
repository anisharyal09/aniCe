<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Do Not Disturb sync v1

This independent capability uses existing authenticated DATA. It does not require Desk Deck, open a connection, acquire a background lease, poll state, or replay disconnected changes. Each device's off-by-default setting authorizes **outgoing** changes. Receiving requires local Android Notification Policy access or locally selected Mac On and Off Shortcuts. Both settings enabled permit both directions. Only connected trusted peers advertising reception receive changes; LAN is preferred over BLE when selecting a channel for each peer; a healthy selected channel stays stable until retirement or peer capability withdrawal.

The deterministic CBOR envelope is `["aniCe dnd sync", 1, kind, fields]`, at most 128 bytes. Unknown capabilities do not enable synchronization.

| Kind | Fields | Meaning |
| --- | --- | --- |
| 1 | `[sendEnabled: bool, receiveEnabled: bool]` | Capability and current local consent/readiness; sent on channel availability and local configuration changes. |
| 2 | `[eventID: uuid, enabled: bool]` | Explicit desired state, never a toggle. Accepted only after the sender advertises sendEnabled and the receiver is ready. |
| 3 | `[eventID: uuid, result: 0..4]` | Native command finished `0`, permission/setup unavailable `1`, failed or unconfirmed `2`, busy `3`, superseded `4`. A successful Mac Shortcut command does not prove Focus changed. |

UUIDs are canonical lowercase, 36 characters. Receivers retain a bounded 128-event replay window per peer across active transports. Channel retirement cancels obsolete work. Native actions are serialized; at most one latest incoming event waits while an action is running. Results are channel-instance bound and commands are not automatically retried. Outgoing feedback expires after eight seconds as unconfirmed.

Mac native Shortcuts automations call the aniCe **Report Mac Do Not Disturb** App Intent with an explicit boolean on DND activation/deactivation. These are authoritative DND events; generic Focus-status permission is not used. Receiving executes locally selected dedicated **On** or **Off** Shortcuts by identifier; no executable content, URLs, names or paths arrive from a peer. Selecting both enables reception independently of the outgoing switch. Removing selections disables reception immediately.

The Shortcuts app is required for initial setup. Apple's documented URL scheme opens the shortcut editor, and importing a `.shortcut` file is done through Shortcuts; there is no supported silent-install route. aniCe provides copyable automation steps in Settings.

Android observes `ACTION_INTERRUPTION_FILTER_CHANGED` only while a secured channel exists. Unknown state is not off. Received states use `NotificationManager.setInterruptionFilter` after checking Notification Policy access. Android 15 and newer, with this app's target SDK, may implement this as an app-owned automatic DND rule: turning it off does not disable another user/system rule. Existing user policy and exemptions remain intact. No user permission prompt is opened by a remote event.

Native callbacks corresponding to a remote apply are consumed locally rather than forwarded. A bounded expected-state marker suppresses the matching callback for up to fifteen seconds; an opposite observed transition clears it and counts as a local change. Duplicate native state reports are ignored. This accommodates asynchronous native automations; an automation delayed past the marker lifetime can be interpreted as a new local change. Explicit setters, duplicate-state suppression and bounded replay prevent a toggle loop. No offline state is inferred or persisted.

Simultaneous conflicting user changes are not an atomic distributed transaction; each side applies the last accepted remote event. Failures, missing setup and unconfirmed results remain visible in Settings. Enabling a switch or reconnecting does not overwrite either device's current state; the next real native transition is synchronized.
