# macOS changelog

Changes to the aniCe Mac app. Repository-wide changes are recorded in the [root changelog](../../CHANGELOG.md).

## Unreleased

### Added

- Bidirectional local file transfer engine and UI (`MacTransferModel`, `TransferView`, `TransferWire`) with 64-chunk cumulative credit flow control, sequential multi-file batch streaming, temporary `.anice-part` staging with atomic rename, sleep assertion management, full-duplex flow-control ACK submission, and integration into Features and Home live-activity.
- Optimize LAN streaming throughput: compute `SessionCrypto.kid` directly from decoded public key bytes avoiding redundant CryptoKit curve reconstruction per record; cache authenticated public device identity in `IdentityService` to eliminate redundant Keychain `securityd` IPC overhead during record validation; decouple `sendData` and `receive` locking in `SessionConnection` to allow concurrent full-duplex ACK transmission; pipeline flow-control ACKs every 8 chunks with multi-waiter `capacityWaiters` backpressure tracking.
- Shared event-driven Now Playing owner with optional Home/companion activity, Phone controls information and attributed packaged universal adapter. Source-bound controls resolve native/script support per action, recover matching late capabilities and publish position samples after commands. Explicit Music/Spotify volume verification gates player sliders; native output-device observation supports phone volume controls. Preview confirmation, readable availability and selection-preserving refresh handle asynchronous results without replaying writes.
- Home/Devices/Features/Settings sidebar and saved native Window appearance preference with native and SwiftUI System inheritance across the window and connection-details sheet; companion and context menus retain system appearance.

### Changed

- Move LAN socket delivery, sliced frame parsing, bounded write accounting and independent assembly watchdogs off the main actor; exercise the production transport in native interchange.

- Separate MacPlaybackModel, MediaProcessBridge and MediaSessionLink; group connection owners under Connections, register feature-neutral DATA handling in App, and split hosted suites with shared independent fixtures.

- Disable App Sandbox while retaining hardened runtime, signing defaults and original identity/trust journal locations; unsupported player targeting remains disabled.
- Compact Home/companion rows open Devices with peer context before restoring the main window; clicking names/status also opens device management.
- Add an aniCe sidebar heading with breathing room and consistent header backgrounds/dividers across Home, Devices, Features and Settings.
- Move local identity behind a full-width This device Settings entry with Back navigation, explicit name editing and clickable Advanced disclosure.
- Apply the selected appearance to native window/sheet backgrounds, text and controls together; System tracks macOS independently of a forced window theme. Retain shared transport owners.

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
