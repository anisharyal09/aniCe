# Repository changelog

Repository-wide structure, documentation, and development conventions belong here. Android, macOS, and protocol changes maintain dedicated component changelogs under unified project releases:

- [Android](apps/android/CHANGELOG.md)
- [macOS](apps/macos/CHANGELOG.md)
- [Protocol](protocol/CHANGELOG.md)

## [Unreleased]

### Added

- Updated implementation summaries to remove outdated blanket acceptance-pending labels.

- SMS relay v3 connects Android Messages with Mac notifications, inline replies, paged conversations, history, phone-side search and per-reply SIM selection over secured LAN/Bluetooth. Content stays in memory on the Mac. Live receipts and sends retain local observation order across provider refreshes; thread scans complete timestamp groups and continue past unreadable rows. Native composers expose SIM choice beside Send, with per-phone Mac notification, sound and preview controls.

- Native Quick Paste Tray on macOS: lightweight floating card carousel invoked via global hotkey (`⌥⌘V`), menu-bar companion button, or in-app button, featuring instant real-time search, category filters (All, Pinned, Mac, Phone), smart card previews (live hex color swatches, URL link summaries, monospace code formatting), Space to expand full text in the tray, immediate arrow-key selection, and Return to copy. History capacity is configurable on both platforms (20 default, 50, 100); pausing collection, app restart, Forget device and Reset identity preserve saved items, with explicit Clear/Delete controls. Clipboard panels have small horizontal insets. On macOS, pinned snippets survive recent-item eviction within the 100-item absolute bound, and clear options offer unpinned or all deletion.

- Clipboard adds Android Send to Mac actions for selected/shared text and URLs, plus a Quick Settings tile for explicit focused capture. Both platforms offer compact sharing controls and optional persistent local history grouped by date. Phone Home and the Mac overview/companion show a five-minute recent preview with local Copy.

- Strict local verification gate (`scripts/verify-suite.py`) with `fast`, `device` and `all` modes. It parses Android JUnit XML and macOS result bundles, cross-checks `xcodebuild` test-case lines, and rejects zero-test runs, failures, crashes, truncated reports and undocumented skips. Adversarial meta-tests (`scripts/test_verify_suite.py`) prove the gate rejects those false-success shapes. No CI workflow is added.
- `--check` drift verification for every independent vector generator (clipboard, SMS, transfer, media, find-device, identity, pairing, session handshake/control/record, LAN framing, bulk probe and LAN transfer). Identity checking compares all non-randomized fields and verifies committed signatures with OpenSSL.
- Replaced the macOS transfer-ordering test that asserted a local reimplementation with a production-path test through `ConnectionPresentation.primaryPeers`, covering connected filtering, stored order and the all-disconnected fallback.

- Native text Clipboard v1 on Android and macOS, with manual sharing, per-device opt-in automatic sharing and direct native clipboard delivery over secured LAN or BLE.

- File transfers now pause instead of failing when the active LAN or Bluetooth channel drops mid-stream. The verified partial is retained for 15 minutes, local-network reconnection resumes automatically at the last verified offset, and either device can explicitly continue over Bluetooth when LAN stays down (the receiver asks the sender to validate the prefix it already holds). Paused cards and notifications show frozen progress, Continue over Bluetooth where available and Cancel; pause remains automatic on transport loss, with no manual pause action. A capable LAN that appears during a Bluetooth stream upgrades the active transfer in place through the same resume handshake, so continuing over Bluetooth no longer keeps streaming over Bluetooth after Wi-Fi returns. On Android, a paused or active batch retains a secured Bluetooth fallback lease so the fallback survives and the channel does not connect/disconnect repeatedly.
- Automatic BLE-coordinated LAN initiation on connection events, secured BLE feature activity, companion media demand and file selection. Automation is on when no preference is stored, a stored off still wins, and pairing exposes one post-pairing toggle that sets both the Bluetooth and LAN choices.

### Changed

- Clarified in-app Clipboard guidance for manual sharing, Android text-selection menu availability and connected-device requirements.

### Fixed

- Any feature communication or interaction over BLE (Now Playing, File Transfer, Find Device, etc.) now automatically triggers the LAN connection and opens the Mac Allow window when LAN is not yet connected. Android background Now Playing additionally requests and retains LAN (including artwork) while playing or inside the paused grace.
- File selection and a pending send no longer retire a secured BLE channel; a send with a secured channel proceeds on it, and a LAN demand that cannot be served fails immediately instead of waiting for the connect timeout.
- Feature traffic no longer resumes LAN after an explicit Disconnect.
- Settings and pairing are decluttered: one post-pairing toggle, one local-network preference, and a collapsed Background timeout row that still defaults to Never.

## [0.2.0]

Development milestone: 0.2.0-dev, build 2.

### Added

- **Find Device (Cross-Platform)**:
  - Peer-scoped Find Device over secured LAN/BLE connections with explicit capability negotiation, replay floors, and bounded request queues.
  - Android bounded alarm-stream ringing service that sounds even in Silent/Vibrate mode, with in-app dialog and high-priority Stop notification.
  - macOS native UserNotifications with explicit permission setup, identifier-bound dismissal, and application-owned expiry.
  - Localized `find_connected` status and peer-specific accessibility action labels (`find_peer_action` -> "Find %s" / "Find %@").
  - Pure Mac presentation policy helper `FindDevicePermissionPolicy` covering allowed, blocked, unknown, and error states.
- **Local File Transfer (v1 Protocol)**:
  - Bidirectional local file transfer engine with recipient approval, sequential multi-file batch streaming, and cumulative credit flow control (64-window / 3,072-byte chunks).
  - Incremental SHA-256 chunk hashing, exclusive job-owned partial staging, and checked non-overwriting publication.
  - Android Compose UI with Storage Access Framework (SAF) document picker and high-priority notification actions.
  - macOS AppKit/SwiftUI views with interactive UserNotifications (Accept to `~/Downloads`, Choose folder…, Decline, Show in Finder) and menu-bar companion live activity paging.
  - High-throughput LAN optimizations: 2-MiB socket buffers, decoupled ingress queues, cached identity digests, concurrent full-duplex ACK transmission, and pipelined backpressure tracking.
- **Now Playing & Remote Media Controls**:
  - Remote playback controls, track progress, volume management, and player selection over secured LAN/BLE DATA subscriptions.
  - Source-bound commands, atomic seek previews, and LAN-only artwork streaming with hash verification.
  - Verified player volume for Apple Music and Spotify, and separately advertised macOS output volume synchronization.
  - Silent Android media notifications with 90-second pause grace and background BLE lease.
- **Native Design System & UI Overhaul**:
  - Android bottom navigation (Home, Devices, Features, Settings) and macOS sidebar navigation with branded compact top bars.
  - Persistent System/Light/Dark appearance preferences with native typography and semantic tokens.
  - Dedicated About screen with installed version, project credits, source repository, and quiet support link (`ic_heart`).
- **Repository Hygiene & CI Foundations**:
  - Comprehensive `.gitattributes` configuration enforcing cross-platform LF normalization for text, CRLF for Windows batch files, and binary protection for icons, audio, keystores, protocol vectors, and native libraries.
  - Sanitized `AGENTS.md` instructions pointing exclusively to tracked documentation and contracts while maintaining strict commit authorization.
- **Test Harness & Conformance**:
  - 218 passing Android JVM unit tests and 207 passing macOS hosted tests with zero failures.
  - Adversarial test coverage for maximum profile-3 bounds, cipher tampering rejection, buffer independence, exact CBOR sizing, and single-copy framing.

### Changed

- **Repository Hygiene**: Added `.gitattributes` for LF normalization, Windows batch compatibility, and binary preservation; sanitized `AGENTS.md` to reference only tracked development and protocol documents.
- **Android Code Hygiene**: Reformatted `MediaController.kt` to idiomatic Kotlin with unpacked statements and standard operator spacing; removed dead `FindDeviceSetup` wrapper, stale imports, and unused parameters.
- **Navigation & Ergonomics**: Replaced full-window connection management on Home with compact summaries; moved detailed pairing, automatic preferences, and transport diagnostics to Devices with clickable fingerprint disclosures.
- **Zero-Copy Record Processing**: Eliminated intermediate allocations and copies across authenticated record paths on both platforms; reused directional ciphers, encoded CBOR into exact buffers, and decoded sliced frames without rebasing.
- **Transports & Concurrency**: Moved macOS LAN socket delivery, sliced frame parsing, write accounting, and watchdogs off the MainActor; decoupled Android socket reads into bounded ordered queues.
- **Development milestone**: Set the application milestone to 0.2.0-dev, build 2.
- **Test Accuracy**: Renamed macOS Find Device rendering test to `testFindDeviceViewRendersNonemptyLayoutWithAndWithoutPeers` to describe layout coverage without claiming OS permission evaluation.

### Fixed

- **Playback Controls Stability**: Retained same-source playback capabilities across track and context transitions to prevent controls flickering or disappearing; eliminated seekbar thumb jumps during drag interactions and reserved stable artwork dimensions.
- **Media Controller**: Deduplicated playback state, coalesced notification updates, ignored output-only provider churn, and properly restored dismissed notifications on Android.
- **Mac Notification Stability**: Suppressed spurious "Transfer unavailable" notification alerts when declining or interacting with already-handled or cancelled transfer offers in `MacTransferNotifier`, and immediately cleared delivered notification banners from Notification Center on user action.
- **Find Device Notification Lifecycle**: Replaced existing Find Device notifications on fresh requests instead of returning busy after banners fade; prevented duplicate requests and stale dismissal callbacks from reviving expired alerts.
- **Transfer Presentation & Progress**: Displayed peer name, direction, and actual destination folder in transfer panels; enabled Show in Finder for published files, reported indeterminate progress for empty batches, and labeled progress for screen readers.
- **File Finalization & Collisions**: Atomically suffixed conflicting destination file names (`name (1).ext`), published files by copying when destination volumes do not support hard links, reported exact POSIX error codes, and preserved verified partials on disk if finalization fails.
- **LAN Ingress Queues**: Decoupled socket reads from delivery with bounded ordered queues and record-sized buffers; released session processing gates before delivery to allow full-duplex control flushes and prevent stall amplification.
- **Rolling Transfer Rates**: Measured transfer speed over a bounded rolling sample window that decays promptly on stalls and omits rate display during finalization.
- **LAN Profile 3 Negotiation**: Negotiated domain-separated 256-KiB LAN records with 128-KiB chunks and up to 1 MiB credit while maintaining live native identity and trust validation.
- **Connection Retention**: Retained active Android LAN sessions during temporary IPv6 address rotation when interface addresses remain valid, and kept Connect LAN visible when only Bluetooth is connected.
- **Keychain & Keystore Caching**: Reused validated Keychain key handles and Keystore provider instances while re-verifying live aliases, public keys, and key protection on every operation.
- **Transfer Lifecycle**: Enforced LAN preference with BLE fallback, exclusive partial staging, and deterministic timer releases so notification denial never halts approved foreground transfers.

## [0.1.0]

### Added

- Architecture overview (`ARCHITECTURE.md`) documenting shared identity, mutual trust bootstrap, secure session profiles, and independent native BLE/LAN transport ownership.
- Independent authenticated LAN sessions alongside BLE, with explicit transport controls, pinned same-peer ownership and bounded native TCP framing.
- Automatic nearby BLE recovery, shared Mac availability and coordinated fresh-session renewal. Notification-free Android companion ownership is enabled on API 31+; physical endurance and minimum-OS acceptance remain pending.
- Negotiated encrypted BLE keepalive with legacy manual fallback and independent application-control conformance fixtures.
- Trusted-device BLE session integration with encrypted readiness, replay-protected directional AES-GCM records, lifecycle cleanup, shared GATT framing and explicit connection controls.
- Independent Python conformance oracle for record framing and test vectors covering directional AES-GCM traffic.
- Strict native-session instrumentation checks and adversarial runner/cleanup tests with automated verification metadata.
- Native EDHOC method 0 / suite 5 handshake engine, strict credential/signature codecs, and cross-platform handshake interchange.
- Pairing and trust: camera QR scanning and six-digit code entry with PAKE bootstrap, bounded GATT transport with automatic cache invalidation, mutual on-device approval, and atomic peer trust persistence.
- Hardened test harness and oracle coverage: baseline fixture floors, independent crypto-vector assertions, interrupted re-pairing at capacity limits, and direct write-failure fault injection on both platforms.
- Six-phase tracked roadmap, provisional BLE discovery architecture decision, and provisional device-identity architecture decision.
- Design guide covering Mac window, menu-bar companion, Android navigation, semantic colors, and native interaction constraints.
- Monorepo scaffold with Android, macOS, Rust pairing bridge, and protocol schemas.

### Changed

- Unify device connection controls, pairing handoff and management across Android and Mac; keep transport diagnostics and Debug events collapsed. Browsing Android discovery preserves both transports, while Scan retires Bluetooth only.
- Enable Android API 31+ notification-free companion auto-connect in main resources for Debug and Release; cap jittered retry backoff at 90 seconds.
- Refine neutral controls, accent checkboxes, phone-name editing and full trusted fingerprints. Resume saved automatic setup inline and retain eligible foreground BLE when automatic ownership is disabled.
- Add native Mac menu-bar right-click routes and readable typed session failures.
- Replace periodic BLE/LAN maintenance with deadline waits and transport events; keep native identity validation on authenticated operations and retire both owners on explicit security mutations.
- Simplify the README around a device-focused introduction with Android/macOS as initial platforms; move the architecture overview to root ARCHITECTURE.md and correct identity protection, transport ownership, renewal and platform baseline descriptions.
- Update repository structure trees, documentation links, and active contracts across root, Android, macOS, and protocol READMEs.
- Reduce secured BLE maintenance frequency while retaining per-operation trust and deadline checks; remove redundant Android identity signing during ordinary reads.
- Add concise purpose headers across source, configuration and design assets; replace conversational documentation attribution with technical verification facts.
- Update Bluetooth Low Energy GATT service and characteristic UUIDs.
- Add shared Mac allowed-device selector with credential pinning, full-label discovery disclosure, and compact Android fingerprint identifiers.
- Avoid private signing probes when loading an existing Mac identity; retain certificate-free local build defaults.
- Distinguish automated unit and contract test evidence from physical radio and manual acceptance criteria across project documentation.
- Simplify root and app READMEs with concise structure trees and direct documentation links.
- Correct Mac development Keychain export-policy handling and document explicit recovery for older development identities.
- Refine local device details on both platforms using the shared design tokens.

### Fixed

- Retire Android LAN ownership on network changes and Disconnect; configure bounded Mac TCP peer-loss detection while preserving foreground-only LAN lifetime.
- Retire Android session state and transport after authenticated Mac Disconnect instead of cancelling only its coroutine worker.
- Restore automatic BLE ownership on same-instance Android companion service rebind and reject callbacks after unbind.
- Resolve native pairing tool paths from private project configuration for IDE builds without shell overrides.
- Prevent stopped background setup from restarting through delayed validation; preserve newer radio modes and scope device settings to their selected relationship.
- Restore native Android background ownership after pause/process rebinding and remove presentation-dependent retry observation.
- Admit fresh trusted sessions on retained BLE indication subscriptions within an explicit Mac window while preserving exclusive admission and authentication.
- Replace roadmap placeholders in pairing completion messages with the saved trust state on both platforms.
- Send authenticated cancellation on Mac pairing Decline before Bluetooth cleanup; report cancellation and release GATT on Android.

Release 0.1.0 captures initial foundation protocols, dual transports, idle optimization, and unified connection flow. Active development proceeds toward subsequent feature milestones.
