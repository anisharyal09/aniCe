# aniCe for macOS

Swift 6 and SwiftUI provide persistent device identity, a main window, and a menu-bar companion. QR/PIN pairing includes authenticated identity proofs, mutual approval and local peer trust. Feature-specific verification and limits are recorded in the linked guides.

## Requirements and user setup

Apple Silicon and macOS 14 or newer; Intel is unsupported. Swift 6, SwiftUI/AppKit and a native Rust pairing bridge.

The development version is **0.9.0-beta.1 · build 90021**. See [installation, pairing and updates](../../docs/GETTING_STARTED.md) for user instructions, [feature guides](../../README.md#features) for behavior and permissions, and [architecture](../../ARCHITECTURE.md) for identity and transport ownership.

## Using the Mac app

- **Overview** shows the selected device and current activity; **Devices** owns pairing, trusted phones, automatic connection preferences and independent Bluetooth/LAN controls. Features and Favourites provide saved access to the implemented panels.
- The **menu-bar companion** shares connection owners with the main window. Closing the window keeps it running; Command-Q quits. It offers Send clipboard, Quick Paste Tray, Send files and Floating Key for the selected compatible phone.
- **Control Android** uses native Classic Bluetooth HID after OS pairing and one explicit link to the trusted phone. Option–Command–K toggles Floating Key; input starts deliberately in its capture area. See [keyboard, pointer and clipboard typing](../../docs/features/KEYBOARD_TRACKPAD.md).
- **Clipboard** offers manual sharing, separate automatic-sharing consent and optional local history. Option–Command–V opens the Quick Paste Tray even without a connected phone. Return copies selected history for normal paste; the tray does not type into another application.
- **Send files** accepts local file drops and the native picker. Optional Edge Drop is off by default; automatic receiving and save folders are configured per trusted sender. [File transfer](../../docs/features/FILE_TRANSFER.md) documents approval, recovery and unsupported inputs.
- **Now Playing → Playback setup** configures supported playback controls for Android. Showing playback in Mac Overview/companion is separately optional and off by default. This controls local Mac players; it does not receive an audio stream from the phone.
- **Settings → Desk Deck** approves apps separately for each trusted phone. **Settings → Do Not Disturb** selects the phone-sync On/Off Shortcuts and the separate Desk Deck toggle. **Settings → Permissions** contains the input-access setup needed for Control Mac and supported lock requests.

Notification mirroring presents selected Android alerts as native Mac notifications, including supported inline replies, source-app actions and synchronized dismissal. Incoming-call alerts can offer Answer/Decline and optional caller identity after phone permission setup; call audio stays on Android. Source icons use LAN, and Android/source-app restrictions still apply. See [notification setup and limits](../../docs/features/NOTIFICATION_MIRRORING.md).

Messages, notification mirroring and Find Device use the existing trusted connection. Mac notification visibility still follows system notification and Focus settings. [Feature guides](../../README.md#features) retain their permission, content and platform limits.

## Code structure

```text
aniCe/
  Assets.xcassets/             aniCe development app icon, based on Android launcher artwork
  App/                         Assembly, navigation, window and companion
  Features/                    Identity, discovery, pairing and session presentation
    Clipboard/                 Clipboard model, pasteboard observation, manual/auto text sync
    FindDevice/                Peer ring request actions, sound player and notification setup
    KeyboardTrackpad/          Native input model/views, floating panel and Objective-C HID adapter
    PhoneInput/                Secured BLE receiver, native input adapter and receiver controls
    NowPlaying/                Playback model, native bridge, session link, codecs and views
      Adapter/                 Attributed helper sources, Perl loader and packaging
    Notifications/             Mirrored notification model, source icon attachment, action notifier and wire codec
    Sms/                       SMS relay model, wire codec, notifier and views
    Transfer/                  Transfer model, destination publisher, rolling rate, views and codecs
  Infrastructure/
    Connections/               BLE/LAN owners and feature-neutral DATA dispatch
    Identity/                  Keychain storage and identity lifecycle
    Bluetooth/                 Native peripheral adapter and framing
    LAN/                       Bonjour, TCP, framing and bounded ingress queue
    Pairing/                   Bootstrap, trust and native PAKE interface
    Session/                   EDHOC, encrypted records and readiness
  Update/                      GitHub discovery, archive/signature checks, staging and detached helper
  UI/                          Shared palette and components
  Info.plist                   Native service and permission declarations
  aniCe.entitlements           App Sandbox disabled; hardware/network entitlements
aniCeTests/                    Hosted suites and shared fixtures
  Clipboard/                   Clipboard model, debounce and wire codec test suites
  FindDevice/                  Find device payload and state transition test suites
  KeyboardTrackpad/            Input ownership, focus, gestures and native HID protocol tests
  PhoneInput/                  Phone-to-Mac receiver, event translation and wire codec tests
  NowPlaying/                  Media and packaged-adapter suites; standalone AdapterChecks
  Notifications/               Notification wire, snapshot, native presentation and action suites
  Sms/                         SMS wire codec, relay model and notifier test suites
  Transfer/                    Transfer model and wire codec test suites
IdentityInterchange/           Native test-only signature endpoint
SessionInterchange/            Native test-only session/TCP endpoints
aniCe.xcodeproj/               Target membership, build inputs and shared scheme
```

The window and companion share identity, connection state and the allowed-device selection. Connect freezes one selected Android credential or accepts any trusted Android, with only one admitted candidate at a time. The authenticated phone name is shown after readiness. The full nearby-discovery label toggles its content. When adding or moving Swift files, update Xcode target membership and any interchange compiler paths. Shared contracts and vectors live in the root [`protocol/`](../../protocol/).

## Build and run

From the repository root:

```sh
./scripts/dev.sh mac
```

Requires an Apple Silicon Mac, a native arm64 shell, full Xcode and the [native Rust prerequisites](../../core/rust/pairing/README.md). Install an Apple Development certificate in Xcode, then set your team in ignored `scripts/dev.local.sh`:

```sh
ANICE_DEVELOPMENT_TEAM='YOUR_TEAM_ID'
# Optional: certificate name or SHA-1 when multiple certificates are installed.
# ANICE_CODE_SIGN_IDENTITY='Apple Development: Your Name (CERTIFICATE_ID)'
```

The script quits aniCe, builds Debug, verifies the signature/team and launches the exact output. If another copy remains open, it stops before building. It never resets permissions. Set `DEVELOPER_DIR` if Xcode is installed elsewhere.

- App: `build/dev-mac/<checkout>-<branch-key>/Build/Products/Debug/aniCe.app` under the checkout root.
- Display name: `aniCe (<branch>)`; the window header stays aniCe.
- Branch slashes are escaped as `_2F`, underscores as `_5F`, and percent signs as `_25` in folder names. This keeps branch copies distinct without percent escapes that break Xcode's SDK stat-cache paths. Detached checkouts use their commit ID.
- Worktrees have separate build folders but share app identity, permissions and device state. Run one copy at a time; Mac hosted tests also use aniCe, so let those finish before running the launcher. Each worktree needs its own local signing file or exported environment settings.
- Closing the window leaves the companion running. Dock reopen restores the main window even when companion or floating panels are open; activation restores it whenever no main window is visible. **Command-Q** quits.

Configure input access in **Settings → Permissions**. If an enabled permission still fails after restarting, use **Show this app in Finder** and re-add that exact copy in System Settings. See [permission recovery](../../docs/features/PHONE_TO_MAC.md#permission-recovery).

Opening the project in Xcode and pressing Command-R uses its own DerivedData copy. The shared project defaults to ad-hoc signing; use the script for repeat permission testing.

## Archive and distribution

Product → Archive creates a Release app at `Products/Applications/aniCe.app`. The checked-in configuration is ad-hoc signed; copying this archive does not make it a production release or grant permissions on another Mac.

The GitHub release workflow overrides signing, embeds the update certificate pins and packages the signed helper. It currently uses a self-signed identity, without notarization. Developer ID distribution would require a deliberate signing/pin migration and notarization; see [Apple's distribution workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Checks

From the repository root:

```sh
python3 scripts/verify-suite.py --only macos
python3 scripts/verify-suite.py fast --macos --vector-python .venv/bin/python
python3 scripts/test_dev.py
```

`--only macos` is the CI lane. It requires a full Xcode, rebuilds `build/native/libanice_pairing.a` for Apple Silicon (`arm64`), compiles a native Release build with codesign verification, then runs the hosted suite. The `fast --macos` form also runs the local contract and Rust checks.

The Mac gate includes Keychain tests and rejects zero tests, failures, crashes and undocumented skips. It prints the real-player/manual checks that cannot run.

Timing checks require an awake Mac. Keep the lid open; `caffeinate -i python3 scripts/verify-suite.py --only macos` prevents idle sleep for the run without changing system settings. It does not prevent forced or lid-close sleep.

## Development storage

The storage backend remains the development login Keychain, without hardware isolation. Local app builds default to ad-hoc signing; developers may use a stable Apple Development identity locally when testing macOS permission persistence. Automated tests remain ad-hoc signed. Existing identity loads validate metadata, public key and protection policy without a preliminary signature; creation/reset still sign a challenge before committing, and every requested signature is verified. Older keys with the incorrect export policy require confirmed reset; identity is never silently replaced. Removing the app may leave Keychain items behind.

The separate data-protection/Secure Enclave backend requires certificate signing and authorized entitlements. Official builds, releases and updates support Apple Silicon (`arm64`) only; Intel Macs are not supported. macOS 14 is the deployment target.

[Design](../../docs/design/DESIGN.md) · [Roadmap](../../docs/ROADMAP.md) · [Changelog](CHANGELOG.md)

Signing diagnostics log only operation counts under `identity-signing`; repeated UI prompts still require physical observation.

Licensed under [GPL-3.0-or-later](../../LICENSE).
