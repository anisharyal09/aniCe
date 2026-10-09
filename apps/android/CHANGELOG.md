# Android changelog

Changes to the aniCe Android app. Repository-wide changes are recorded in the [root changelog](../../CHANGELOG.md).

## Unreleased

### Added

- Companion-owned nearby retry with bounded backoff, pinned saved setup, a device-level automatic connection switch and Disconnect pause. Release service ownership remains disabled pending physical acceptance.
- Coordinated fresh EDHOC renewal before lifetime/record limits, with encrypted backpressure, Stop and key-reuse regressions.

- HELLO/ACK compatibility and encrypted PING/PONG in the shared session controller; legacy peers retain manual operation and unsupported background probes stop.
- Adversarial control tests for malformed encodings, ordering, deadlines, backpressure, transport failure and hard session lifetime.
- Debug-only system companion association/presence probe with pinned EDHOC authentication, bounded event diagnostics, explicit cleanup and API 31–36 dispatch.

- Trusted Mac Connect/Disconnect/Retry controls, native AES-GCM record channel and EDHOC/BLE ordering owner, foreground cleanup and shared v1/v2 GATT transport with bounded queues and submission deadlines.
- Native EDHOC method 0 / suite 5 handshake engine with active-trust pinning, bounded deterministic CBOR, DER/COSE signature conversion, and cancellation guards.
- Pairing: CameraX QR scanning and six-digit code entry with PAKE bootstrap, bounded GATT transport with automatic cache invalidation, mutual approval, atomic peer trust persistence, and local forgetting.
- Foreground service-filtered nearby BLE discovery with on-demand permissions and bounded candidate validation.
- Persistent P-256 device identity with Android Keystore signing, actual protection reporting, and backup-excluded metadata.
- Initial Android app with aniCe top bar, device list home, and system light/dark theme using the shared palette.

### Changed

- Load existing identity state without a signing challenge; retain creation/reset proof and validate the active journal binding and requested signature before return.
- Run secured-session maintenance once per second while retaining 200 ms authentication/readiness checks and native companion recovery.
- Add file-purpose summaries to Android sources, tests, resources, manifest and build configuration.
- Document shared session controller architecture, companion device lifecycle boundaries, and native API paths in docs/BACKGROUND_CONNECTIONS.md.
- Replace centered connection home with a minimal device list, contextual actions and native management menus.
- Display eight-hex-digit fingerprint prefix instead of placeholder text; complete semantic color tokens using DESIGN.md palette.
- Document session security and lifecycle invariants inline: trust revalidation, nonce ownership, readiness, bounded fragmentation, submission semantics and best-effort secret cleanup.
- Record native GATT write status and session mode in transport diagnostics without recording payloads or keys.
- Extract app shell and device-identity screen/state from MainActivity into lifecycle ViewModels.

### Fixed

- Retire controller state and transport on authenticated Mac closure, manual disconnect and renewal requiring manual reconnection; explicitly qualify cleanup inside coroutine receivers and publish terminal feedback before retry observation.
- Restore companion ownership on same-instance rebind without presence replay and reject stale unbound callbacks.
- Read private Cargo, Rustup and NDK paths during native pairing builds; preserve explicit environment overrides.
- Cancel retired Resume results and lookup failures before they can overwrite Stop or newer setup.
- Scope automatic connection settings, reset and checks to the displayed Mac; retire the previous association on explicit replacement.
- Restore native companion ownership after pause/process rebinding and observe background session/radio changes independently of Compose presentation.
- Preserve authenticated connections when opening or leaving the background-test screen; track both activity lifecycles and disconnect only through explicit setup.
- Normalize companion association addresses for native Bluetooth lookup and identify failed setup stages; collapse test diagnostics behind an explicit disclosure.
- Distinguish authenticated Mac closure and idle/lifetime limits from trust failure; serialize session health checks with incoming close processing.
- Show pairing completion and saved trust without placeholder text.
- End pairing promptly on authenticated Mac cancellation, clear temporary channel state, and show cancellation recovery message.

The foundation uses development version `0.0.0-dev` (code `1`), targets Android 16 (API 36), and has a provisional Android 10 (API 29) minimum.
