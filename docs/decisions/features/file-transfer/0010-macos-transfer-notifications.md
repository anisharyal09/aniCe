# Mac file transfer notifications and companion activity

## Context

Incoming file transfers over secured LAN or Bluetooth previously required an open aniCe window or an opened companion popover to discover and approve offers. If aniCe was in the background or closed to the menu bar, incoming offers left the remote peer waiting without system-level notification. Android already implements foreground-service notifications with direction, progress, and completion wording. macOS had no counterpart notification integration, and the companion popover lacked live-activity presentation for active transfers.

## Decision

Introduce native macOS notifications (`UNUserNotificationCenter`) and a compact transfer live activity in the menu-bar companion:

1. **Native notification channel**:
   - Register `MacTransferNotifier` as `@preconcurrency UNUserNotificationCenterDelegate` before `applicationWillFinishLaunching` finishes, preserving cold-launch action clicks.
   - Define two notification categories:
     - `FILE_TRANSFER_OFFER`: Includes **Accept** (`ACCEPT_ACTION`, saving to `~/Downloads`), **Choose folder…** (`CHOOSE_ACTION`, foreground-activating aniCe with the offer visible), and **Decline** (`DECLINE_ACTION`, destructive).
     - `TRANSFER_RESULT`: Includes **Show in Finder** (`SHOW_IN_FINDER`), revealing published files via `NSWorkspace.shared.activateFileViewerSelecting`.
   - Notification content displays the authenticated `peerName`, file count, and aggregate byte size. Unchecked peer-provided filenames are excluded from banners.
   - Authorize lazily on first offer; permission denial or dismissal never gates transfer capability. When denied, the menu-bar companion activity and main window serve as the fallback presentation.
   - Guard against stale notification actions: verify `model.pendingOffer != nil` before executing an action, posting an informational notice if the offer was already cancelled or expired.

2. **Companion live activity & multi-device ordering**:
   - Stack `TransferView(compact: true)` alongside `MediaView` in a paged companion activity container (`1 of 2`).
   - Disable swipe gestures on cards containing horizontal sliders (such as `MediaView` seek/volume), while allowing swipe on transfer.
   - Present page indicators with an accent attention affordance on incoming offers without auto-switching pages or moving controls under user interaction.
   - Filter device overview rows so only connected peers appear when active connections exist, offering a card-styled **Send files…** row action that preserves popover presentation across modal file selection and hides while a transfer is active.
   - Keep the status-item right-click menu static and free of device state, preserving existing navigation tests.

3. **Destination reporting**:
   - Record actual published file locations (`publishedURLs`) and final directory (`receiveFolder`) in `MacTransferModel`, surviving transfer cleanup until explicit panel dismissal.
   - Report the verified destination folder rather than a tentative picker choice.

## Consequences

Existing wire contracts, session encryption, and identity stores remain unchanged. Destination folder writes respect standard macOS TCC protections: unattended writes to `~/Downloads` trigger standard system prompts on first access, with readable model failure handling if denied.
