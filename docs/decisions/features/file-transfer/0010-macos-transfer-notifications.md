# Mac file transfer notifications and companion activity

## Context

Incoming offers need a discovery path while aniCe is backgrounded. Approval, progress and recovery remain available in the main window and menu-bar companion independently of notification permission.

## Decision

### Background offers

- `AppDelegate` owns the shared `UNUserNotificationCenterDelegate` and registers transfer categories alongside Messages and Find Device. Responses route to the existing feature owner.
- **Background offer notifications** defaults off; **Play sound** defaults on. Files and Settings edit the same local preferences. Notification authorization is requested when the first enabled background offer is posted; denial never gates transfer execution.
- Post one `FILE_TRANSFER_OFFER` notice per batch only while aniCe is inactive. Show authenticated peer name, file count and total size; omit peer-supplied filenames.
- **Accept** saves through the transfer owner to Downloads. **Choose folder…** activates the main window for destination selection. **Decline** rejects the offer.
- Accept and Decline validate the notification identifier against the current pending batch. Stale actions cannot approve or reject a successor offer. Choose folder opens the window without applying approval to another batch.
- Pause, resume, completion and failure clear the active offer notice and remain in the app; they post no new system banners. Startup removes legacy transfer notices without clearing Messages or Find Device notices. Legacy result and pause categories retain their action handlers.

### Companion activity

- Show active playback and transfer together, separated by a divider; use no pages, counters or swipe gestures.
- Show connected peers while any are connected, otherwise saved peers. Keep Send files compact and available only for a compatible ready target; preparation and active transfer replace the idle action.
- Preserve the companion across modal file selection and restore focus afterward. Dismissing the companion does not cancel work.
- Keep Open aniCe in a persistent footer. The companion overflow exposes Settings; the status-item context menu exposes Open aniCe, Manage devices and Quit.

### Destination reporting

`MacTransferModel` retains actual published file URLs and the receive folder through cleanup until explicit dismissal. Result presentation uses the verified publication destination rather than a tentative picker choice.

## Consequences

Notification preferences affect presentation only. Approval, transport ownership and file publication remain with the existing transfer owner. Destination writes remain subject to macOS filesystem and TCC access; failures surface through the transfer state.
