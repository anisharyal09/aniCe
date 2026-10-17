# Android changelog

Changes to the aniCe Android app. Repository-wide changes are recorded in the [root changelog](../../CHANGELOG.md).

## [0.2.0]

### Added

- Add Find Device requests and localized alerts with a bounded alarm-stream ringing service, Stop notification/in-app dialog, permission checks, dismissal/disconnect/focus/timeout cleanup, deferred context-backed initialization and existing companion BLE ownership. Silent/Vibrate is supported without changing sound mode or alarm volume; DND and native audio policy remain authoritative.
- Bidirectional local file transfer controller and Compose UI (`TransferController`, `TransferView`, `TransferWire`, `TransferNotification`, `TransferActionReceiver`) with cumulative credit flow control, sequential multi-file streaming, Storage Access Framework document picker support, exclusive job-owned partial documents and checked provider finalization, full-duplex flow-control ACK submission, high-priority heads-up incoming transfer notifications with tap-to-open and Decline actions, and integration into Features and Home live-activity.
- Optimize LAN streaming throughput: pre-allocate 2-MiB TCP send/receive socket buffers before connect and size the read loop to one whole record, with the socket read decoupled from record delivery by a bounded ordered queue; cache validation and `kid` digest on immutable `DeviceIdentity` instances to eliminate repeated BigInteger curve point verification and `KeyFactory` JNI instantiation per record; decouple `sendOperation` and `receive` locking in `SessionConnection` so recipient flow-control ACKs stream concurrently over full-duplex TCP; pipeline flow-control ACKs every 8 chunks with multi-waiter `capacityWaiters` backpressure tracking.
- Now Playing Home controls/player picker and Features workspace over one secured LAN/BLE subscription, with source-bound commands, atomic seek/elapsed previews and LAN-only artwork. Silent native media notifications use a fixed 90-second pause grace and existing companion-owned background BLE. Verified player volume and separately advertised Mac output volume support sliders and phone/system volume controls; bounded latest-intent handling confirms previews and never replays uncertain commands.
- Home/Devices/Features/Settings bottom navigation and saved System/Light/Dark appearance across app and setup screens; use compact aniCe titles and top bars across main destinations.
- Adversarial test coverage for maximum profile-3 bounds, cipher tampering rejection, buffer independence across encryption directions, exact CBOR payload sizing, scratch framing identity, and single-copy chunk framing.

### Changed

- Document persistent Cargo/Rustup and Android SDK NDK locations for native pairing builds; incremental outputs must not conceal missing temporary tool installations.
- Rework phone navigation with branded compact Home, dedicated feature panels, separate Favourites/About and one fluid feature card per row. Keep player/source selection, compact Home volume and native scalable typography; automatic connection preferences stay in Devices to simplify Home.
- Present direct Bluetooth/LAN actions and automatic preference in Devices. Prefer connected peers, place a quiet Add device action in the persistent Devices footer, expose local identity and saved trust separately, and show clickable fingerprint disclosures with visible expansion cues. Keep Disconnect accessible on Home and add mirrored navigation chevrons, stable artwork spacing and slate playback controls.
- Keep About concise with installed version, a short purpose line, source and license links, followed by only @anisharyal09 linked to the personal website. Set version 0.2.0-dev and version code 2; document completed manual/native checks alongside the remaining test matrix.
- Parse LAN receive buffers in bounded slices with one clock sample per read; add native cumulative-credit benchmarking with payload validation, CPU/GC and socket/delivery timing. The isolated bulk probe uses bounded larger records and Debug-only Wi-Fi power ownership; production DATA and Release permissions remain unchanged.
- Remove per-record allocations and copies from the authenticated record path: one AES-GCM provider cipher, key spec and authentication suffix per direction, record headers written into the record buffer, exact-size deterministic CBOR encoding, single-copy chunk framing out of the reused transfer buffer, TCP framing into transport-owned scratch space, and one compiled device-ID pattern for journal validation. Receive validates native identity and trust after synchronous tag verification so unauthenticated records never reach Keystore. Wire bytes, bounds and typed failures are unchanged.
- Group Now Playing code and matching tests under features/nowplaying; move application BLE/LAN owners, connection feedback and nearby policy into Connections; preserve manifest entry points and stored association keys, and register media through feature-neutral secured DATA dispatch.
- Keep Home device rows compact and clickable; move full connections, pairing and diagnostics to Devices with an explicit Connection details disclosure.
- Use smaller aniCe titles on Home/Devices and aniCe Settings on Settings. Reduce top bars to 48 dp at normal text size, allow growth for large text and tighten spacing above the Devices label.
- Move local identity behind a full-width This device Settings entry; keep reset under Advanced with a compact neutral entry and destructive confirmation.
- Preserve peer/nested-route state across tabs and native Back behavior; completed pairing returns Home through the guarded connection handoff.

### Fixed

- De-churn `MediaNotification`: eliminate notification rebuild loops on every track and volume change by installing a single persistent `MediaSession.Callback` delegating dynamically to the active playback model, coalescing notification updates, deduplicating playback state changes, removing output revision churn from `providerKey`, and recovering dismissed notifications.
- Decode media artwork off the main thread in `MediaController` on `Dispatchers.Default` protected by a generation/revision/hash fence to prevent UI jank.
- Move Keystore and trust-store disk lookups during `connectPreferred()` in `LanSessionController` to background IO coroutines.
- Prevent premature LAN session cancellation during IPv6 SLAAC privacy address rotations by verifying interface presence and address retention before triggering Wi-Fi change cancellation.
- Declutter Find Device UX: replace heavy card borders with clean native peer rows, suppress redundant `"find_idle"` message when peers are connected, provide quiet permission guidance, and show truthful connection state for all paired devices.
- Integrate `"This device >"` and `"Add device >"` as sequential rows directly within the primary scrollable column on Devices screen, eliminating pinned bottom bars and duplicate trust rows.
- Align About screen design with macOS layout: configure 24 dp padding, exact website attribution link, and clean license/source navigation.
- Avoid materializing Find Device channel candidates and complete deadline inventories during routing and expiry scheduling. Preserve LAN preference, BLE fallback and existing alert deadlines.
- Report transfer direction and finalization in the file-transfer panel and its progress notification: name the peer and whether the batch is sending or receiving, state that a fully received file is being verified and saved instead of leaving the bar at 100% with no rate, mark an unavailable rate as unavailable instead of dropping the row, report an empty batch as indeterminate progress rather than as 0%, label progress for screen readers, and correct the completion notification's file count. Remove the unused transfer-panel parameters and raise the notification-permission and preparing controls to the 48 dp minimum.
- Publish received files under an available name instead of failing a verified batch: resolve taken destination names by suffixing (`name (1).ext`), confirm destination-provider renames, fall back to copying when folders cannot hold hard links, and preserve verified partials on finalization failure.
- Keep local-network sockets readable while earlier records are being processed: decouple socket reads from delivery via bounded ordered queues, size read buffers to one whole record, decode received chunks off presentation threads, and release session operation mutexes before application delivery to allow full-duplex control flushes and prevent stall amplification. Record order, admission bounds and per-record native validation are unchanged.
- Report transfer rates over a bounded rolling window instead of lifetime averages, decaying promptly on stalls and omitting rate display from notifications and finalization.
- Amortize live native validation with explicitly selected LAN profile 3: domain-separated 256-KiB records, advertised 128-KiB file chunks and at most 1 MiB of transfer credit; preserve standard BLE formats and live native identity/trust checks. On Android, remove duplicate native reads around synchronous cryptography while validating before delivery and retaining generation/deadline fences.
- Keep Android’s Connect LAN action visible in the file-transfer panel when Bluetooth is connected and LAN is disconnected.
- Replace per-byte fingerprint formatters with direct canonical lowercase hex encoding during record validation; independent SHA-256 and identity fixtures preserve existing fingerprint bytes.
- Retain the native Keystore provider connection while re-reading live aliases, public keys and key protection on every identity check; detect external deletion and same-alias replacement.
- Enforce LAN-preferred file transfer routing with BLE fallback, background lifecycle ownership, exclusive partial staging, checked finalization, and isolated reply correlation. Notification denial no longer blocks approved foreground transfers; release idle leases and stale timers deterministically, preserve approved BLE work during screen lock, and require explicit resend for interrupted batches.

Release 0.2.0 introduces remote Now Playing media controls, bidirectional LAN-preferred Local File Transfer with BLE fallback, Find Device alarm-stream ringing, and a redesigned navigation system.

## [0.1.0]

### Added

- Opt-in physical connected-idle CPU test with channel continuity, encrypted-operation validation budgets and unchanged identity/trust journal assertions.
- Foreground LAN sessions with Wi-Fi-bound sockets, scoped IPv6, bounded NSD resolution and independent Bluetooth/local-network controls.
- Notification-free companion auto-connect on API 31+ in Debug and Release, with pinned saved setup, a device-level preference and Disconnect pause. Physical endurance and minimum-OS acceptance remain pending.
- Coordinated fresh EDHOC renewal before lifetime/record limits, with encrypted backpressure, Stop and key-reuse regressions.
- HELLO/ACK compatibility and encrypted PING/PONG in the shared session controller; legacy peers retain manual operation and unsupported background probes stop.
- Adversarial control tests for malformed encodings, ordering, deadlines, backpressure, transport failure and hard session lifetime.
- Native companion association/presence handling with pinned EDHOC authentication, explicit cleanup, API 31–36 dispatch and Debug-only bounded event logs.
- Trusted Mac Connect/Disconnect/Retry controls, native AES-GCM record channel and EDHOC/BLE ordering owner, foreground cleanup and shared v1/v2 GATT transport with bounded queues and submission deadlines.
- Native EDHOC method 0 / suite 5 handshake engine with active-trust pinning, bounded deterministic CBOR, DER/COSE signature conversion, and cancellation guards.
- Pairing: CameraX QR scanning and six-digit code entry with PAKE bootstrap, bounded GATT transport with automatic cache invalidation, mutual approval, atomic peer trust persistence, and local forgetting.
- Foreground service-filtered nearby BLE discovery with on-demand permissions and bounded candidate validation.
- Persistent P-256 device identity with Android Keystore signing, actual protection reporting, and backup-excluded metadata.
- Initial Android app with aniCe top bar, device list home, and system light/dark theme using the shared palette.

### Changed

- Cap nearby retry delays at 90 seconds after jitter, with saturation/reset and invalid-jitter regressions.
- Unify device summaries, compact neutral connection controls and inline transport details. Keep checks and Debug events collapsed; pairing returns to Home and starts fresh Bluetooth work.
- Make the accent automatic checkbox observable and resume saved setup inline. Disabling automatic ownership retains eligible foreground BLE as manual work; background/lock cleanup and hard limits remain.
- Add atomic 1–64-code-point phone-name editing, compact identity details with neutral confirmed-reset controls, full trusted fingerprints and native Back/close icons. Keys and trust stay unchanged.
- Expose the existing 15-second LAN browse in progress text; preserve authenticated candidate selection and manual retry policy.
- Replace BLE/LAN maintenance polling and idle TCP read timeouts with cancellable deadline waits; use elapsed realtime for authentication, record and fragment deadlines.
- Retire both session owners from identity reset and trust-store revocation/replacement, including mutations outside presentation callbacks.
- Update Android code structure tree, test inventory, and manual LAN documentation in README.
- Load existing identity state without a signing challenge; retain creation/reset proof and validate the active journal binding and requested signature before return.
- Add file-purpose summaries to Android sources, tests, resources, manifest and build configuration.
- Document shared session controller architecture, companion device lifecycle boundaries, and native API paths in docs/BACKGROUND_CONNECTIONS.md.
- Display eight-hex-digit fingerprint prefix instead of placeholder text; complete semantic color tokens using DESIGN.md palette.
- Document session security and lifecycle invariants inline: trust revalidation, nonce ownership, readiness, bounded fragmentation, submission semantics and best-effort secret cleanup.
- Record native GATT write status and session mode in transport diagnostics without recording payloads or keys.
- Extract app shell and device-identity screen/state from MainActivity into lifecycle ViewModels.

### Fixed

- Keep BLE and LAN connected when opening discovery; only Scan suspends/retires Bluetooth, and completion restores eligible automatic work. Preserve LAN across setup navigation; device-level Disconnect, final activity stop and screen lock still retire it.
- LAN network-change and Disconnect callbacks retire their owner instead of cancelling only the callback coroutine; stale callbacks cannot close a newer attempt.
- Retire controller state and transport on authenticated Mac closure, manual disconnect and renewal requiring manual reconnection; explicitly qualify cleanup inside coroutine receivers and publish terminal feedback before retry observation.
- Restore companion ownership on same-instance rebind without presence replay and reject stale unbound callbacks.
- Read private Cargo, Rustup and NDK paths during native pairing builds; preserve explicit environment overrides.
- Cancel retired Resume results and lookup failures before they can overwrite Stop or newer setup.
- Scope automatic setup and reset to the displayed Mac; retire the previous association on explicit replacement.
- Restore native companion ownership after pause/process rebinding and observe background session/radio changes independently of Compose presentation.
- Normalize companion association addresses for native Bluetooth lookup and identify failed setup stages; collapse test diagnostics behind an explicit disclosure.
- Distinguish authenticated Mac closure and idle/lifetime limits from trust failure; serialize session health checks with incoming close processing.
- Show pairing completion and saved trust without placeholder text.
- End pairing promptly on authenticated Mac cancellation, clear temporary channel state, and show cancellation recovery message.

The foundation uses development version `0.0.0-dev` (code `1`), targets Android 16 (API 36), and has a provisional Android 10 (API 29) minimum.
