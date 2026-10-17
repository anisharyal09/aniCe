# Local File Transfer

Send batches of 1–128 files from the device overview over an already-authenticated local-network or Bluetooth connection. Local network has priority whenever it is secured. The peer must advertise transfer support. Bluetooth is available when local network is disconnected; it is slower and uses the existing secured BLE session. The receiver approves each batch; files transfer sequentially with bounded cumulative credit.

Updated Android and Mac apps use bounded 128-KiB LAN chunks with an authenticated 256-KiB record profile. Bluetooth retains 3-KiB chunks. Both apps must be updated to use LAN revision 2; Android can still connect to an older Mac using the original smaller LAN records. Native identity and trust checks remain live. See the [LAN profile contract](../../protocol/lan/TRANSFER_PROFILE.md).

## Connection changes

On Android, Connection details exposes local-network connection controls. The idle file panel presents Send files; when disconnected, that action can start the existing trusted-Mac LAN flow. File selection on both devices requests automatic LAN setup through an existing secured BLE channel when enabled on both devices. The current batch still uses the best already-secured channel; switching an active transfer between BLE and LAN is not implemented.

Both transports must belong to the same authenticated device. Support and negotiated limits are checked separately on each connection. A new batch uses local network whenever it is secured, regardless of which connection became ready first. A batch already running on Bluetooth finishes on that connection; the next batch uses local network.

Losing the active connection ends the batch and removes its current partial file. The remaining secured connection becomes available automatically. Send the files again and approve the new batch to restart; unfinished bytes are not resumed. Files already published remain in place and are not overwritten. A new batch may create another copy of files that completed before disconnection.

## Storage and preparation

Mac reception uses the selected folder, exclusive job-owned partials, SHA-256 verification, file synchronization and non-overwriting same-filesystem publication. Storage errors produce failure rather than completion. Existing files and unrelated partials remain untouched.

Android reception opens the system folder picker. Local external-storage and Downloads document providers are accepted only after a disposable read/write/seek/flush/rename/delete probe and available-space check with a 64-MiB reserve. Incompatible providers produce readable feedback. Provider rename is not claimed to be atomic. Persistable grants acquired by the active job are released at cleanup; pre-existing permission modes are retained. Cloud providers are excluded.

Transfer v1 offers include full-file SHA-256, so senders prepare hashes before offering. Preparation runs off the UI thread, is cancellable and displays Preparing files. Streaming completion digests require a separately versioned contract; existing v1 bytes remain unchanged.

## Execution and presentation

ACKs identify the active batch/file and cannot exceed admitted bytes. File results must identify the active source and match its digest before success is accepted. Batch-result messages cannot bypass file verification. Empty files finalize without chunks. Offer assembly permits one incomplete inventory for at most ten seconds and validates aggregate counts, byte totals and unique file IDs.

Capacity refusal waits for transport events with a bounded timeout; there is no five-millisecond retry loop. Submitted records are not replayed. Progress byte counts are independent of throttled UI updates. Feature delivery is awaited in transport order. File opening, reads, receive writes, SHA-256 updates, synchronization, publication and cleanup execute on IO workers/actors; presentation state stays on its UI owner. Cancellation invalidates the job before callbacks resume. Android waits for old storage cleanup before acquiring a successor destination grant. Complete verified partials survive failed publication; corrupt partials are discarded. Capacity refusal emits no synthetic availability event that could wake its own rejected sender.

Both panels name the peer and the direction of the active batch, and Android's progress notification reports the same direction and completion wording. A rate that is not yet measurable is presented as unavailable rather than as zero, and an empty batch reports indeterminate progress rather than zero progress. A received file whose bytes have all landed but which is still being hashed and published is presented as verifying and saving instead of as a stalled transfer, and the direction outlives cleanup so a completed batch still reports which way the files moved.

Android starts a connected-device foreground service after a visible user starts sending or approves a destination. Ownership begins during LAN connection and hashing, before the offer is submitted, and continues through destination preflight and streaming. A picker has a separate sixty-second lease; result handling acquires approved work before releasing that lease. Approved LAN and BLE jobs use the transfer service independently of companion ownership. Incoming offers alone do not acquire approved background work.

Notification permission controls progress, incoming offer alerts, and cancel actions in the notification drawer; it does not gate the foreground service. Android posts a high-priority notification with file count and size when an incoming offer arrives, with tap-to-open and a Decline action. When permission is denied, Android retains its foreground-service notice in the system Task Manager. The permission setting is not changed automatically. A failed service start or service loss retires unowned background work. Idle LAN follows the configured background timeout after approved work finishes. Mac idle-sleep assertions belong to the active job. See [Android notification permission](https://developer.android.com/develop/ui/compose/notifications/notification-permission).

Mac posts native notifications (`UNUserNotificationCenter`) on incoming offers with interactive **Accept** (saving by default to `~/Downloads`), **Choose folder…** (activating aniCe with the offer visible for custom destination selection), and **Decline**, plus a completion notice with **Show in Finder**. Notification permission is requested lazily on first need; when denied or dismissed, the offer remains interactive in the menu-bar companion and main window without gating transfer execution. The companion hosts a compact transfer live activity with rate/progress and cancel, shown alongside Now Playing with visible supported seek, falling back to in-app presentation when unattended banners are disabled.

## Verification

Manual application testing covers transfers in both directions and playback during Phone→Mac transfer. Physical application transfer over a 5 GHz mobile hotspot (external AP) measures 7.0–10.5 MB/s (average ~8.0 MB/s) Mac→Phone, and 3.0–5.2 MB/s (average ~4.0 MB/s) Phone→Mac; an attenuated 2.4 GHz router (3–5m range) measures ~1.0 MB/s symmetrically. Bounded ingress queues and off-main chunk decoding resolve previous progress and rate presentation stuttering. The 1-GiB, concurrent Now Playing latency, CPU/battery, and phone-hosted hotspot loopback routing gates remain open.

## Current limits

- Resume journals, durable checkpoints, finalization-intent recovery and coordinated LAN renewal are not implemented. Disconnect ends the job and removes its current partial. Restarting transfer is a new explicit action on the remaining connection, with LAN preferred again after reconnection.
- Resume requests receive unavailable status; accepting capability v1 does not establish resumable large-file support.
- Provider revocation, rename behavior and background phone-lock continuity need physical acceptance. SAF cannot guarantee non-overwriting atomic publication across every provider.

## Implementation

Android implementation and tests live under `features/transfer/`; Mac implementation and tests live under `Features/Transfer/` and `aniCeTests/Transfer/`. TransferDestination owns the Android folder grant and provider probe; TransferService presents approved foreground ownership. The existing connection and session owners retain authentication, nonce ownership and backpressure.

See the authoritative [transfer contract](../../protocol/transfer/README.md), [CDDL](../../protocol/transfer/transfer.cddl), [LAN contract](../../protocol/lan/README.md) and [design guide](../design/DESIGN.md).
