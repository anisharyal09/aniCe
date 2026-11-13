<h2 align="center">
  <img src="assets/logo/anice-mark-final.svg" width="168" alt="aniCe silver interlocking ribbon mark"><br>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo/anice-wordmark-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/logo/anice-wordmark-light.svg">
    <img src="assets/logo/anice-wordmark.svg" height="27" alt="aniCe">
  </picture>
</h2>

<p align="center">
  <strong>Seamless continuity between Android and Mac.</strong>
</p>

A native Android–Mac bridge for file sharing, clipboard, messages and remote controls. Devices pair directly and exchange feature data over local Bluetooth or Wi-Fi; no account or relay service is required.

Maintainer testing starts with **0.9.0-beta.1 · build 90021**, followed by in-app update testing before the public beta. Available builds appear on [GitHub Releases](https://github.com/anisharyal09/aniCe/releases); see the [release plan](docs/ROADMAP.md) for the planned sequence.

## Install and connect

- **Mac:** Apple Silicon, macOS 14 or newer. Intel Macs are not supported.
- **Android:** Android 10 / API 29 or newer; some background features require Android 12 / API 31 or newer. Minimum-version device acceptance remains pending.
- Follow [installation, pairing and updates](docs/GETTING_STARTED.md). Feature permissions are requested when needed.

## Features

### Use the Mac without opening its main window

Keep aniCe running in the menu bar; closing the window does not quit it.

- **[Edge Drop](docs/features/FILE_TRANSFER.md#sending):** On by default at the right edge. Drag regular Finder files to the Mac screen edge to send them to the selected compatible phone; change the edge or turn the shelf off in Settings → File transfer.
- **[Quick Paste Tray](docs/features/CLIPBOARD.md#quick-paste-tray-on-macos):** `⌥⌘V` opens searchable local clipboard history with previews, filters and pins. Copy a selection for ordinary paste, even without a connected phone.
- **[Floating Key](docs/features/KEYBOARD_TRACKPAD.md#floating-key):** `⌥⌘K` opens a compact control for typing on Android from your Mac; expand it for trackpad and navigation actions. aniCe trust, system Bluetooth pairing and a confirmed device link are required.
- **Menu-bar sharing:** Choose **Send files…** or **Send clipboard**, and follow current transfer activity from the companion.

**Command-Q quits aniCe**, including its companion and floating controls.

### File sharing and clipboard

- **[File transfer](docs/features/FILE_TRANSFER.md):**
  - **Mac → Android:** Drop regular Finder files into aniCe, use the native picker, or send through the menu bar and Edge Drop, which is on by default.
  - **Android → Mac:** Choose files in another app and use **Share → Send to Mac**.
  - **Receiving:** Choose a local save folder and enable automatic receiving per trusted sender. Incoming files are verified and saved without overwriting existing files.
  - **Recovery:** Interrupted transfers retain verified progress for up to 15 minutes. Reconnect to the same trusted peer over LAN to resume, or explicitly continue over Bluetooth.
  - Folders and unavailable cloud-only files are unsupported. The feature guide explains approval, background behavior and Bluetooth fallback.
- **[Clipboard sync](docs/features/CLIPBOARD.md):** Share text and links manually or enable automatic sharing separately on each device. Keep optional local history and open shared HTTP(S) links directly in the Mac browser. Android clipboard observation requires input focus; images and rich text are unsupported.
- **[Quick Paste Tray](docs/features/CLIPBOARD.md#quick-paste-tray-on-macos):** Option–Command–V opens searchable Mac clipboard history with filters, previews, pins and keyboard selection. Return copies the selection for ordinary paste; the tray does not inject text into another app.

### Keyboard, trackpad and workspace controls

- **[Control Mac](docs/features/PHONE_TO_MAC.md):** Use your phone as a keyboard and trackpad to type, move the pointer, click, drag and scroll over an authenticated Bluetooth session. Mac input permission is required.
- **[Control Android](docs/features/KEYBOARD_TRACKPAD.md):** Use your Mac keyboard and trackpad through system Bluetooth HID, including Android Home, Back and Recents controls. Option–Command–K toggles the floating control; native Bluetooth pairing and an explicit device link are required.
- **[Mac Desk Deck](docs/features/MAC_DESK_DECK.md):** See CPU, memory, thermal pressure and power status on your phone. Request Mac lock, open screenshot controls, toggle DND, adjust supported audio controls, switch output devices and launch Mac-approved apps. Screenshots stay on the Mac; controls depend on permissions and hardware.

### Playback, messages and notifications

- **[Notification mirroring](docs/features/NOTIFICATION_MIRRORING.md):** Act on selected phone notifications from native Mac alerts: send inline replies, use supported app actions, open the source app on Android and dismiss alerts across both devices. Source icons arrive over LAN; available content and actions depend on Android and the source app.
- **[Incoming calls](docs/features/NOTIFICATION_MIRRORING.md#what-is-mirrored):** Answer or decline supported incoming-call alerts from the Mac, with optional caller names or numbers after permission setup. Call audio stays on the phone.
- **[Messages](docs/features/SMS.md):** Browse and search Android SMS conversations, receive Mac alerts and send replies, with an active SIM choice where available. RCS and MMS sending are unsupported.
- **[Now Playing](docs/features/NOW_PLAYING.md):** Control your Mac’s playback from your phone with live track details, album artwork, automatic or manual player selection, and supported play/pause, skip and seek controls. Adjust supported player and Mac output volume, including with the phone’s volume buttons. Use the full player or Android notification/lock-screen controls when background ownership permits; optionally show playback in the Mac companion. Artwork uses LAN; audio keeps playing on the Mac.
- **[Do Not Disturb sync](docs/features/DND_SYNC.md):** Relay phone DND changes to configured Mac Shortcuts.
- **[Find Device](docs/features/FIND_DEVICE.md):** Ring a connected phone or notify a connected Mac through an existing trusted connection.

### System integration and everyday access

Both apps show the connected peer’s battery and charging state without starting a new connection.

Choose System, Light or Dark appearance and adjust text size. Features and Favourites keep their saved order. Automatic connections can be paused for a preset/custom duration or until manually resumed; see [connection controls](docs/GETTING_STARTED.md#manage-connections).

Beta updates are opt-in and require confirmation before enabling. **About → Report an issue** opens a user-reviewed GitHub form with app and OS versions; submitting requires a GitHub account.

## Native technical foundation

**Built from scratch:** aniCe has its own native Android and Mac apps and continuity protocol.

- **Android:** Kotlin, Jetpack Compose and Material 3, with Android Keystore, system notifications, media controls, the Share sheet and companion-device APIs.
- **Mac:** Swift 6, SwiftUI and AppKit, with native windows, menu-bar controls, clipboard access, Bluetooth HID, audio controls and Shortcuts integration.
- **Shared foundation:** Versioned protocol contracts and test vectors define pairing, encrypted sessions and feature messages. A small Rust bridge supplies OPAQUE PIN pairing; identity storage, connections and feature owners remain native to each platform.
- **Direct connections:** Bluetooth Low Energy and local Wi-Fi carry authenticated feature data between trusted devices. LAN transfer profile 4 supports chunks up to 512 KiB and up to 4 MiB outstanding; these are negotiated limits, not promised transfer rates.

aniCe uses open-source libraries; the Mac Now Playing adapter includes code adapted from Vorssaint with [upstream attribution](apps/macos/aniCe/Features/NowPlaying/Adapter/THIRD_PARTY_NOTICES.md).

See [architecture](ARCHITECTURE.md), [protocol contracts](protocol/README.md) and [performance](docs/PERFORMANCE.md) for the system design and its limits.

## Security and privacy

Pairing uses QR authentication or an OPAQUE six-digit code exchange, with approval on both devices. Trusted BLE and LAN sessions use EDHOC and directional AES-256-GCM records. Discovery is unauthenticated and does not advertise device identities or fingerprints. LAN uses framed TCP with aniCe's encrypted session protocol.

Android identity keys use Android Keystore and report the actual protection available. Current Mac builds use the development Keychain backend; they do not claim Secure Enclave isolation. System Bluetooth HID uses its own OS-managed security. The Mac app is unsandboxed to support native integrations.

Feature content travels between devices. Update checks and downloads contact GitHub. aniCe has no analytics service. See [architecture and trust boundaries](ARCHITECTURE.md) and [security reporting](SECURITY.md).

## Build and contribute

Install the prerequisites in [Mac setup](apps/macos/README.md), [Android setup](apps/android/README.md) and [Rust setup](core/rust/pairing/README.md), then build from the repository root:

```sh
./scripts/dev.sh mac
./scripts/dev.sh android
./scripts/dev.sh android --serial DEVICE_SERIAL
```

See [contributing](CONTRIBUTING.md) for development checks and contribution guidance.

## Repository structure

```text
apps/android/       Native Android app and tests
apps/macos/         Native Mac app, Xcode project and tests
core/rust/pairing/  Shared OPAQUE pairing bridge
protocol/           Wire contracts, schemas and test vectors
scripts/            Build, release and verification tools
docs/               Feature guides, design, decisions and roadmap
```

- [Architecture](ARCHITECTURE.md) · [Decisions](docs/decisions/README.md) · [Protocol contracts](protocol/README.md)
- [Design](docs/design/DESIGN.md) · [Roadmap](docs/ROADMAP.md) · [Performance](docs/PERFORMANCE.md)
- [Background Bluetooth](docs/BACKGROUND_CONNECTIONS.md) · [LAN ownership](docs/LAN_CONNECTIONS.md)
- [Changelog](CHANGELOG.md) · [Android changes](apps/android/CHANGELOG.md) · [Mac changes](apps/macos/CHANGELOG.md) · [Protocol changes](protocol/CHANGELOG.md)

Licensed under [GPL-3.0-or-later](LICENSE).
