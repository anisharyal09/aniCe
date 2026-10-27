# Android changelog

Changes to the aniCe Android app. Repository-wide changes are recorded in the [root changelog](../../CHANGELOG.md).

## [Unreleased]

### Added

- Record stale GATT callback drops and include connection/write failure stage, status, MTU, queue depth, write state, and operation epoch in BLE transport diagnostics. Successful fragment callbacks no longer emit routine log entries.

- Parameterize the isolated raw TCP diagnostic by payload size and Wi-Fi lock request, reporting lock ownership alongside bidirectional rates and checksum results.

- Opt-in LAN timings distinguish writer admission, IO dispatch, blocking socket writes and reads.

- Queue authenticated transfer chunks in a bounded FIFO before returning to shared feature delivery. Count active writes against capacity, preserve write/ACK order, invalidate pending work on cancellation or retirement, and drain accepted work on normal EOF or authenticated close. Run receiver storage, provider setup, cleanup and checkpoint writes on one injected single-parallelism IO dispatcher, with opt-in ingress and storage wait/work timing.

- Bound unsealed DATA admission to eight waiting callers, prioritize standard-sized requests ahead of large chunks, and grant bulk a turn after four small-record requests. Cancellation and retirement clear waiting admissions before sealing. Transfer cleanup cancels queued stream, ACK and upgrade work; nonce-owned submission and post-write validation finish under session ownership. Opt-in timing separates admission, ingress backpressure, validation, encryption and authenticated receive delivery, with monotonic stage timestamps and record direction/profile/sequence correlation.

- Messages provides SMS permission setup, live relay, paged conversations and history, phone-side search and active-SIM selection over existing secured sessions. Multipart replies report radio acceptance or an unconfirmed outcome without automatic resend. Provider scans complete timestamp groups and retain continuation cursors across unreadable batches; partial reads preserve completed state. Live receipts and sends keep local observation order when carrier clocks differ. The composer keeps SIM choice on the left and Send SMS at the far-right edge, with keyboard sending and readable long-label truncation.

- Send to Mac through supported text-selection menus, the text Share sheet and a Quick Settings tile with a compact screen-and-arrow icon. The tile uses native placement setup, one focused capture and sensitive-text confirmation. Clipboard retains Share/History views, with optional device-local history, 20/50/100-item capacity choices, date groups, source-device labels and Copy/Send/Delete controls. Home shows the latest successful clipboard activity for five minutes with an eligible-text preview and local Copy.

- Strict local verification gate for the shared JVM/Android checks. It parses JUnit reports and rejects zero-test runs, failures, crashes, truncated reports and undocumented skips; shared vector generators now support `--check` drift validation.

- Clipboard panel and shared per-peer settings, actual-focus automatic reading, marked background incoming writes, sensitive-content confirmation and bounded LAN/BLE delivery with idempotent fallback. Manual sends survive automatic clipboard changes during preparation; disabling automatic sharing immediately cancels pending automatic preparation. A focus-triggered sample waits for clipboard negotiation when the connection becomes ready after aniCe opens.

- Resilient file transfers: a mid-stream LAN or Bluetooth loss now pauses with retained partial storage, frozen progress and one silent service notice. A reconnected LAN to the same peer resumes automatically at the verified offset; either device can explicitly continue over Bluetooth when LAN stays down, with the receiver asking the sender to validate the prefix it holds. Cancel deletes the partial, and a 15-minute pause timeout fails and cleans it up.
- A receiver-initiated Bluetooth continuation now works end to end: the receiving device hashes its retained bytes, sends the resume request itself, and the sender answers with the validated offset. A live LAN that becomes capable during a Bluetooth stream upgrades the active transfer in place, so the stream moves off Bluetooth as soon as Wi-Fi reconnects.
- Automatic LAN is on when no preference has been stored; a stored off still wins, and pairing exposes one post-pairing toggle for both Bluetooth and LAN. Authenticated BLE readiness coordination permits one bounded foreground Wi-Fi initiation on BLE/eligibility events, successful BLE feature traffic, file selection, companion media demand or explicit transfer demand, without independent LAN retries. The background idle timeout defaults to Never while preserving saved finite choices.
- Background companion playback holds a bounded media demand lease while playing or inside the paused grace, so Now Playing can request and retain LAN (and receive artwork) in the background.

### Changed

- Resolve LAN services during the bounded browse and stream at most eight deduplicated endpoints into authentication. Stop remaining discovery on selected-peer secured readiness; route producer failures through connection error handling, fence lost services and late callbacks, serialize legacy resolution, and release browse resources on consumer exit, cancellation or deadline.

- Qualify large LAN transfer windows with a small acknowledged startup chunk. Delayed acknowledgement constrains subsequent sender backlog to at most two 65,536-byte chunks within peer credit, amortizing native validation without restoring the full bulk window; drained senders can requalify after five seconds, each file/resume probes afresh, and fast paths retain negotiated large chunks.

- LAN rendezvous retains capacity notifications arriving during a pending submission. Frame-bounded LAN reads keep ingress queue waits outside the next frame's assembly deadline. Playback and volume actions that expire before submission report that they were not sent; submitted actions with missing results remain uncertain and are never replayed.

- Foreground and companion-service handoffs retain Bluetooth retry history and candidate exclusions until authenticated readiness remains stable.
- Bluetooth setup validates the existing discovery payload before subscribing to replies; stale read targets and duplicate pairing profiles share the single service-cache refresh budget without retrying authentication errors. Persistent duplicate profiles stop connection setup without assuming extra Mac app copies are running.

- Keep capable Bluetooth available while LAN capability is pending. Repeat bounded rediscovery after failed automatic attempts, reset backoff only after stable readiness, and preserve native GATT write failures through teardown.


- Session-control classification avoids copying file payloads before feature decoding while retaining CBOR validation.
- LAN write watchdog failures preserve their timeout cause instead of reporting session expiry or generic cancellation.

- File-transfer source opening and delayed completion discard retired batch callbacks before touching replacement state.
- File-transfer ACK failures wait for a new capacity or receive event instead of immediately resubmitting themselves.

- Bluetooth setup refreshes a stale service cache once when macOS rejects an indication subscription with status 3 or 245, sharing the existing invalid-handle recovery budget. Persistent rejection preserves the native status; authentication and authorization errors do not trigger a refresh.

- Advertise a capability-2 baseline before negotiating 262,016-byte LAN file-transfer chunks with capability 3; older peers retain their supported limits.

- Clipboard and file sending use quiet outlined icon-and-label controls. Clipboard preferences use the compact LAN-style checkbox; History shows a saved-count and Clear all toolbar. Pausing collection preserves saved history across app restarts, Forget device and Reset identity; Clear/Delete remain explicit. Clipboard content has a small horizontal inset.

- Clipboard help explains Share → Send to Mac for text and links, the small sending panel, and the difference between manual sending and focus-limited automatic sharing.

### Fixed

- Retire LAN when its bound local address disappears, detect address restoration on the same Wi-Fi network, and retain pending reconnect requests until channel retirement.

- Gate LAN recovery probes on one second of timely advancing ACKs, and return credit immediately for qualification probes and chunks smaller than the negotiated LAN maximum.

- Run receiver resume verification and channel rebinding in the chunk FIFO so later old-channel writes cannot invalidate the reported resume offset.

- Give the raw TCP diagnostic's final receiver-confirmation ACK sixty seconds to drain locally accepted TCP backlog; data reads retain their ten-second no-progress bound.

- Preserve immediate native Bluetooth write-submission errors through adapter teardown and pending-send completion. Distinguish synchronous `BluetoothStatusCodes` from asynchronous GATT completion status; legacy rejection reports unavailable status without inventing a code.

- Stop resetting transfer-owned Bluetooth retry history immediately at secured readiness. Evaluate the existing fifteen-second stability deadline across progress transitions and clear it on recovery cancellation; retain the bounded retry schedule for short-lived connections.

- Preserve replacement credit waiters when immediate coroutine resumption shrinks the LAN send window. Re-arm ACK coalescing for newer written bytes after a pending ACK succeeds, without retrying failed submissions in a loop.

- Tolerate progressing encrypted LAN frames after secured readiness with a ten-second no-progress deadline and sixty-second absolute assembly cap. Partial headers and handshake frames retain ten seconds absolute; wire bytes, record authentication and socket write deadlines are unchanged.

- Retire failed authenticated DATA submissions through their BLE/LAN owner while preserving recoverable backpressure and native Bluetooth subscription error statuses.
- Bound unsubmitted media intents, coalesce continuous controls and show explicit pending/expiry feedback; uncertain commands never replay across connections.

- Allow environment-configured native pairing builds without `local.properties`, while retaining incremental input tracking for local tool overrides when present.

- Cap GATT fragment values at 512 bytes when MTU 517 would otherwise create invalid 514-byte writes, and refresh a stale descriptor handle within the existing single layout retry. Serialize session control issuance with receive/maintenance so concurrent DATA cannot issue a stale pending control on BLE or LAN. Coalesce concurrent BLE connection requests, recover saved setup on foreground return, and bound stale-locator rediscovery. Transfer leases survive channel replacement; BLE credits leave ingress headroom, admitted records finish across route changes, and prepared jobs retain checkpointed progress and completion receipts across restarts for 15 minutes. Publish terminal LAN state before retirement callbacks so paused work can request reconnection. Reduce routine checkpoint flushes and retain only silent service/background-offer notices. Show the active transfer route and log negotiated source limits and LAN failure categories. Wait for requested LAN setup for a bounded interval before falling back to a compatible Bluetooth offer, and measure transfer rates over a five-second window.

- Prefer negotiated LAN for transfers, bound traffic-triggered LAN attempts, and report receiver-confirmed progress with consistent speed sampling and stalled-rate refreshes.

- SMS reception uses the platform decoder for GSM/CDMA and framework multipart batches, with bounded broadcast completion. Live acknowledgements validate result and channel; expired queues and replies are retired, duplicate reply commits reuse bounded in-memory results, and provider paging preserves each source position and rejects oversized timestamp groups.

- A lost active connection no longer fails the batch or deletes its verified partial; streaming losses pause instead, and paused batches keep the transfer foreground service, LAN work lease and a secured BLE fallback lease so automatic LAN or explicit Bluetooth continuation can resume them.
- Continuing over Bluetooth no longer causes the BLE channel to connect and disconnect repeatedly, and the paused card offers Continue over Bluetooth on the receiving device as well as the sender.
- Selecting files or starting a send no longer retires a secured BLE channel: picker leases follow secured transports instead of the transfer's transiently selected channel, and a LAN attempt preserves existing transfer leases.
- A failed LAN demand now releases a waiting send to the best secured channel immediately. A requested LAN route gets a bounded rendezvous before a ready Bluetooth channel carries the offer, so transfers do not start on Bluetooth while Wi-Fi is still connecting.
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
