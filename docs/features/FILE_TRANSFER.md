# Local File Transfer

Send batches of 1–128 files from Features → Local file transfer over an already-authenticated local-network or Bluetooth connection. Local network has priority whenever it is secured. The peer must advertise transfer support. Bluetooth is available when local network is disconnected; it is slower and uses the existing secured BLE session. The receiver approves each batch; files transfer sequentially with bounded cumulative credit.

Updated Android and Mac apps use bounded 128-KiB LAN chunks with an authenticated 256-KiB record profile. Bluetooth retains 3-KiB chunks. Both apps must be updated to use LAN revision 2; Android can still connect to an older Mac using the original smaller LAN records. Native identity and trust checks remain live. See the [LAN profile contract](../../protocol/lan/TRANSFER_PROFILE.md).

## Connection changes

On Android, the idle Local file transfer panel exposes **Connect LAN** whenever local network is disconnected, including while Bluetooth is connected. It starts the existing trusted-Mac LAN connection flow.

Both transports must belong to the same authenticated device. Support and negotiated limits are checked separately on each connection. A new batch uses local network whenever it is secured, regardless of which connection became ready first. A batch already running on Bluetooth finishes on that connection; the next batch uses local network.

Losing the active connection ends the batch and removes its current partial file. The remaining secured connection becomes available automatically. Send the files again and approve the new batch to restart; unfinished bytes are not resumed. Files already published remain in place and are not overwritten. A new batch may create another copy of files that completed before disconnection.

## Storage and preparation

Mac reception uses the selected folder, exclusive job-owned partials, SHA-256 verification, file synchronization and non-overwriting same-filesystem publication. Storage errors produce failure rather than completion. Existing files and unrelated partials remain untouched.

Android reception opens the system folder picker. Local external-storage and Downloads document providers are accepted only after a disposable read/write/seek/flush/rename/delete probe and available-space check with a 64-MiB reserve. Incompatible providers produce readable feedback. Provider rename is not claimed to be atomic. Persistable grants acquired by the active job are released at cleanup; pre-existing permission modes are retained. Cloud providers are excluded.

Transfer v1 offers include full-file SHA-256, so senders prepare hashes before offering. Preparation runs off the UI thread, is cancellable and displays Preparing files. Streaming completion digests require a separately versioned contract; existing v1 bytes remain unchanged.

## Execution and presentation

ACKs identify the active batch/file and cannot exceed admitted bytes. File results must identify the active source and match its digest before success is accepted. Batch-result messages cannot bypass file verification. Empty files finalize without chunks. Offer assembly permits one incomplete inventory for at most ten seconds and validates aggregate counts, byte totals and unique file IDs.

Capacity refusal waits for transport events with a bounded timeout; there is no five-millisecond retry loop. Submitted records are not replayed. Progress byte counts are independent of throttled UI updates. Feature delivery is awaited in transport order. File opening, reads, receive writes, SHA-256 updates, synchronization, publication and cleanup execute on IO workers/actors; presentation state stays on its UI owner. Cancellation invalidates the job before callbacks resume. Android waits for old storage cleanup before acquiring a successor destination grant. Complete verified partials survive failed publication; corrupt partials are discarded. Capacity refusal emits no synthetic availability event that could wake its own rejected sender.

Android starts a connected-device foreground service after a visible user starts sending or approves a destination. Ownership begins during LAN connection and hashing, before the offer is submitted, and continues through destination preflight and streaming. A picker has a separate sixty-second lease; result handling acquires approved work before releasing that lease. Approved LAN and BLE jobs use the transfer service independently of companion ownership. Incoming offers alone do not acquire approved background work.

Notification permission controls progress and cancel actions in the notification drawer; it does not gate the foreground service. When permission is denied, Android retains its foreground-service notice in the system Task Manager. The permission setting is not changed automatically. A failed service start or service loss retires unowned background work. Idle LAN follows the configured background timeout after approved work finishes. Mac idle-sleep assertions belong to the active job. See [Android notification permission](https://developer.android.com/develop/ui/compose/notifications/notification-permission).

## Current limits

- Resume journals, durable checkpoints, finalization-intent recovery and coordinated LAN renewal are not implemented. Disconnect ends the job and removes its current partial. Restarting transfer is a new explicit action on the remaining connection, with LAN preferred again after reconnection.
- Resume requests receive unavailable status; accepting capability v1 does not establish resumable large-file support.
- Provider revocation, rename behavior and background phone-lock continuity need physical acceptance. SAF cannot guarantee non-overwriting atomic publication across every provider.
- The prior larger-record benchmark does not establish production 3,072-byte transfer throughput after native-key revalidation was restored. Physical application transfer on local Wi-Fi typically ranges from sub-megabit rates on degraded 2.4 GHz channels up to approximately 1–3 MB/s under favorable local network conditions(for smaller file ~10MB)), accompanied by transfer progress bar and rate display stutter on both platforms during active streaming. The 1-GiB, concurrent Now Playing latency and CPU/battery gates remain pending.

## Implementation

Android implementation and tests live under `features/transfer/`; Mac implementation and tests live under `Features/Transfer/` and `aniCeTests/Transfer/`. TransferDestination owns the Android folder grant and provider probe; TransferService presents approved foreground ownership. The existing connection and session owners retain authentication, nonce ownership and backpressure.

See the authoritative [transfer contract](../../protocol/transfer/README.md), [CDDL](../../protocol/transfer/transfer.cddl), [LAN contract](../../protocol/lan/README.md) and [design guide](../design/DESIGN.md).
