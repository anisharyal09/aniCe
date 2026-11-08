# UX request audit

This records the original UX requests and the later phone-control and Mac-recovery fixes. “Implemented” means the code is present; it does not establish physical-device or visual acceptance. Commit history is owned by Git, not this document.

## Connection constraints

BLE retains automatic reconnect ownership through native events and bounded backoff. Automatic LAN remains coordinated through authenticated BLE; it has no independent retry loop. Timed pauses close current sessions and gate those owners until a saved deadline or manual resume. Android background LAN defaults to **Never**; saved choices are preserved. See [background connections](BACKGROUND_CONNECTIONS.md) and [LAN policy](LAN_CONNECTIONS.md).

## Original requests

| Request | Implementation and remaining limits |
| :--- | :--- |
| Timed connection pause, custom duration and automatic resume | Implemented on both platforms: 1, 3, 6 hours, custom duration or manual resume. Home and Devices show a labeled Pause/Resume menu with the same choices; Android Home omits Disconnect and overflow, while Devices retains explicit transport controls. See Android `SessionPanel.kt` / `CompanionProbe.kt` and Mac `MacSessionView.swift` / `MacSessionModel.swift`. |
| Start LAN by default without waiting for BLE | **Partial relative to the original wording.** Automatic LAN defaults on, but authenticated BLE coordination remains required, following the later instruction to preserve the current architecture. Manual LAN remains independent. |
| Home device name opens Devices instead of a popup | Implemented in both navigation shells, including the Mac Home header. Phone focused-device navigation clears connection details, diagnostics and discovery events. |
| One plain-language connection status | Implemented by Android `ConnectionSummary.kt` and Mac `ConnectionPresentation`; each secured Bluetooth or local-network link is shown as an accessible icon instead of repeating transport names in the status text. |
| Background LAN timeout defaults to Never | Implemented in Android `LanSessionController.kt` and Settings; existing finite choices remain. |
| Highlight QR/code selection and shorten phone code entry | Implemented in the pairing views; phone code input has a compact height. |
| Bluetooth and LAN checks in both directions | Send/receive paths and diagnostic feedback exist on both platforms. Physical two-device delivery still needs acceptance testing. |
| Phone Settings navigation like Mac, smaller controls | Implemented as a vertically scrolling page with horizontally scrollable top shortcuts that jump to groups, retain visible selected styling through the jump, briefly highlight the destination group, and reveal the active shortcut during manual scroll. Mac Settings uses balanced section columns. Phone visual acceptance remains pending. |
| Phone identity sheet should expand only for Advanced | Implemented: collapsed content wraps its height; Advanced animates open and requests that Reset identity be brought into view. Visual phone acceptance remains pending. |
| Enable automatic file acceptance in both directions | Enabled for new pairings on both platforms. Existing peers retain saved choices; no saved choice on an existing peer remains off. See [file transfer](features/FILE_TRANSFER.md). |
| Mac global keyboard shortcut | Implemented: Option-Command-K toggles the existing floating keyboard. |
| Favourites empty state teaches how to add items | Implemented on both platforms, with a Choose favourites action. |
| Improve the first app opening | Both Home views show one Add device entry with instructions for the other device; Android opens pairing directly when Devices is selected with no trusted phone. Unavailable send actions and empty trust/activity controls are hidden. This is an implemented flow change, not a completed visual usability study. |
| Reorder lists on phone and Mac | Features and Favourites have saved order with long-press/right-click Move actions. Trusted-device manual ordering is not implemented. |
| Mac feature right-click Add to Favourites/Home | Favourites actions are implemented. Optional Add to Home is not implemented. |
| Remove redundant Back to Features/Favourites links | Removed from feature panels; native history and conversation navigation remain. |
| Keyboard entry in Mac full-screen trackpad | Implemented with a separate capture area; floating keyboard behavior remains separate. Full-screen spacing preserves the pointer area at small window sizes. |
| Improve manual file review and receive results | Offers identify files and the save folder; successful receipt identifies its destination. See [file transfer](features/FILE_TRANSFER.md). Visual acceptance remains pending. |
| Simplify Mac keyboard/trackpad Bluetooth linking | Setup exposes the link choices directly with short instructions. Native Bluetooth pairing and one explicit Link device confirmation remain required. |
| Remove stray unpaired companion/file actions and empty trust toggle | Implemented in Home, Devices and the Mac companion. |

## Later corrections

- Defer Mac identity loading, automatic connection startup and OS integrations until after the main window's first render. The freeze was not reproducible in the running app during this pass; this removes avoidable startup work from app construction while preserving the event-driven BLE/LAN owners.
- Mac Dock reopen and activation restore the main workspace through one delegate-owned recovery path, including when other windows are visible. SwiftUI window creation has a bounded wait before focus/de-miniaturization. Physical Dock/Stage Manager acceptance remains pending.
- Manual Mac Disconnect stays disabled after restart even if an old automatic preference is still saved.
- Mac development build folders use URL-safe branch keys to avoid the percent-escaped slash stat-cache failure. See [Mac development setup](../apps/macos/README.md).
- Android Find Device permission and peer actions use the compact outlined control style. Pairing code entry and Settings selectors were tightened while preserving touch targets.

## Verification and remaining work

The full Mac suite previously passed with 521 tests and six skips; focused Dock and companion tests passed after the window-recovery consolidation. The latest Mac app build passed. Android Kotlin compilation and unit tests passed after the Settings highlight, connection-row and pause-menu corrections. Swift syntax parsing, structure checks and whitespace checks passed. Mac unit tests were not rerun in this pass.

Remaining device acceptance: first pairing by QR and code, pause expiry/manual resume, Bluetooth/LAN checks in both directions, manual/automatic file receipt, phone Advanced-sheet expansion, and Mac Dock/Stage Manager reopening. Screen capture failed during the earlier interactive pass, so those flows are not marked visually verified.

Product behavior belongs in the [design guide](design/DESIGN.md) and feature guides; wire contracts remain under [protocol](../protocol/README.md). Optional follow-ups are Add to Home and manual trusted-device ordering.
