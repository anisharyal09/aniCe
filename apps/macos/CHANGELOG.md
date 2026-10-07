# macOS changelog

Changes to the aniCe Mac app. Repository-wide changes are recorded in the [root changelog](../../CHANGELOG.md).

## Unreleased

### Changed

- Apply reviewed Xcode recommendations for compiler warnings, dead-code stripping, and build-script sandboxing. Keep legacy development Keychain deprecation warnings visible until signed storage/migration are verified.
- Simplify the app README around its source structure, run/check commands, and development storage limits; document state ownership beside app assembly and loading.
- Present identity recovery in a focused details panel with actions appropriate to the storage failure; an older key policy offers confirmed replacement, while temporary access failures offer Retry. Reuse the existing semantic palette.
- Correct the legacy development key's non-extractable generation policy and replace private-key attribute copying with metadata-only inspection, avoiding its implicit export path. Preserve older keys and require explicit reset for an incorrect policy. Remove redundant signing self-checks while retaining pre-commit validation and returned-signature verification.
- Group sources into App, Features, Infrastructure, and UI; separate identity assembly/model/view and update Xcode references. Reuse the initial identity load when opening details, retain explicit Retry, and report denied Keychain authorization distinctly.
- Add negative signature controls to the native interchange utility.
- Refine “This device” with a clear device heading, grouped identity details, readable fingerprint, and a separate reset section.

### Added

- Explicit bounded BLE peripheral discovery shared by window and companion, read-only rotating nonce payload, sandbox/usage configuration, sleep/Quit cleanup, and deterministic discovery tests. Physical acceptance remains pending.

- Persistent P-256 identity with immutable Keychain generations, atomic reset/recovery, typed errors, and signing snapshots. Current ad-hoc builds explicitly select development Keychain; a separate signed data-protection/Secure Enclave backend awaits native verification.
- Full-window “This device” details, ID/fingerprint copying, protection status, confirmed reset, and a companion shortcut to the same sheet.
- Shared-vector, concurrency, interruption-recovery, and isolated Keychain tests, plus disposable native signature interchange.
- Native SwiftUI application with a resizable, single-instance window and an unpaired starting screen.
- Menu-bar companion with Open aniCe and Quit actions, plus Dock reopening after the main window closes.
- System light and dark appearance using the shared aniCe palette.
- Xcode project, shared aniCe scheme, universal build configuration, and local build and run instructions.

The foundation uses development version `0.0.0` (build `1`) and a provisional macOS 14 minimum.
