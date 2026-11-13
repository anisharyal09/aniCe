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

The first public beta is being prepared. Development metadata is **0.9.0-beta.1 · build 90021**; a version in source does not mean a release has shipped. Published downloads appear on [GitHub Releases](https://github.com/anisharyal09/aniCe/releases).

## Install and connect

- **Mac:** Apple Silicon, macOS 14 or newer. Intel Macs are not supported.
- **Android:** Android 10 / API 29 or newer; some background features require Android 12 / API 31 or newer. Minimum-version device acceptance remains pending.
- Follow [installation, pairing and updates](docs/GETTING_STARTED.md). Feature permissions are requested when needed.

## Features

| Feature | What it does |
| --- | --- |
| [File transfer](docs/features/FILE_TRANSFER.md) | Send files in either direction through Finder drops, optional Mac Edge Drop and Android’s Share sheet. Choose save folders and automatic receiving per trusted sender; interrupted transfers retain verified progress for up to 15 minutes. |
| [Clipboard](docs/features/CLIPBOARD.md) | Share text and links manually or automatically, keep optional local history, and open shared HTTP(S) links directly in the Mac browser. Android clipboard observation requires input focus; images and rich text are unsupported. |
| [Now Playing](docs/features/NOW_PLAYING.md) | Your Mac’s playback, controlled from your phone: live track details, album artwork, automatic or manual player selection, and supported play/pause, skip and seek controls. Adjust supported player and Mac output volume, including with the phone’s volume buttons. Use the full player or Android notification/lock-screen controls when background ownership permits; optionally show playback in the Mac companion. Artwork uses LAN; audio keeps playing on the Mac. |
| [Messages](docs/features/SMS.md) | Browse and search Android SMS conversations, receive Mac alerts and send replies, with an active SIM choice where available. RCS and MMS sending are not supported. |
| [Notification mirroring](docs/features/NOTIFICATION_MIRRORING.md) | Act on your phone’s notifications from native Mac alerts: send inline replies, use supported app actions, open the source app on Android, and dismiss alerts across both devices. Selected apps stay under your control; source icons arrive over LAN. Incoming-call alerts support Answer/Decline where available, with optional caller names or numbers after permission setup. Call audio stays on the phone; available content and actions depend on Android and the source app. |
| [Control Android](docs/features/KEYBOARD_TRACKPAD.md) | Use the Mac keyboard and trackpad through system Bluetooth HID, including Android Home/Back/Recents controls. Option–Command–K toggles the floating control; native Bluetooth pairing and an explicit device link are required. |
| [Control Mac](docs/features/PHONE_TO_MAC.md) | Type, move the pointer, click, drag and scroll using the phone keyboard and trackpad over an authenticated Bluetooth session. Mac input permission is required. |
| [Mac Desk Deck](docs/features/MAC_DESK_DECK.md) | View CPU, memory, thermal pressure and power status; request Mac lock, open screenshot controls, adjust supported audio controls and launch Mac-approved apps. Screenshots stay on the Mac; controls depend on permissions and hardware. |
| [DND sync](docs/features/DND_SYNC.md) | Relay phone DND changes to configured Mac Shortcuts. |
| [Find Device](docs/features/FIND_DEVICE.md) | Ring a connected phone or notify a connected Mac. Uses an existing trusted connection; it does not track location or bypass DND. |

The Mac menu-bar companion keeps device status, current activity and send controls available when the main window is closed. Both apps show the connected peer’s battery and charging state without starting a new connection.

The **Quick Paste Tray** (Option–Command–V) searches and filters optional Mac clipboard history, with previews, pins and keyboard selection. Return copies the selection for ordinary paste; it does not inject text into another app. See [tray controls and history retention](docs/features/CLIPBOARD.md#quick-paste-tray-on-macos).

Choose System, Light or Dark appearance and adjust text size. Features and Favourites keep their saved order. Automatic connections can be paused for a preset/custom duration or until manually resumed; see [connection controls](docs/GETTING_STARTED.md#manage-connections).

## Security and privacy

Pairing uses QR authentication or an OPAQUE six-digit code exchange, with approval on both devices. Trusted BLE and LAN sessions use EDHOC and directional AES-256-GCM records. Discovery is unauthenticated and does not advertise device identities or fingerprints. LAN uses framed TCP with aniCe's encrypted session protocol.

Android identity keys use Android Keystore and report the actual protection available. Current Mac builds use the development Keychain backend; they do not claim Secure Enclave isolation. System Bluetooth HID uses its own OS-managed security. The Mac app is unsandboxed to support native integrations.

Feature content travels between devices. Update checks and downloads contact GitHub. aniCe has no analytics service. See [architecture and trust boundaries](ARCHITECTURE.md) and [security reporting](SECURITY.md).

## Build and contribute

```sh
./scripts/dev.sh mac
./scripts/dev.sh android
./scripts/dev.sh android --serial DEVICE_SERIAL
```

See [Mac setup](apps/macos/README.md), [Android setup](apps/android/README.md), [Rust prerequisites](core/rust/pairing/README.md) and [contributing](CONTRIBUTING.md).

- [Architecture](ARCHITECTURE.md) · [Decisions](docs/decisions/README.md) · [Protocol contracts](protocol/README.md)
- [Design](docs/design/DESIGN.md) · [Roadmap](docs/ROADMAP.md) · [Performance](docs/PERFORMANCE.md)
- [Background Bluetooth](docs/BACKGROUND_CONNECTIONS.md) · [LAN ownership](docs/LAN_CONNECTIONS.md)
- [Changelog](CHANGELOG.md) · [Android changes](apps/android/CHANGELOG.md) · [Mac changes](apps/macos/CHANGELOG.md) · [Protocol changes](protocol/CHANGELOG.md)

Licensed under [GPL-3.0-or-later](LICENSE).
