# Android changelog

Changes to the aniCe Android app. Repository-wide changes are recorded in the [root changelog](../../CHANGELOG.md).

## [Unreleased]

### Added

- Messages relays incoming SMS to the Mac over the secured session and answers Mac requests for conversation lists, paged history and replies. The panel requests RECEIVE_SMS (live), READ_SMS (conversations/history) and SEND_SMS (replies) separately, explains Android 13+ restricted settings after a permanent denial and reports unread counts and skipped rows. Reads use the conversations view with recipient resolution and fall back to the newest direct `content://sms`/`content://mms` row per thread; history pages filter by timestamp in SQL and apply the byte-wise messageId tie-break in memory. A manifest `SMS_RECEIVED` receiver decodes messages through Android telephony and combines multipart parts (NUL sanitization, deterministic `live:` IDs), live events are queued in memory for up to ten minutes without a channel and offered again every few seconds until the Mac acknowledges them (a link that has not announced its capability is asked to advertise again), and replies are sent as multipart SMS on the default subscription after every part's `sentIntent` reports success. Alphanumeric sender IDs (bank and service senders) normalize to their trimmed uppercase text, so each one keeps its own conversation and rows instead of collapsing into a single nameless one, an incoming message — or a message sent from either panel — updates its conversation in the panel list immediately (snippet and time; an incoming message also bumps the unread count) instead of waiting for a provider reload, the panel's conversation view keeps its composer directly above the newest message and loads ten messages at a time with older pages on demand ("Show older messages"), keeps another sender's live or sent row out of the open thread, and drops a "Sending" echo when its lifetime ends. A send whose provider row lands after the sentIntent resolves is re-read once after two seconds, so its echo becomes the provider row instead of showing **Sending** for its lifetime. A conversation load that is replaced by another selection is cancelled and its rows and cursor are discarded, unread counts count unread incoming rows rather than subtracting the view's all-read flag, a reply request that is retired, expired or replaced never sends for the old request and cannot clear the newer request's tracking, a history page whose batches are entirely skipped keeps scanning older batches, and a finished page carries the terminal cursor so the Mac stops offering empty older pages.

- Messages answers the v2 SIM and search requests. A SIM listing returns the phone's active subscriptions (labels, slot, default) and result 1 when READ_PHONE_STATE is missing; the composer reads that list once per conversation and offers **Send from** only when a second active subscription comes back, replies carry the chosen subscription, an unknown or inactive one fails with result 4 and is never retried on another SIM, and the choice is never persisted. Search matches SMS bodies and text/plain MMS parts with `LIKE … ESCAPE '\'` escaping, streams hits as ordinary message records with history's ordering, cursor and tie rules, resolves matching MMS ids from the mms table newest-first so page boundaries never depend on part order, caps the scan at 2,048 rows (result 4 beyond) and rejects a query shorter than 2 UTF-8 bytes with result 6, cancels an in-flight page when a newer search arrives, and reports skipped rows exactly like history. The manifest gains READ_PHONE_STATE, and the phone default, history and search all work without it.

- Messages serves v3 thread cursors and per-message subscription attribution. The thread list request carries a `(dateMillis, threadId)` cursor: the store reads a `limit + 32` provider window at or below the boundary, resolves unread counts and fallback metadata, then applies the exact cursor filter and byte-wise ordering in memory and reports a cursor only while another page exists. Provider history rows and live events carry the subscription that produced them (0 for MMS or unreadable provider metadata), the receiver keeps the framework's subscription metadata when combining multipart parts, and a live message id mixes the subscription in so two SIM copies of identical text at the same moment stay distinct — a provider copy merges only when the subscriptions agree or either is unknown. The panel's conversation list loads 15 conversations first and continues from the returned cursor as its last row composes, a conversation that mixes two known subscriptions shows a SIM chip on rows with a readable origin (outgoing rows on the default read **Phone default**) and groups messages under day separators, and a sent reply's echo carries the resolved subscription.

- Send to Mac through supported text-selection menus, the text Share sheet and a Quick Settings tile with a compact screen-and-arrow icon. The tile uses native placement setup, one focused capture and sensitive-text confirmation. Clipboard retains Share/History views, with optional device-local history limited to 20 items, date groups, source-device labels and Copy/Send/Delete controls. Home shows the latest successful clipboard activity for five minutes with an eligible-text preview and local Copy.

- Strict local verification gate for the shared JVM/Android checks. It parses JUnit reports and rejects zero-test runs, failures, crashes, truncated reports and undocumented skips; shared vector generators now support `--check` drift validation.

- Clipboard panel and shared per-peer settings, actual-focus automatic reading, marked background incoming writes, sensitive-content confirmation and bounded LAN/BLE delivery with idempotent fallback. Manual sends survive automatic clipboard changes during preparation; disabling automatic sharing immediately cancels pending automatic preparation. A focus-triggered sample waits for clipboard negotiation when the connection becomes ready after aniCe opens.

- Resilient file transfers: a mid-stream LAN or Bluetooth loss now pauses with retained partial storage, frozen progress and a paused ongoing notification. A reconnected LAN to the same peer resumes automatically at the verified offset; either device can explicitly continue over Bluetooth when LAN stays down, with the receiver asking the sender to validate the prefix it holds. Cancel deletes the partial, and a 15-minute pause timeout fails and cleans it up.
- A receiver-initiated Bluetooth continuation now works end to end: the receiving device hashes its retained bytes, sends the resume request itself, and the sender answers with the validated offset. A live LAN that becomes capable during a Bluetooth stream upgrades the active transfer in place, so the stream moves off Bluetooth as soon as Wi-Fi reconnects.
- Automatic LAN is on when no preference has been stored; a stored off still wins, and pairing exposes one post-pairing toggle for both Bluetooth and LAN. Authenticated BLE readiness coordination permits one bounded foreground Wi-Fi initiation on BLE/eligibility events, successful BLE feature traffic, file selection, companion media demand or explicit transfer demand, without independent LAN retries. The background idle timeout defaults to Never while preserving saved finite choices.
- Background companion playback holds a bounded media demand lease while playing or inside the paused grace, so Now Playing can request and retain LAN (and receive artwork) in the background.

### Changed

- Clipboard and file sending use quiet outlined icon-and-label controls. Clipboard preferences use the compact LAN-style checkbox; History shows a saved-count and Clear all toolbar.

- Messages: the phone serves the thread list and history pages within the limits the Mac advertised on that link, the panel shows live relay counts (relayed, waiting, not relayed), and a live event with no authenticated Mac reads **Waiting for the Mac** instead of claiming delivery.

- Clipboard help explains Share → Send to Mac for text and links, the small sending panel, and the difference between manual sending and focus-limited automatic sharing.

### Fixed

- SMS reception uses the platform decoder for GSM/CDMA and framework multipart batches, with bounded broadcast completion. Live acknowledgements validate result and channel; expired queues and replies are retired, duplicate reply commits reuse bounded in-memory results, and provider paging preserves each source position and rejects oversized timestamp groups.

- A lost active connection no longer fails the batch or deletes its verified partial; streaming losses pause instead, and paused batches keep the transfer foreground service, LAN work lease and a secured BLE fallback lease so automatic LAN or explicit Bluetooth continuation can resume them.
- Continuing over Bluetooth no longer causes the BLE channel to connect and disconnect repeatedly, and the paused card/notification offers Continue over Bluetooth on the receiving device as well as the sender.
- Selecting files or starting a send no longer retires a secured BLE channel: picker leases follow secured transports instead of the transfer's transiently selected channel, and a LAN attempt preserves existing transfer leases.
- A failed LAN demand now fails a waiting send immediately instead of waiting for the connect timeout; a send with an already-secured compatible channel proceeds on it without waiting for LAN.
- Feature traffic and playback demand no longer clear an explicit LAN Disconnect; manual reconnect or a preference change resumes automation.
- Snapshot blocked transfer senders before resuming capacity waiters, preventing startup capability exchange from spinning on the main thread when BLE remains busy.
- Settings collapses the background-timeout choices into one row (default Never) and renames the LAN toggle to Use local network automatically.

## [0.2.0]

### Added

- **Find Device**:
  - Request and receive Find Device alerts with bounded alarm-stream ringing service that plays even in Silent/Vibrate mode.
  - Dedicated in-app dialog and high-priority notification with explicit "Stop ringing" action.
  - Localized `find_connected` status and peer-specific accessibility action labels (`find_peer_action` -> "Find %1$s").
  - Automatic 60-second alert timeout, audio-focus handling, and companion BLE background ownership.
- **Local File Transfer**:
  - Full bidirectional transfer controller and Compose UI (`TransferController`, `TransferView`, `TransferWire`).
  - 64-chunk cumulative credit flow control, sequential multi-file batch streaming, and incremental SHA-256 validation.
  - Storage Access Framework (SAF) document picker integration, exclusive partial staging, and checked non-overwriting renames.
  - High-priority heads-up transfer notifications with tap-to-open and Decline actions.
  - LAN throughput optimization: pre-allocated 2-MiB TCP send/receive socket buffers, decoupled record delivery via bounded queue, cached `DeviceIdentity` cryptographic verification, concurrent recipient ACKs over full-duplex TCP, and pipelined flow-control ACKs every 8 chunks.
- **Now Playing & Media Controls**:
  - Remote playback controls, player selector, and Features workspace over secured LAN/BLE.
  - Source-bound commands, atomic seek and elapsed previews, and LAN-only artwork fetching.
  - Silent media notifications with 90-second pause grace and background BLE lease.
  - Verified player volume and separately advertised Mac output volume controls.
- **Native Navigation & Appearance**:
  - Bottom navigation bar with Home, Devices, Features, and Settings destinations.
  - Branded compact aniCe top bar and System/Light/Dark theme selector with persistent state.
  - Dedicated About screen with installed version, project credits, source repository, and quiet support link (`ic_heart`).
- **Test & Conformance Coverage**:
  - 218 automated JVM unit tests with 0 failures and 0 skips.
  - Adversarial test coverage for LAN profile 3 bounds, cipher tampering rejection, buffer independence, exact CBOR sizing, and single-copy framing.

### Changed

- **Navigation & Layout**: Reworked phone navigation with branded compact Home, dedicated feature panels, fluid card rows, and isolated Devices view.
- **Device Management**: Grouped Bluetooth and LAN actions by connected peer in Devices, separated local identity from saved trust, and added clickable fingerprint disclosures.
- **Record Pipeline & Zero-Copy**: Reused AES-GCM provider ciphers and key specs per direction; encoded CBOR directly into exact-size buffers and eliminated intermediate byte copies during chunk framing.
- **Code Organization**: Grouped Now Playing under `features/nowplaying`, isolated connection owners under `infrastructure/connections`, and moved media dispatch into secured data handlers.
- **Code Hygiene**: Formatted `MediaController.kt` to idiomatic Kotlin by unpacking multi-statement lines, standardizing operator spacing, and removing semicolons without changing coroutine flow or logic.
- **Find Device Cleanup**: Removed dead `FindDeviceSetup` wrapper, removed stale import in `FeaturesScreen.kt`, and dropped unused `hasAvailablePeer` parameter and dead early return in `FindDeviceFeedback`.
- **Tooling & Prerequisites**: Documented persistent Cargo/Rustup and Android NDK paths for offline native JNI pairing rebuilds (arm64-v8a, armeabi-v7a, x86_64) with 16-KiB alignment checks.

### Fixed

- **Now Playing Playback**: Eliminated seekbar thumb jumps during drag gestures, reserved stable artwork dimensions to prevent layout shift, and retained controls across track metadata changes.
- **Media Controller**: Deduplicated playback state, coalesced notification updates, ignored output-only provider churn, and properly restored dismissed notifications.
- **Find Device Routing**: Avoided materializing candidate channels and full deadline lists during route resolution; preserved LAN preference with BLE fallback.
- **Transfer Publication**: Suffix duplicate destination file names atomically (`name (1).ext`), confirmed SAF provider renames, fell back to copying when folders reject hard links, and preserved verified partials on disk if finalization fails.
- **LAN Ingress**: Decoupled socket reads from delivery through bounded queues, sized read buffers to whole records, and released session mutexes before application delivery to allow concurrent full-duplex ACKs and prevent stalls.
- **Transfer Rates & Progress**: Calculated transfer speed using a bounded rolling sample window that decays promptly on stalls, marked unavailable rates explicitly, labeled progress for screen readers, and corrected notification counts.
- **LAN Profile 3 Negotiation**: Correctly negotiated domain-separated 256-KiB LAN records with 128-KiB chunks and up to 1 MiB credit while maintaining live native validation.
- **Connection Retention**: Retained active Android LAN sessions during temporary IPv6 address rotation when interface addresses remain valid, and kept Connect LAN visible when only Bluetooth is connected.
- **Keystore & Identity**: Reused Keystore provider instances while re-validating live aliases, public keys, and key protection on every operation to catch external deletions or replacements.
- **Transfer Lifecycle**: Enforced LAN preference with BLE fallback, exclusive partial staging, and deterministic timer releases so notification denial never halts approved foreground transfers.

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
