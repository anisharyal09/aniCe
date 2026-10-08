# Repository changelog

Repository-wide structure, documentation, and development conventions belong here. Android, macOS, and protocol changes have separate changelogs and may be versioned independently:

- [Android](apps/android/CHANGELOG.md)
- [macOS](apps/macos/CHANGELOG.md)
- [Protocol](protocol/CHANGELOG.md)

## Unreleased

### Fixed

- Replace roadmap placeholders in pairing completion messages with the saved trust state on both platforms.
- Mac pairing Decline now sends authenticated cancellation before Bluetooth cleanup; Android reports cancellation and stops waiting.

### Added

- Strict native-session instrumentation success checks and adversarial runner/cleanup tests, with explicit automated-evidence and pending-manual-acceptance metadata. Cleanup failure prevents writing a success report.
- Native EDHOC secure-session feasibility infrastructure, an independent Python conformance oracle, strict credential/signature codecs, and isolated Android–Mac handshake interchange. Record transport and UI integration remain gated on baseline runtime verification.

- Pairing and trust: camera QR scanning and six-digit code entry with PAKE bootstrap, bounded GATT transport with automatic cache invalidation, mutual on-device approval, and atomic peer trust persistence. User manual/radio acceptance remains pending.
- Hardened test harness and oracle coverage: baseline fixture floors, independent crypto-vector assertions, interrupted re-pairing at capacity limits, and direct write-failure fault injection on both platforms.

- Six-phase tracked roadmap and provisional BLE discovery architecture decision separating compatibility from pairing/trust.
- Provisional device-identity architecture decision, shared contract/vector verification, and a test-only Android Keystore ↔ Mac Keychain interchange harness. Platform implementations are described in their component changelogs.
- Minimal monorepo scaffold for Android, macOS, optional shared Rust logic, protocol contracts under `protocol/schemas/`, documentation, tests, tools, and scripts. Network framing and serialization remain undecided.
- Root README and agent context describing project direction, current repository state, unresolved decisions, and navigation to design and change history.
- Design guide covering the Mac window, menu-bar companion, Android, semantic colors, live activities, clipboard preferences, and native implementation constraints.
- Separate component changelogs and generic ignore rules for generated output, local configuration, and private planning references.
- GNU GPL version 3 license text and an explicit GPL-3.0-or-later licensing declaration.

### Changed

- Separate agent-run automated/native evidence from pending user manual acceptance in verification reports, roadmap, app documentation and operational notes.
- Simplify root and app READMEs with concise structure trees and direct links to design, roadmap, and protocol documentation.
- Correct Mac development Keychain export-policy handling and document explicit recovery for older development identities.
- Organize native identity code into app shells, feature presentation, and identity infrastructure; update code maps and verification paths.
- Harden the identity interchange harness against skipped tests and stale success artifacts, with native negative controls, independent OpenSSL verification, and adversarial runner checks.
- Refine local device details on both platforms using the existing native design direction.
- Extend ignore rules for Kotlin and native Android build caches, Xcode result bundles, archives, and debug-symbol bundles.
- Update repository status and agent context for the Android and macOS foundations; implementation changes are recorded in their component changelogs.

Android uses development version `0.0.0-dev`; macOS uses numeric `0.0.0` to follow Apple's bundle-version conventions. Both identify unreleased foundations, not published releases.

Both native applications build locally and include identity, discovery and pairing infrastructure. User manual acceptance and minimum-OS coverage remain pending. Secure-session record/BLE/UI integration, LAN synchronization and CI remain deferred.
