# Android changelog

Changes to the aniCe Android app. Repository-wide changes are recorded in the [root changelog](../../CHANGELOG.md).

## Unreleased

### Fixed

- End pairing promptly on authenticated Mac cancellation, clear temporary channel state, and show a cancellation recovery message.

### Added

- Pairing: CameraX QR scanning and six-digit code entry with PAKE bootstrap, bounded GATT transport with automatic cache invalidation, mutual approval, atomic peer trust persistence, and local forgetting.
- Test hardening: baseline fixture inventory floors, independent ECDH/client-MAC checks, pending re-pair recovery at capacity limits, and measured identity fault-injection boundaries.
- Foreground, service-filtered nearby BLE discovery with on-demand permissions, generic temporary candidates, bounded GATT validation/cleanup, cancellation and recovery, and shared-vector/lifecycle tests. Physical acceptance remains pending.

### Changed

- Simplify the app README around its source structure and run/check commands; add concise ownership and threading comments at app entry points.
- Extract the app shell and device-identity screen/state from MainActivity, retain state in a lifecycle ViewModel, and group identity infrastructure/tests with explicit imports. Storage identifiers and public contracts are preserved.
- Require interchange tests to reject altered messages, malformed signatures, and wrong keys, and confirm isolated test cleanup.
- Refine “This device” with a clear device heading, grouped identity details, readable fingerprint, and a separate reset section.

- Persistent P-256 device identity with Android Keystore signing, actual protection reporting, and backup-excluded metadata.
- A native “This device” screen with copy actions, explicit identity reset, and recoverable storage errors.
- Journaled identity replacement, shared interoperability vectors, JVM behavior tests, and Android Keystore instrumented tests.
- Initial Android app with an aniCe top bar and “No devices paired” starting screen.
- System light and dark themes using the shared aniCe palette.
- Edge-to-edge layout with safe window insets, wrapping text, and scrollable content.
- Single-module Kotlin/Compose project, Gradle wrapper, and local build and run instructions.

The foundation uses development version `0.0.0-dev` (code `1`), targets Android 16 (API 36), and has a provisional Android 10 (API 29) minimum.
