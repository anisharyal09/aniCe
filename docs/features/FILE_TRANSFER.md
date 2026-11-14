# Local File Transfer

Transfer batches of 1–128 files between trusted Mac and Android devices over their existing authenticated LAN or BLE sessions. Both peers must advertise file-transfer support. Ready LAN is preferred; BLE remains available under the rules below. The receiver approves each batch unless automatic receiving is enabled for that trusted sender.

## Sending

Home shows file-send controls after at least one device is trusted. On a new installation, Home directs the user to add a device first.

On Mac, Home and Features → File transfer accept file drops; **Choose files** remains available. Picker sends show the selected files and recipient for review. A drop sends to the current compatible Android phone and pins that recipient.

**Edge Drop** is on by default at the right edge. It can be moved to the left or top, or turned off in Settings → File transfer; an explicit choice is saved. It appears only for a current Finder file drag on the display containing the drag. Drops accept regular local files already available to Mac, up to 128 per batch. Folders, symbolic links, promised files, unavailable cloud files and mixed unsupported selections are rejected without partial sending. After the receiver verifies a drop, the shelf confirms the file count and recipient before dismissing. Edge Drop uses native drag observation and requires no Accessibility permission.

On Android, **Share → Send to Mac** sends one or more selected files to the connected compatible Mac. The send is pinned to that Mac. Busy or disconnected states offer recovery instead of queuing or redirecting the batch. Text and link sharing keep their existing clipboard flow.

Mac sends prefer a ready LAN channel and request bounded setup when needed. If setup fails, the files remain pending with **Retry**, **Send over Bluetooth**, and **Cancel**; Bluetooth never starts silently. Android may use an already-capable BLE channel while LAN setup runs. A batch stays bound to its trusted peer.

## Receiving and destinations

Receives default to `~/Downloads/aniCe` on Mac and `Downloads/aniCe` on Android. Each platform can remember a supported local folder and reset to its default. Android uses pending MediaStore entries for the default and a validated document-tree grant for a custom folder; cloud-only providers are unsupported.

Both platforms offer **Automatically receive files** per trusted sender. New pairings enable it on both sides; existing peers keep their saved choice, and a peer with no saved choice remains off. The receiver can change this at any time. Consent and the destination are captured when a complete offer is admitted. With consent off, the receiver shows the file list and save folder for review before approval; with consent on, it validates the offer and destination before accepting. Success identifies the received files and save folder. The user can cancel an active transfer. Trust removal clears that sender’s consent.

On Android Home, a pending manual offer appears below the connected device summary and before Quick access. The file list and destination stay visible above the equal-width **Accept** and **Decline** actions.

Android can receive in the background when its existing connected-device/companion ownership permits it. Otherwise the offer stays pending until aniCe opens. Background connection also requires **Connect automatically**.

Files are written to job-owned partials, verified against their SHA-256 offer, then published without overwriting existing files. Android keeps default MediaStore entries pending until publication succeeds. Custom document providers are checked before use, but they do not guarantee atomic rename.

## Progress and recovery

Progress identifies direction, peer and file. Send progress counts receiver acknowledgements; receive progress counts successful local writes. Verification and publication remain visible after the bytes arrive. Android’s ongoing notification shows throttled byte progress for active sends and receives even while the app is open, with an operation-bound cancel action. Notification permission controls visibility in the notification shade.

Back or **Continue in background** hides Android’s Share-to-Mac panel without cancelling the job. **Cancel transfer** cancels it explicitly. The share activity remains alive while needed for temporary source-file access; process recreation does not replay a send.

On either platform, connection loss pauses an active batch and retains verified partial data and a private checkpoint for up to 15 minutes. Reconnecting to the same trusted peer over LAN resumes after prefix verification. After LAN loss, either device can explicitly continue over BLE. Cancel removes the partial; already-published files remain untouched.

Mac background transfer notifications are off by default and optional; their controls are in Settings → File transfer. While aniCe is in the background, they announce incoming offers and confirm a successfully received batch, including automatic receives, after its files are verified and saved. They require macOS notification permission, and **Show in Finder** opens that batch’s saved folder. Progress remains in the app, where success identifies the files and save folder. Notification actions stay bound to the original batch. Dismissing a window or the Edge Drop shelf does not cancel an admitted transfer.

## Limits and references

Only one batch runs at a time. There is no manual pause while a connection is healthy. Prepared offers and verified progress can recover after restart; file selection and unfinished initial hashing cannot. A Mac selection waiting for a route is process-local and is discarded if aniCe quits before the user retries, chooses Bluetooth, or cancels.

Five seconds after its previous probe, a constrained LAN sender retries when an advancing acknowledgement arrives, draining outstanding data first. Slow fallback acknowledgements do not prevent that retry. A confirmed probe within 100 ms restores the negotiated window.

LAN profile 4 supports transfer chunks up to 512 KiB; legacy profile 3 supports up to 262,016 bytes. BLE transfer chunks are 3,072 bytes. These are protocol limits, not promised transfer rates. See the [performance guide](../PERFORMANCE.md), [transfer contract](../../protocol/transfer/README.md), [LAN contract](../../protocol/lan/README.md), and [design guide](../design/DESIGN.md).
