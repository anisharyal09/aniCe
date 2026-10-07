# aniCe for macOS

Swift 6 and SwiftUI. Phase 2 provides persistent device identity, a main window, and a menu-bar companion. Phase 4 adds QR/PIN pairing, authenticated identity proofs, mutual approval, and local peer trust. Physical acceptance and security review remain pending.

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
aniCe.xcodeproj/                     Targets, source references, shared scheme
```

The window and companion share one identity model. When adding or moving Swift files, update Xcode target membership and any interchange compiler paths. Shared contracts and vectors live in the root [`protocol/`](../../protocol/).

## Run and check

First run `python3 scripts/build-pairing-native.py macos` from the repository root using the [native prerequisites](../../core/rust/pairing/README.md). Then open `aniCe.xcodeproj`, select **aniCe → My Mac**, and press **Command-R**. Closing the window leaves the companion running; **Open aniCe** or the Dock icon reopens it. **Command-Q** quits.

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

The current ad-hoc build explicitly uses the login Keychain, without hardware isolation. Rebuilds may require renewed authorization. Older keys with the incorrect export policy require confirmed reset; identity is never silently replaced. Removing the app may leave Keychain items behind.

The separate signed data-protection/Secure Enclave backend requires real signing and authorized entitlements; native verification is pending. Universal builds support Apple Silicon and Intel. macOS 14 is the provisional minimum; runtime coverage remains pending.

[Design](../../docs/design/DESIGN.md) · [Roadmap](../../docs/ROADMAP.md) · [Changelog](CHANGELOG.md)

Licensed under [GPL-3.0-or-later](../../LICENSE).

Signing diagnostics log only operation counts under `identity-signing`; repeated UI prompts still require physical observation.
