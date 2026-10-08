# aniCe

A local-first companion for Android and macOS, built with Kotlin/Compose and Swift/SwiftUI.

**Current phase: native secure-session feasibility (minimum-OS runtime gate pending).** Native EDHOC engines authenticate existing trusted peers; record/BLE/UI integration awaits API 29/macOS 14 verification. QR/PIN pairing and mutual trust approval remain available. Discovery remains unauthenticated; synchronization is planned.

User manual verification is pending for all implemented features. Agent-run automated and native checks are recorded separately in local [verification status](docs/A&V/VERIFICATION_STATUS.md).

## Repository structure

```text
apps/
  android/              Android app and tests
  macos/                Mac app, Xcode project, and tests
protocol/
  bluetooth/            BLE discovery contract
  pairing/              Authenticated bootstrap and control-pipe contract
  session/              Native EDHOC profile and gated record/BLE contract
  schemas/              Shared public identity contract
  test-vectors/         Cryptographic verification cases
  fixtures/             Sample public identities
scripts/                Identity/session interchange and native pairing builds
docs/
  design/               Shared design guide
  decisions/            Architecture decisions
.agents/                Operational coding context
core/rust/              Pinned ephemeral OPAQUE bridge
tests/                  Reserved for system tests
tools/                  Reserved for developer utilities
```

## Development

- [Roadmap](docs/ROADMAP.md) · [Design guide](docs/design/DESIGN.md) · [Protocol](protocol/README.md)
- [Android app setup](apps/android/README.md) · [macOS app setup](apps/macos/README.md)
- [Architecture decisions](docs/decisions/0001-provisional-device-identity.md) (ADR [0001](docs/decisions/0001-provisional-device-identity.md), [0002](docs/decisions/0002-provisional-ble-discovery.md), [0003](docs/decisions/0003-provisional-pairing-and-trust.md), [0004](docs/decisions/0004-stable-ble-attribute-layout.md), [0005](docs/decisions/0005-edhoc-secure-sessions.md))
- Local [session verification and pending gates](docs/A&V/SESSION_VERIFICATION.md)

Android uses Keystore. The current ad-hoc Mac build uses development Keychain storage; signed Secure Enclave operation remains unverified. Android 10 and macOS 14 are provisional minimums.

Changes: [repository](CHANGELOG.md) · [Android](apps/android/CHANGELOG.md) · [macOS](apps/macos/CHANGELOG.md).

Licensed under [GPL-3.0-or-later](LICENSE).

Pairing setup: [native toolchain](core/rust/pairing/README.md).
