# macOS changelog

Changes to the aniCe Mac app. Repository-wide changes are recorded in the [root changelog](../../CHANGELOG.md).

## [Unreleased]

### Added

- Isolated launcher for the pinned experimental scrcpy microphone-injection client and matching Android server, preserving the installed scrcpy command and production app configuration.

- Standalone call-audio diagnostic with native HFP service and SCO state, phone-address endpoint association, bounded input/output buffer checks, explicit microphone permission requests, interactive call controls and JSON results. Supports native audio transfer and passive phone-initiated SCO setup.

- Compact Clipboard Share/History views and optional device-local history with 20 retained items, source-device labels and Copy/Send/Delete controls independent of automatic sharing. The overview and companion show five-minute recent clipboard previews with local Copy; the companion also offers direct clipboard sending.

- Replaced the transfer-ordering test that reimplemented compact/none-connected ordering locally with a production-path test through `ConnectionPresentation.primaryPeers`, covering connected filtering, stored order and the all-disconnected fallback. The strict local verification gate now cross-checks hosted-suite result bundles against `xcodebuild` test-case lines and rejects zero-test runs, failures, crashes and undocumented skips.

- Clipboard panel, favourites and companion entry with credential-scoped automatic consent, permission-aware pasteboard observation, sensitive-content confirmation and bounded LAN/BLE delivery with idempotent fallback. Manual sends survive automatic clipboard changes during preparation; disabling automatic sharing immediately cancels pending automatic preparation.

- Resilient file transfers: a mid-stream LAN or Bluetooth loss now pauses with retained partial storage, frozen progress in the transfer panel and menu-bar companion, and a native paused notification. A reconnected LAN to the same peer resumes automatically at the verified offset; either device can explicitly continue over Bluetooth from the panel or notification when LAN stays down, with the receiver asking the sender to validate the prefix it holds. Cancel deletes the partial, and a 15-minute pause timeout fails and cleans it up.
- A live LAN that becomes capable during a Bluetooth stream upgrades the active transfer in place through the resume handshake, so a Bluetooth continuation moves back to local network as soon as Wi-Fi reconnects.
- Automatic LAN is on when no preference has been stored; a stored off still wins, and pairing exposes one post-pairing toggle for both Bluetooth and LAN. Authenticated BLE admission coordination opens bounded Allow windows on connection events, successful BLE feature traffic, media demand or file-transfer demand; coordination traffic cannot initiate another window.

### Changed

- Clipboard and file sending use compact labeled native controls. Clipboard preferences use small accent-colored checkboxes; History groups entries by date with a count/Clear all toolbar and adaptive row actions in both appearances. Clipboard help explains Android selection, Share-sheet and Quick Settings routes, connected-device requirements and manual sharing with automatic sharing off.

### Fixed

- A lost active connection no longer fails the batch or deletes its verified partial; streaming losses pause instead, and a paused batch keeps its sleep assertion, destination and secured Bluetooth fallback so automatic LAN or explicit Bluetooth continuation can finish it. The paused notification offers Continue over Bluetooth on the receiving device as well as the sender.
- Any feature communication or interaction over BLE (Now Playing, File Transfer, Find Device, etc.) now automatically triggers the LAN connection and opens the Mac Allow window when LAN is not yet connected, even on fresh installs with no stored preference.
- Feature traffic no longer resumes LAN after an explicit Disconnect; manual Allow/Connect or a preference change resumes automation.

## [0.2.0]

### Added

- **Find Device**:
  - Integrated Find Device into connected-peer actions and the menu-bar companion.
  - Native UserNotifications with explicit permission setup, identifier-bound dismissal, and application-owned expiry/cleanup.
  - Localized `find_connected` status and peer-specific accessibility action labels (`find_peer_action` -> "Find %@").
  - Extracted pure presentation policy helper `FindDevicePermissionPolicy` with automated coverage across allowed, blocked, unknown, and error states.
- **Local File Transfer**:
  - Native bidirectional file transfer engine (`MacTransferModel`, `TransferView`, `TransferWire`) with 64-chunk cumulative credit flow control.
  - Sequential multi-file batch streaming, exclusive partial staging with checked non-overwriting finalization, and sleep assertion management.
  - Interactive file transfer notifications (`MacTransferNotifier`, `UNUserNotificationCenter`) with Accept (saves to `~/Downloads`), Choose folder…, Decline, and completion notices with Show in Finder.
  - Menu-bar companion live activity (`CompanionView`, `TransferView(compact: true)`): two-activity paging (`1 of 2`), attention indicators for incoming offers, isolated swipe gestures, and active transfer state awareness.
  - LAN throughput optimization: direct `SessionCrypto.kid` digest extraction from decoded public key bytes, decoupled `sendData` and `receive` locking in `SessionConnection` for concurrent full-duplex ACK transmission, and pipelined ACKs every 8 chunks.
- **Now Playing & Media Controls**:
  - Event-driven Now Playing owner supporting Home view, menu-bar companion, and remote Phone controls.
  - Source-bound controls for native and scriptable media players, recovering late capabilities and publishing position samples.
  - Explicit volume verification for Apple Music and Spotify gating player sliders, and native system output-device observation for volume synchronization.
- **Native Navigation & Appearance**:
  - Sidebar navigation with Home, Devices, Features, and Settings destinations.
  - Saved native window appearance preference supporting System, Light, and Dark modes with SwiftUI and AppKit inheritance.
  - Concise About view with installed version (0.2.0-dev, build 2), purpose summary, project links, and support link.
- **Test & Conformance Coverage**:
  - 207 automated hosted Mac tests with 0 failures and 6 explicit manual skips.
  - Adversarial test coverage for maximum profile-3 bounds, cipher tampering rejection, sliced-buffer decoding, and buffer independence.

### Changed

- **Layout & Structure**: Aligned macOS window around content-sized activity panels in at most two columns, dedicated feature workspaces, and separated Devices, Favourites, and About.
- **Companion & Menus**: Filtered companion devices to connected-only peers when active devices exist, made disclosure labels clickable, routed companion clicks to Devices, and omitted empty dividers.
- **Record Pipeline & Zero-Copy**: Assembled records and TCP frames into single reserved buffers, and decoded sliced buffers directly without re-basing copies.
- **Concurrency & Transports**: Moved LAN socket delivery, sliced frame parsing, bounded write accounting, and assembly watchdogs off the MainActor to run concurrently with native interchange.
- **Test Precision**: Renamed `testFindDeviceViewRendersPermittedAndBlockedStates` to `testFindDeviceViewRendersNonemptyLayoutWithAndWithoutPeers` to accurately reflect layout assertion coverage without claiming OS permission evaluation.

### Fixed

- **Playback Controls**: Retained same-source playback capabilities across track and context changes to prevent controls flickering or disappearing when track metadata updates.
- **Now Playing Snapshots**: Merged resolved media capabilities into initial adapter and command snapshots for immediate, glitch-free UI updates.
- **Notification Routing**: Routed transfer and Find Device notifications through a unified `AppDelegate` listener, registering all notification categories together.
- **Notification Stability**: Suppressed spurious "Transfer unavailable" notification alerts when declining or interacting with already-handled or cancelled transfer offers in `MacTransferNotifier`, and immediately cleared delivered notification banners from Notification Center on user action.
- **Find Device Notification Lifecycle**: Replaced existing Find Device notifications on fresh requests instead of returning busy after banners fade; prevented duplicate requests and stale dismissal callbacks from reviving expired alerts.
- **Transfer Presentation**: Displayed peer name, direction, and actual destination folder in the transfer panel; enabled Show in Finder for published files, reported indeterminate progress for empty batches, and labeled progress for VoiceOver.
- **File Finalization & Collisions**: Atomically suffixed conflicting destination file names (`name (1).ext`), published files by copying when destination volumes do not support hard links, reported exact POSIX error codes, and preserved verified partials on disk.
- **LAN Ingress Queues**: Decoupled socket reads from delivery with bounded ordered ingress queues and record-sized buffers; released session processing gates before delivery to allow full-duplex control flushes.
- **Rolling Transfer Rates**: Measured transfer speed over a bounded rolling sample window that decays promptly on stalls and omits rate display during finalization.
- **LAN Profile 3 Negotiation**: Negotiated domain-separated 256-KiB LAN records with 128-KiB chunks and up to 1 MiB credit while maintaining live native identity and trust validation.
- **Keychain Handles**: Reused validated native Keychain key handles across lookups while re-verifying key presence, protection, and trust journals on every operation.
- **Transfer Routing & Recovery**: Enforced LAN-preferred transfer routing with BLE fallback, exclusive partial staging, checked finalization, and isolated reply correlation.

## [0.1.0]

### Added

- Shared manual Bonjour/TCP admission, encrypted LAN connection checks, same-peer reservations and sandbox network declarations.
- Shared automatic nearby admission with five-failure cooldown, persisted allowed-phone policy, paused Disconnect and sleep/wake restoration.
- Coordinated encrypted renewal requests before session lifetime or record limits.
- Session control negotiation and encrypted keepalive replies, sharing existing record limits, trust validation and bounded transport queues.
- Shared CBOR conformance fixtures and hosted tests for control ordering, timeouts, legacy peers, submission failure and suspended-send cancellation.
- Allow connections and session controls shared by window and companion, native AES-GCM record actor, admission failure/window limits, advertising-independent established traffic and sleep/Quit cleanup.
- Actor-isolated EDHOC method 0 / suite 5 handshake engine, pinned CCS credentials, strict CBOR/signature codecs, and shared conformance tests.
- Pairing: QR and six-digit code invitations with PAKE bootstrap, stable three-characteristic GATT peripheral adapter, mutual approval, atomic peer trust store, dedicated pairing and trusted-devices panels.
- Explicit bounded BLE peripheral discovery shared by window and companion, read-only rotating nonce payload, sandbox/usage configuration, and sleep/Quit cleanup.
- Persistent P-256 identity with immutable Keychain generations, atomic reset/recovery, typed errors, and signing snapshots.
- Native SwiftUI application with resizable single-instance window, menu-bar companion, and system light/dark appearance using the shared palette.

### Changed

- Share readiness-based summaries and neutral connection controls across the window and companion; retain full-width details and accent automatic checkmarks in Devices. Successful pairing returns to the overview and opens fresh Bluetooth admission after guarded cleanup.
- Use an AppKit status item/transient popover with a compact device summary, persistent footer and native right-click routes to main-window device controls.
- Provide full-width Diagnostics controls for transport checks and discovery; keep LAN/manual recovery independent. Translate typed session failures into readable reasons.
- Replace repeating BLE/LAN maintenance timers with revision-guarded deadline tasks; separate visible admission countdowns from security work.
- Match service-level trust revocation to the owning journal and retire both transports on identity reset/recovery.
- Update macOS code structure tree, test inventory, and manual LAN documentation in README.
- Document source/configuration responsibilities and session invariants inline: trust revalidation, nonce ownership, readiness, bounded fragmentation, submission semantics and best-effort secret cleanup.
- Load existing public identity state without a startup signing challenge; retain creation/reset checks and verification of requested signatures.
- Merge secured state and authenticated-device feedback into one status line in window and companion.

### Fixed

- LAN TCP enables bounded native keepalives and retransmission timeout so an unreachable phone is detected before the authenticated idle limit.
- Keep delayed pairing cleanup from replacing a newer pairing or discovery radio owner with automatic session admission.
- Allow fresh session admission on retained Core Bluetooth indication subscriptions during an explicit window while preserving exclusive admission.
- Show pairing actions on an unpaired Mac; hide unavailable connection controls in window and companion while retaining active-operation controls.
- Declare finite session-task ownership explicitly while retaining weak transport/channel callbacks, resolving Swift nested-capture diagnostics.
- Retain session termination reason and distinguish idle/lifetime limits, authenticated peer closure and trust failure.
- Show pairing completion and saved trust without placeholder text.
- Send encrypted cancellation on pairing Decline with bounded transport draining before invitation cleanup.

The initial release targets macOS 14 as a provisional minimum.
