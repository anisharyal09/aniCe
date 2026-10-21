# Local File Transfer

Send batches of 1–128 files from the device overview over an already-authenticated local-network or Bluetooth connection. Local network has priority whenever it is secured. The peer must advertise transfer support. Bluetooth is available when local network is disconnected; it is slower and uses the existing secured BLE session. The receiver approves each batch; files transfer sequentially with bounded cumulative credit.

Updated Android and Mac apps use LAN chunks up to 262,016 bytes with an authenticated 256-KiB record profile. Bluetooth retains 3-KiB chunks. Both apps must be updated to use the new transfer capability for larger chunks; older peers retain their negotiated limits. Native identity and trust checks remain live. See the [LAN profile contract](../../protocol/lan/TRANSFER_PROFILE.md).

## Connection changes

On Android, Connection details exposes local-network connection controls. The idle file panel presents Send files; when disconnected, that action can start the existing trusted-Mac LAN flow. File selection on both devices requests automatic LAN setup through an existing secured BLE channel when enabled on both devices. The current batch stays on its channel while that channel remains connected, except that a capable local network upgrades an active Bluetooth stream as described below.

Both transports must belong to the same authenticated device. Support and negotiated limits are checked separately on each connection. A new batch uses local network whenever it is secured, regardless of which connection became ready first. A batch already running on Bluetooth stays there unless local network becomes capable to the same peer, in which case the sender upgrades the active stream in place through the resume handshake. If local network arrives while the sender is between files, the upgrade happens at the next file.

Losing the active connection while a batch is streaming pauses the batch instead of failing it. Both devices keep their verified partial and last acknowledged offset, show a paused card with frozen progress, and retain the partial in process memory for 15 minutes. Reconnecting local network to the same peer resumes automatically: the sender requests the retained offset and the receiving side verifies the prefix digest before continuing. If local network stays down while a secured Bluetooth channel exists, either device may choose Continue over Bluetooth. The sending device resumes directly from its acknowledged offset; the receiving device asks the sender to validate the prefix it already holds and stream the rest over Bluetooth, so the receiver never depends on the sender noticing the request. A Bluetooth continuation upgrades to local network automatically when a capable channel appears. Cancel deletes the partial immediately; the 15-minute timeout fails the batch and deletes it. Channel loss before streaming or during finalization still ends the batch. Files already published remain in place and are not overwritten. Pause is automatic on transport loss; there is no manual pause action while a channel is healthy.

Android source selection waits for the requested LAN connection and its transfer capability before preparing the offer. A failed or timed-out LAN request can use a compatible secured Bluetooth channel when no LAN channel remains. A secured channel whose capability is still arriving gets a bounded capability wait.

Sender progress counts receiver-acknowledged writes; receiver progress counts successful local writes. Rate samples are collected at least 250 ms apart, independently of chunk-driven progress updates. The bounded rate window therefore retains a consistent time span through bursts and decays during a stalled stream.

## Storage and preparation

Mac reception uses the selected folder, exclusive job-owned partials, SHA-256 verification, file synchronization and non-overwriting same-filesystem publication. Storage errors produce failure rather than completion. Existing files and unrelated partials remain untouched.

Android reception opens the system folder picker. Local external-storage and Downloads document providers are accepted only after a disposable read/write/seek/flush/rename/delete probe and available-space check with a 64-MiB reserve. Incompatible providers produce readable feedback. Provider rename is not claimed to be atomic. Persistable grants acquired by the active job are released at cleanup; pre-existing permission modes are retained. Cloud providers are excluded.

Transfer v1 offers include full-file SHA-256, so senders prepare hashes before offering. Preparation runs off the UI thread, is cancellable and displays Preparing files. Streaming completion digests require a separately versioned contract; existing v1 bytes remain unchanged.

## Execution and presentation

ACKs identify the active batch/file and cannot exceed admitted bytes. File results must identify the active source and match its digest before success is accepted. Batch-result messages cannot bypass file verification. Empty files finalize without chunks. Offer assembly permits one incomplete inventory for at most ten seconds and validates aggregate counts, byte totals and unique file IDs.

Capacity refusal waits for transport events with a bounded timeout; there is no five-millisecond retry loop. Submitted records are not replayed. Progress byte counts are independent of throttled UI updates. Feature delivery is awaited in transport order. File opening, reads, receive writes, SHA-256 updates, synchronization, publication and cleanup execute on IO workers/actors; presentation state stays on its UI owner. Cancellation invalidates the job before callbacks resume. Android waits for old storage cleanup before acquiring a successor destination grant. Complete verified partials survive failed publication; corrupt partials are discarded. Capacity refusal emits no synthetic availability event that could wake its own rejected sender.

Both panels name the peer and the direction of the active batch, and Android's progress notification reports the same direction and completion wording. A rate that is not yet measurable is presented as unavailable rather than as zero, and an empty batch reports indeterminate progress rather than zero progress. A received file whose bytes have all landed but which is still being hashed and published is presented as verifying and saving instead of as a stalled transfer, and the direction outlives cleanup so a completed batch still reports which way the files moved.

Android starts a connected-device foreground service after a visible user starts sending or approves a destination. Ownership begins during LAN connection and hashing, before the offer is submitted, and continues through destination preflight and streaming. A picker has a separate sixty-second lease; result handling acquires approved work before releasing that lease. Approved LAN and BLE jobs use the transfer service independently of companion ownership. Incoming offers alone do not acquire approved background work.

Notification permission controls progress, incoming offer alerts, and cancel actions in the notification drawer; it does not gate the foreground service. Android posts a high-priority notification with file count and size when an incoming offer arrives, with tap-to-open and a Decline action. A paused batch keeps an ongoing paused notification with frozen progress and Cancel; a paused batch on either device additionally gets Continue over Bluetooth when a secured Bluetooth channel is available. When permission is denied, Android retains its foreground-service notice in the system Task Manager. The permission setting is not changed automatically. A failed service start or service loss retires unowned background work. Idle LAN follows the configured background timeout after approved work finishes. A paused batch keeps its approved transfer lease, LAN eligibility and a secured BLE fallback lease so automatic LAN and explicit Bluetooth continuation can reconnect; an explicit Disconnect still pauses automation. Mac idle-sleep assertions belong to the active or paused job. See [Android notification permission](https://developer.android.com/develop/ui/compose/notifications/notification-permission).

Mac posts native notifications (`UNUserNotificationCenter`) on incoming offers with interactive **Accept** (saving by default to `~/Downloads`), **Choose folder…** (activating aniCe with the offer visible for custom destination selection), and **Decline**, plus a completion notice with **Show in Finder**. A paused batch posts a paused notification with **Cancel transfer** and, when Bluetooth continuation is available, **Continue over Bluetooth** on either device. Notification permission is requested lazily on first need; when denied or dismissed, the offer remains interactive in the menu-bar companion and main window without gating transfer execution. The companion hosts a compact transfer live activity with rate/progress and cancel, shown alongside Now Playing with visible supported seek, falling back to in-app presentation when unattended banners are disabled.

## Verification

Manual application testing covers transfers in both directions and playback during Phone→Mac transfer. Physical application transfer over a 5 GHz mobile hotspot (external AP) measures 7.0–10.5 MB/s (average ~8.0 MB/s) Mac→Phone, and 3.0–5.2 MB/s (average ~4.0 MB/s) Phone→Mac; an attenuated 2.4 GHz router (3–5m range) measures ~1.0 MB/s symmetrically. Bounded ingress queues and off-main chunk decoding resolve previous progress and rate presentation stuttering.

## Current limits

- Pause/resume state is in memory for the running process. Process death loses the paused batch and may leave a stale partial; there is no durable journal, checkpoint, cross-launch resume or finalization-intent recovery.
- Pause is a consequence of transport loss; there is no manual pause while a channel is healthy, because the peer has no wire message for one.
- A batch only changes transport through the resume handshake to the same authenticated peer: a newly capable LAN upgrades an active Bluetooth stream, and a channel change after a pause rebinds the retained prefix. Either side may initiate a resume; the receiving side always validates it.
- After a local-network pause, Bluetooth continuation requires an explicit action on either device. A paused batch is abandoned after 15 minutes.
- SAF cannot guarantee non-overwriting atomic publication across every provider.

## Implementation

Android implementation and tests live under `features/transfer/`; Mac implementation and tests live under `Features/Transfer/` and `aniCeTests/Transfer/`. TransferDestination owns the Android folder grant and provider probe; TransferService presents approved foreground ownership. The existing connection and session owners retain authentication, nonce ownership and backpressure.

See the authoritative [transfer contract](../../protocol/transfer/README.md), [CDDL](../../protocol/transfer/transfer.cddl), [LAN contract](../../protocol/lan/README.md) and [design guide](../design/DESIGN.md).
