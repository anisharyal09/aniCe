# aniCe for macOS

Swift 6 and SwiftUI provide persistent device identity, a main window, and a menu-bar companion. QR/PIN pairing includes authenticated identity proofs, mutual approval and local peer trust. Manual feature/UI testing and native device checks have been completed on the current phone/Mac setup.

Native EDHOC method 0/suite 5, directional AES-GCM records, BLE v2, readiness, negotiated encrypted keepalive and manual authenticated LAN TCP connections with shared peer reservations are implemented. Extended background endurance, minimum-OS runtime coverage and independent security review remain open. Manual Connect retains its 120-second admission window.

Opt-in Connect automatically shares nearby admission, allowed-phone selection and fresh-session renewal between window and menu companion. Disconnect pauses it; sleep/wake retires/restores availability. [Background BLE](../../docs/BACKGROUND_CONNECTIONS.md) records acceptance gates.

## Development version and verification

Current build: **0.2.0-dev · build 2**. Now Playing, Local File Transfer, Find Device and text Clipboard are implemented and manually exercised; this version also includes the native UI overhaul. This is an unreleased development milestone.

## Nearby discovery

Mac advertises only the public aniCe service UUID and generic name for 120 seconds, with a rotating GATT discovery nonce. Discovery does not pair or trust devices.

## Code structure

```text
aniCe/
  App/                         Assembly, navigation, window and companion
  Features/                    Identity, discovery, pairing and session presentation
    Clipboard/                 Clipboard model, pasteboard observation, manual/auto text sync
    FindDevice/                Peer ring request actions, sound player and notification setup
    NowPlaying/                Playback model, native bridge, session link, codecs and views
      Adapter/                 Attributed helper sources, Perl loader and packaging
    Transfer/                  Transfer model, destination publisher, rolling rate, views and codecs
  Infrastructure/
    Connections/               BLE/LAN owners and feature-neutral DATA dispatch
    Identity/                  Keychain storage and identity lifecycle
    Bluetooth/                 Native peripheral adapter and framing
    LAN/                       Bonjour, TCP, framing and bounded ingress queue
    Pairing/                   Bootstrap, trust and native PAKE interface
    Session/                   EDHOC, encrypted records and readiness
  UI/                          Shared palette and components
  Info.plist                   Native service and permission declarations
  aniCe.entitlements           App Sandbox disabled; hardware/network entitlements
aniCeTests/                    Hosted suites and shared fixtures
  Clipboard/                   Clipboard model, debounce and wire codec test suites
  FindDevice/                  Find device payload and state transition test suites
  NowPlaying/                  Media and packaged-adapter suites; standalone AdapterChecks
  Transfer/                    Transfer model and wire codec test suites
IdentityInterchange/           Native test-only signature endpoint
SessionInterchange/            Native test-only session/TCP endpoints
aniCe.xcodeproj/               Target membership, build inputs and shared scheme
```

The window and companion share identity, connection state and the allowed-device selection. Connect freezes one selected Android credential or accepts any trusted Android, with only one admitted candidate at a time. The authenticated phone name is shown after readiness. The full nearby-discovery label toggles its content. When adding or moving Swift files, update Xcode target membership and any interchange compiler paths. Shared contracts and vectors live in the root [`protocol/`](../../protocol/).

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

For the strict aggregate gate, run from the repository root:

```sh
python3 scripts/verify-suite.py fast --macos --vector-python .venv/bin/python
```

The gate enables the Keychain tests, cross-checks the result bundle against `xcodebuild`'s test-case lines, and fails on zero tests, failures, crashes and undocumented skips. The real-player/manual tests are printed by name when they cannot run.

## Development storage

The storage backend remains the development login Keychain, without hardware isolation. The default build uses local ad-hoc signing without a certificate requirement. Existing identity loads validate metadata, public key and protection policy without a preliminary signature; creation/reset still sign a challenge before committing, and every requested signature is verified. Stable certificate signing keeps code identity across rebuilds; ad-hoc builds may require renewed Keychain authorization. Older keys with the incorrect export policy require confirmed reset; identity is never silently replaced. Removing the app may leave Keychain items behind.

The separate signed data-protection/Secure Enclave backend requires real signing and authorized entitlements; native verification is pending. Universal builds support Apple Silicon and Intel. macOS 14 is the provisional minimum; runtime coverage remains pending.

[Design](../../docs/design/DESIGN.md) · [Roadmap](../../docs/ROADMAP.md) · [Changelog](CHANGELOG.md)

Licensed under [GPL-3.0-or-later](../../LICENSE).

Signing diagnostics log only operation counts under `identity-signing`; repeated UI prompts still require physical observation.

## Secure sessions

Mac taps **Connect** to open Bluetooth admission; Android selects a trusted Mac on Home and taps **Connect**. The device summary shows **Connected** only after encrypted readiness, names ready transports and keeps secondary-channel failures separate. **Connection details** contains transport-specific controls and collapsed **Diagnostics** for checks/counters/discovery. Details use a sheet in Devices; the companion opens that main-window destination. **Manage devices** opens pairing/trust management; active pairing remains visible. Several trusted phones require a concrete selection for LAN. [LAN ownership and verification](../../docs/LAN_CONNECTIONS.md). [Local File Transfer](../../docs/features/FILE_TRANSFER.md) provides bidirectional file transfers over authenticated LAN with BLE fallback when LAN is disconnected.

Pairing offers Connect automatically before approval and starts fresh Bluetooth work after mutual trust activation and pairing cleanup, returning to Home. Android first enable still requires the native companion association dialog; build/platform availability gates remain enforced. Manual LAN is independent.

Overview, Devices, Features, Favourites, Settings and About use a native sidebar. Overview owns a compact device/status header, file controls and playback; Devices retains connection and trust management, with direct LAN access; security details remain nested. Companion arrows select the peer and open its details in Devices before restoring the main window. Settings has a compact This device entry opening local identity and explicit name editing, alongside saved Window appearance; System resolves application appearance; the main window and connection-details sheet apply the resolved native presentation scheme. The companion and context menus follow macOS appearance independently. Feature boxes use trailing chevrons and stars for local favourites on a separate Favourites page. Cards expand with the window and use at most two columns. About aniCe shows the installed version, license and source link.

## Now Playing

Features → Now Playing → Playback setup provides remote playback to Android. Local Overview/companion playback is optional and off by default. See [Now Playing](../../docs/features/NOW_PLAYING.md) for controls, permissions and limitations.

## Local File Transfer

Overview → Files and the companion provide file sending, incoming batch approval, folder selection and progress tracking with rolling rate metrics. Incoming files use exclusive job-owned partials and checked verification before non-overwriting publication via atomic hard link or copy fallback. Mid-stream channel loss automatically pauses with in-memory partial retention, auto-resuming over reconnected LAN or explicit Bluetooth continuation; cross-launch resume after process death remains unavailable. See [Local File Transfer](../../docs/features/FILE_TRANSFER.md).

Debug/Release disable App Sandbox for the whole app. Journals retain their existing container paths without migration or reset; [ADR 0007](../../docs/decisions/0007-macos-unsandboxed-playback-prototype.md) records signing and access consequences.

## Find Device

Features → Find Device opens peer request actions and local notification setup. See [Find Device](../../docs/features/FIND_DEVICE.md) for acknowledgement semantics, verified Samsung ringing/Stop/timeout checks and the remaining device-state matrix.

## Clipboard

Features → Clipboard provides manual text sharing and off-by-default per-device automatic sharing over LAN or BLE. Receiving writes directly to the native clipboard. Android automatic reads require aniCe input focus; Mac observation respects pasteboard access settings. [Clipboard behavior and physical acceptance gates](../../docs/features/CLIPBOARD.md) describe the background-overwrite limitation and verification still required.
