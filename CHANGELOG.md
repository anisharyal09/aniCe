# Repository changelog

Repository-wide structure, documentation, and development conventions belong here. Android, macOS, and protocol changes maintain dedicated component changelogs under unified project releases:

- [Android](apps/android/CHANGELOG.md)
- [macOS](apps/macos/CHANGELOG.md)
- [Protocol](protocol/CHANGELOG.md)

## Unreleased

### Added

- Now Playing on Mac Home/companion and Android Home, with phone Home controls and platform-specific Features information, revision-bound controls over existing secured LAN/BLE, atomic seek feedback, native Android media presentation and a fixed 90-second paused grace; companion-owned background BLE and separately negotiated selected-player volume remain capability/permission gated; independently advertised Mac output volume supports phone buttons without player scripting.
- Home, Devices, Features and Settings navigation with saved native appearance preferences.

### Changed

- Group Now Playing implementation, adapter and tests by feature; separate application connection owners, navigation, playback authority, native process handling and media queues. Add dependency/link/Xcode membership checks and relocate the byte-preserving media fixture generator.
- Consolidate feature usage and limitations; keep app-wide ADRs at the decision root and independent decisions in feature folders. Update READMEs, source maps, attribution and agent state without repeated verification matrices or stage reports.

- Separate compact Home/companion summaries from device connection management and local identity settings; retain a small aniCe heading on each platform.

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
