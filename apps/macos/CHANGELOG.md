# macOS changelog

Changes to the aniCe Mac app. Repository-wide changes are recorded in the [root changelog](../../CHANGELOG.md).

## Unreleased

### Fixed

- Send encrypted cancellation on pairing Decline, with bounded transport draining before invitation cleanup and QR/PIN regression coverage.

### Added

- Pairing: QR and six-digit code invitations with PAKE bootstrap, stable three-characteristic GATT peripheral adapter, mutual approval, atomic peer trust store, dedicated pairing and trusted-devices panels, and persistent window device header.
- Test hardening: baseline fixture inventory floors, independent crypto-vector assertions, pending re-pair recovery at capacity limits, and direct write-failure rollback fault injection.

- Explicit bounded BLE peripheral discovery shared by window and companion, read-only rotating nonce payload, sandbox/usage configuration, sleep/Quit cleanup, and deterministic discovery tests. Physical acceptance remains pending.

- Persistent P-256 identity with immutable Keychain generations, atomic reset/recovery, typed errors, and signing snapshots. Current ad-hoc builds explicitly select development Keychain; a separate signed data-protection/Secure Enclave backend awaits native verification.
- Full-window “This device” details, ID/fingerprint copying, protection status, confirmed reset, and a companion shortcut to the same sheet.
- Shared-vector, concurrency, interruption-recovery, and isolated Keychain tests, plus disposable native signature interchange.
- Native SwiftUI application with a resizable, single-instance window and an unpaired starting screen.
- Menu-bar companion with Open aniCe and Quit actions, plus Dock reopening after the main window closes.
- System light and dark appearance using the shared aniCe palette.
- Xcode project, shared aniCe scheme, universal build configuration, and local build and run instructions.

The foundation uses development version `0.0.0` (build `1`) and a provisional macOS 14 minimum.
