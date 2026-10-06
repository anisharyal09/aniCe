# aniCe

A local-first companion for Android and macOS, built with Kotlin/Compose and Swift/SwiftUI.

**Current phase: persistent device identity.** Both apps show a local device ID, fingerprint, key-protection status, and confirmed reset. Device discovery, pairing, and communication are not implemented yet.

## Repository structure

```text
apps/
  android/              Android app and tests
  macos/                Mac app, Xcode project, and tests
protocol/
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

- [Android setup and code structure](apps/android/README.md)
- [macOS setup and code structure](apps/macos/README.md)
- [Code organization](docs/development/code-organization.md)
- [Design guide](docs/design/DESIGN.md)
- [Identity decision](docs/decisions/0001-provisional-device-identity.md) · [Protocol](protocol/README.md)
- [Verification and pending coverage](docs/development/identity-verification.md)

Android uses Keystore. The current ad-hoc Mac build uses development Keychain storage; signed Secure Enclave operation remains unverified. Android 10 and macOS 14 are provisional minimums.

Changes: [repository](CHANGELOG.md) · [Android](apps/android/CHANGELOG.md) · [macOS](apps/macos/CHANGELOG.md).

Licensed under [GPL-3.0-or-later](LICENSE).
