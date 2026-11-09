# aniCe for macOS

Swift 6 and SwiftUI provide persistent device identity, a main window, and a menu-bar companion. QR/PIN pairing includes authenticated identity proofs, mutual approval and local peer trust. Manual feature/UI testing and native device checks have been completed on the current phone/Mac setup.

The [path-only ringless silver ribbon](../../branding/anice-mark-final.svg) supplies the app icon, sidebar, About and menu-bar art. The app icon uses a full rounded Light tile. The Dock switches between Light and Dark appearance-aware tiles with extra transparent inset around the tile, keeping the mark at its selected size alongside neighboring icons. The menu-bar companion uses a 21.5 pt shaded template.

Native EDHOC method 0/suite 5, directional AES-GCM records, BLE v2, readiness, negotiated encrypted keepalive and manual authenticated LAN TCP connections with shared peer reservations are implemented. Manual Connect retains its 120-second admission window.

Opt-in Connect automatically shares nearby admission, allowed-phone selection and fresh-session renewal between window and menu companion. Disconnect pauses it; sleep/wake retires/restores availability. [Background BLE](../../docs/BACKGROUND_CONNECTIONS.md) records lifecycle policy.

## Current release

Current build: **v0.3.0 · build 3**. Now Playing, Local File Transfer, Find Device, text Clipboard and SMS relay are included.

## Nearby discovery

Mac advertises only the public aniCe service UUID and generic name for 120 seconds, with a rotating GATT discovery nonce. Discovery does not pair or trust devices.

## Code structure

```text
aniCe/
  App/                         Assembly, navigation, window and companion
  Features/                    Identity, discovery, pairing and session presentation
    Clipboard/                 Clipboard model, pasteboard observation, manual/auto text sync
    FindDevice/                Peer ring request actions, sound player and notification setup
    KeyboardTrackpad/          Native input model/views, floating panel and Objective-C HID adapter
    PhoneInput/                Secured BLE receiver, native input adapter and receiver controls
    NowPlaying/                Playback model, native bridge, session link, codecs and views
      Adapter/                 Attributed helper sources, Perl loader and packaging
    Sms/                       SMS relay model, wire codec, notifier and views
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
  KeyboardTrackpad/            Input ownership, focus, gestures and native HID protocol tests
  PhoneInput/                  Phone-to-Mac receiver, event translation and wire codec tests
  NowPlaying/                  Media and packaged-adapter suites; standalone AdapterChecks
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

Requires Xcode and the [native Rust prerequisites](../../core/rust/pairing/README.md). Install an Apple Development certificate in Xcode, then set your team in ignored `scripts/dev.local.sh`:

```sh
ANICE_DEVELOPMENT_TEAM='YOUR_TEAM_ID'
# Optional: certificate name or SHA-1 when multiple certificates are installed.
# ANICE_CODE_SIGN_IDENTITY='Apple Development: Your Name (CERTIFICATE_ID)'
```

The script quits aniCe, builds Debug, verifies the signature/team and launches the exact output. If another copy remains open, it stops before building. It never resets permissions. Set `DEVELOPER_DIR` if Xcode is installed elsewhere.

- App: `build/dev-mac/<checkout>-<branch>/Build/Products/Debug/aniCe.app` under the checkout root.
- Display name: `aniCe (<branch>)`; the window header stays aniCe.
- Branch slashes are escaped as `_2F`, underscores as `_5F`, and percent signs as `_25` in folder names. This keeps branch copies distinct without percent escapes that break Xcode's SDK stat-cache paths. Detached checkouts use their commit ID.
- Worktrees have separate build folders but share app identity, permissions and device state. Run one copy at a time; Mac hosted tests also use aniCe, so let those finish before running the launcher. Each worktree needs its own local signing file or exported environment settings.
- Closing the window leaves the companion running. **Command-Q** quits.

Configure input access in **Settings → Permissions**. If an enabled permission still fails after restarting, use **Show this app in Finder** and re-add that exact copy in System Settings. See [permission recovery](../../docs/features/PHONE_TO_MAC.md#permission-recovery-during-development).

Opening the project in Xcode and pressing Command-R uses its own DerivedData copy. The shared project defaults to ad-hoc signing; use the script for repeat permission testing.

## Archive and distribution

**Product → Archive** uses Release. The app is named **aniCe**, without a branch suffix. In the archive it lives at `Products/Applications/aniCe.app`.

Release shows **Mac input allowed** when Event Posting is granted, or the permission action when blocked. Developer signing warnings appear only in Debug. Copying the app preserves its signature; it does not grant permissions on another Mac.

**The checked-in Release configuration is ad-hoc signed too.** An archive copied directly from it is a local test build. For public distribution outside the Mac App Store, use Organizer → Distribute App with Developer ID signing and notarization. See [Apple's distribution workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). Development and distribution signatures may require separate privacy approval; see [Apple's signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

## Checks

From the repository root:

```sh
python3 scripts/verify-suite.py fast --macos --vector-python .venv/bin/python
python3 scripts/test_dev.py
```

The Mac gate includes Keychain tests and rejects zero tests, failures, crashes and undocumented skips. It prints the real-player/manual checks that cannot run.

## Development storage

The storage backend remains the development login Keychain, without hardware isolation. Local app builds default to ad-hoc signing; developers may use a stable Apple Development identity locally when testing macOS permission persistence. Automated tests remain ad-hoc signed. Existing identity loads validate metadata, public key and protection policy without a preliminary signature; creation/reset still sign a challenge before committing, and every requested signature is verified. Older keys with the incorrect export policy require confirmed reset; identity is never silently replaced. Removing the app may leave Keychain items behind.

The separate data-protection/Secure Enclave backend requires certificate signing and authorized entitlements. Universal builds support Apple Silicon and Intel; macOS 14 is the deployment target.

[Design](../../docs/design/DESIGN.md) · [Roadmap](../../docs/ROADMAP.md) · [Changelog](CHANGELOG.md)

Licensed under [GPL-3.0-or-later](../../LICENSE).

Signing diagnostics log only operation counts under `identity-signing`; repeated UI prompts still require physical observation.

## Secure sessions

Mac taps **Connect** to open Bluetooth admission; Android selects a trusted Mac on Home and taps **Connect**. The device summary shows **Connected** only after encrypted readiness, names ready transports and keeps secondary-channel failures separate. **Connection details** contains transport-specific controls and collapsed **Diagnostics** for checks/counters/discovery. Details use a sheet in Devices; the companion opens that main-window destination. **Manage devices** opens pairing/trust management; active pairing remains visible. Several trusted phones require a concrete selection for LAN. [LAN ownership and verification](../../docs/LAN_CONNECTIONS.md). [Local File Transfer](../../docs/features/FILE_TRANSFER.md) prefers authenticated LAN for new sends and asks before using Bluetooth when the LAN attempt does not succeed.

Pairing offers Connect automatically before approval and starts fresh Bluetooth work after mutual trust activation and pairing cleanup, returning to Home. Android first enable still requires the native companion association dialog; build/platform availability gates remain enforced. Manual LAN is independent.

Overview, Devices, Features, Favourites, Settings and About use a native sidebar. Overview owns a compact device/status header, file controls and playback; Devices retains connection and trust management, with direct LAN access; security details remain nested. Companion arrows select the peer and open its details in Devices before restoring the main window. Settings has a compact This device entry opening local identity and explicit name editing, alongside saved Window appearance; System resolves application appearance; the main window and connection-details sheet apply the resolved native presentation scheme. The companion and context menus follow macOS appearance independently. Feature boxes use trailing chevrons and stars for local favourites on a separate Favourites page. Cards expand with the window and use at most two columns. About aniCe shows the installed version, license and source link.

## Now Playing

Features → Now Playing → Playback setup provides remote playback to Android. Local Overview/companion playback is optional and off by default. See [Now Playing](../../docs/features/NOW_PLAYING.md) for controls, permissions and limitations.

## Control Android (Keyboard & Trackpad, unreleased)

Features → Control Android sends native keyboard and mouse input to a trusted Android phone over Classic Bluetooth HID. Pair in macOS Bluetooth Settings, then confirm the paired device's link to the aniCe phone once. Connecting leaves input idle until you click the keyboard or pointer pad. Two fingers up/down scroll; left/right drags the phone pointer. Scrolling over an inactive embedded pad browses the local panel.

The menu-bar companion's **Keyboard** button shows or hides a persistent floating button; its right-click menu also offers **Show floating keyboard**. Click the floating button to toggle typing, or right-click it for full controls and Hide. Compact position and visibility are saved; reopening restores idle controls. Resizing the full controls preserves keyboard focus. Stopping or hiding releases held input while the HID connection can remain idle.

The Objective-C adapter adapts aniKey's GPL transport and report conventions with aniCe's bounded worker and connection checks; Swift owns trusted targets, input capture and cancellation. See the [feature guide](../../docs/features/KEYBOARD_TRACKPAD.md), [Classic HID contract](../../protocol/bluetooth/classic-hid.md) and [adaptation record](../../docs/decisions/features/keyboard-trackpad/0011-macos-classic-hid-input.md#anikey-adaptation). No Android app component or Accessibility permission is required.

## Phone-to-Mac input

Settings → Permissions shows Event Posting status and setup for Mac input. aniCe checks `CGPreflightPostEventAccess()` before accepting a phone start; Accessibility trust alone is not enough. After access is granted, the authenticated phone can start input without a Mac feature page or receiver toggle. Use the same signed app copy for setup and later runs; ad-hoc rebuilds can invalidate the saved permission. See the [feature guide](../../docs/features/PHONE_TO_MAC.md) and [input contract](../../protocol/phone-input/README.md).

## Local File Transfer

Overview → Files and Features → File transfer support Choose files and drag-and-drop. The optional **Edge Drop** shelf can appear at the right, left or top edge. Receives default to `~/Downloads/aniCe`; saved custom folders and per-phone automatic receiving are available. Sends prefer authenticated LAN, with an explicit Bluetooth choice when LAN setup fails. Transfers pause on connection loss and resume with the same trusted peer. See [Local File Transfer](../../docs/features/FILE_TRANSFER.md).

Debug/Release disable App Sandbox for the whole app. Journals retain their existing container paths without migration or reset; [ADR 0007](../../docs/decisions/0007-macos-unsandboxed-playback-prototype.md) records signing and access consequences.

## Find Device

Features → Find Device opens peer request actions and local notification setup. See [Find Device](../../docs/features/FIND_DEVICE.md) for acknowledgement semantics, verified Samsung ringing/Stop/timeout checks and the remaining device-state matrix.

## Messages (SMS relay)

Features → Messages relays incoming SMS to notifications with an inline reply, reads the phone's conversations and history on demand, searches matching messages in bounded pages without indexing them, and replies on the phone's default SIM unless another active subscription is chosen while the panel is open. The thread list paints 15 cards first, keeps filling from the cursor and shows **Load older conversations** whenever a page is available and none is loading; **Return** or **Command-Return** sends (Shift-Return keeps a newline), and the reply paints as a **Sending** row until the phone confirms it. A conversation that mixes two SIMs labels each row with the subscription it arrived on. Settings → Messages collapses each phone's **Notifications** and **Play sound** switches (both on by default) and the **Show message text in notifications** preview (off by default) behind its clickable name label, and the panel's gear expands the same switches under its row; a failed or unconfirmed reply posts a follow-up alert, and SMS notifications are cleared on quit. See [Messages](../../docs/features/SMS.md) for paging limits, search behavior and the notification controls.

## Clipboard

Features → Clipboard provides manual text sharing and off-by-default per-device automatic sharing over LAN or BLE. Receiving writes directly to the native clipboard. Android automatic reads require aniCe input focus; Mac observation respects pasteboard access settings. [Clipboard behavior](../../docs/features/CLIPBOARD.md) describes permissions, focus rules and the background-overwrite limitation.
