# Repository changelog

Repository-wide structure, documentation, and development conventions belong here. Android, macOS, and protocol changes have separate changelogs and may be versioned independently:

- [Android](apps/android/CHANGELOG.md)
- [macOS](apps/macos/CHANGELOG.md)
- [Protocol](protocol/CHANGELOG.md)

## Unreleased

### Added

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

- Update Bluetooth Low Energy GATT service and characteristic UUIDs.
- Add shared Mac allowed-device selector with credential pinning, full-label discovery disclosure, and compact Android fingerprint identifiers.
- Simplify Android connection presentation to a flat device list and native contextual menus; clarify session feedback on idle limits, peer closure, and trust failure.
- Avoid private signing probes when loading an existing Mac identity; retain certificate-free local build defaults.
- Distinguish automated unit and contract test evidence from physical radio and manual acceptance criteria across project documentation.
- Simplify root and app READMEs with concise structure trees and direct documentation links.
- Correct Mac development Keychain export-policy handling and document explicit recovery for older development identities.
- Refine local device details on both platforms using the shared design tokens.

### Fixed

- Admit fresh trusted sessions on retained BLE indication subscriptions within an explicit Mac window while preserving exclusive admission and authentication.
- Replace roadmap placeholders in pairing completion messages with the saved trust state on both platforms.
- Send authenticated cancellation on Mac pairing Decline before Bluetooth cleanup; report cancellation and release GATT on Android.

Android uses development version `0.0.0-dev`; macOS uses numeric `0.0.0` to follow Apple's bundle-version conventions. Both identify unreleased foundations, not published releases.

