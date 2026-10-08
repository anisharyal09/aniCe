# aniCe for macOS

Swift 6 and SwiftUI provide persistent device identity, a main window, and a menu-bar companion. QR/PIN pairing includes authenticated identity proofs, mutual approval and local peer trust. Comprehensive manual/radio acceptance, minimum-OS coverage and independent integration security review remain pending.

Native EDHOC method 0/suite 5, directional AES-GCM records, BLE v2, readiness and connection controls are implemented. Over-the-air BLE radio inspection, minimum-OS baseline coverage, and independent security review remain pending.

## Nearby discovery

Mac advertises only the public aniCe service UUID and generic name for 120 seconds, with a rotating GATT discovery nonce. Discovery does not pair or trust devices.

## Code structure

```text
aniCe/
  App/
    AniCeApp.swift                  App scenes and shared identity model
    AppDelegate.swift               Window and Dock activation
    MainWindowView.swift            Main window and details sheet
    CompanionView.swift             Menu-bar actions
    IdentityAssembly.swift          Backend and service assembly
  Features/DeviceIdentity/
    IdentityView.swift              Details, copying, reset confirmation
    IdentityViewModel.swift         Presentation state and recovery
  Infrastructure/Identity/
    DeviceIdentity.swift            Public identity validation and encoding
    IdentityService.swift           Actor-isolated lifecycle and signing
    MacIdentityStorage.swift        Keychain backends and atomic metadata
  Infrastructure/Bluetooth/        Peripheral adapter, codec, timed session
  Infrastructure/Pairing/          Bootstrap engine, native crypto, trust journal, PAKE ABI
  Infrastructure/Session/          EDHOC, record and ordering actors, native codecs
  Features/Pairing/                Shared pairing model, QR/PIN and trusted-device view
  Features/Discovery/              Shared discovery model and view
  UI/
    Theme/AniCePalette.swift         Semantic light/dark colors
    Components/EmptyStateView.swift  Unpaired-state view
  aniCe.entitlements                Sandbox configuration
aniCeTests/
  IdentityTests.swift               Hosted identity and storage tests
IdentityInterchange/
  main.swift                        Test-only signature interchange endpoint
SessionInterchange/
  main.swift                        Test-only protected-key EDHOC interchange endpoint
aniCe.xcodeproj/                     Targets, source references, shared scheme
```

The window and companion share identity, connection state and the allowed-device selection. Allow connections freezes one selected Android credential or accepts any trusted Android, with only one admitted candidate at a time. The authenticated phone name is shown after readiness. The full nearby-discovery label toggles its content. When adding or moving Swift files, update Xcode target membership and any interchange compiler paths. Shared contracts and vectors live in the root [`protocol/`](../../protocol/).

## Run and check

First run `python3 scripts/build-pairing-native.py macos` from the repository root using the [native prerequisites](../../core/rust/pairing/README.md). Then open `aniCe.xcodeproj`, select **aniCe → My Mac**, and press **Command-R**. The project uses local ad-hoc signing and requires no Apple account/certificate. Closing the window leaves the companion running; **Open aniCe** or the Dock icon reopens it. **Command-Q** quits.

From `apps/macos/`, with Xcode installed at the path below:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project aniCe.xcodeproj -scheme aniCe -configuration Debug \
    -derivedDataPath /tmp/aniCe-DerivedData ONLY_ACTIVE_ARCH=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
    -project aniCe.xcodeproj -scheme aniCe -configuration Debug \
    -derivedDataPath /tmp/aniCe-DerivedData -destination 'platform=macOS' test
```

App: `/tmp/aniCe-DerivedData/Build/Products/Debug/aniCe.app`. Prefix the test command with `TEST_RUNNER_ANICE_RUN_KEYCHAIN_TESTS=1` to include isolated Keychain integration tests.

## Development storage

The storage backend remains the development login Keychain, without hardware isolation. The default build uses local ad-hoc signing without a certificate requirement. Existing identity loads validate metadata, public key and protection policy without a preliminary signature; creation/reset still sign a challenge before committing, and every requested signature is verified. Stable certificate signing keeps code identity across rebuilds; ad-hoc builds may require renewed Keychain authorization. Older keys with the incorrect export policy require confirmed reset; identity is never silently replaced. Removing the app may leave Keychain items behind.

The separate signed data-protection/Secure Enclave backend requires real signing and authorized entitlements; native verification is pending. Universal builds support Apple Silicon and Intel. macOS 14 is the provisional minimum; runtime coverage remains pending.

[Design](../../docs/design/DESIGN.md) · [Roadmap](../../docs/ROADMAP.md) · [Changelog](CHANGELOG.md)

Licensed under [GPL-3.0-or-later](../../LICENSE).

Signing diagnostics log only operation counts under `identity-signing`; repeated UI prompts still require physical observation.

## Secure sessions

Mac opens **Allow connections**; Android selects a trusted Mac on Home and taps **Connect**. Both show **Secured** after encrypted readiness. **Send connection check** tests the live path in either direction; Disconnect and Retry require a fresh handshake. LAN and feature synchronization remain deferred.
