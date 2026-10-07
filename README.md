# aniCe

A local-first companion for Android and macOS, built with Kotlin/Compose and Swift/SwiftUI.

**Current phase: nearby BLE discovery (physical acceptance pending).** Mac can advertise a bounded discovery window; Android scans, reads the discovery protocol, and disconnects. Discovery is unauthenticated and creates no trust. Persistent local identity remains available; pairing, secure sessions, and synchronization are later phases.

## Repository structure

```text
apps/
  android/              Android app and tests
  macos/                Mac app, Xcode project, and tests
protocol/
  bluetooth/            BLE discovery contract
  schemas/              Shared public identity contract
  test-vectors/         Cryptographic verification cases
  fixtures/             Sample public identities
scripts/                Identity interchange harness and its tests
docs/
  design/               Shared design guide
  decisions/            Architecture decisions
  development/          Code organization and verification
.agents/                Operational coding context
core/rust/              Reserved; no shared runtime yet
tests/                  Reserved for system tests
tools/                  Reserved for developer utilities
```

## Development

- [Roadmap](docs/ROADMAP.md) · [Design guide](docs/design/DESIGN.md) · [Protocol](protocol/README.md)
- [Android app setup](apps/android/README.md) · [macOS app setup](apps/macos/README.md)
- [Architecture decisions](docs/decisions/0001-provisional-device-identity.md) (ADR [0001](docs/decisions/0001-provisional-device-identity.md), [0002](docs/decisions/0002-provisional-ble-discovery.md))

Android uses Keystore. The current ad-hoc Mac build uses development Keychain storage; signed Secure Enclave operation remains unverified. Android 10 and macOS 14 are provisional minimums.

Changes: [repository](CHANGELOG.md) · [Android](apps/android/CHANGELOG.md) · [macOS](apps/macos/CHANGELOG.md).

Licensed under [GPL-3.0-or-later](LICENSE).
