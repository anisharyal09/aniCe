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

**aniCe** brings seamless, ecosystem-level continuity between your Android phone and Mac without walled gardens, cloud relays, or subscriptions.

Drag files directly to your screen edge to share them, sync clipboards instantly, reply to phone messages from your Mac keyboard, and monitor your Mac from your phone—all over secure, direct Bluetooth and local-network connections.

- **🔒 100% Private & Local:** Zero accounts, zero relay servers, zero analytics. Your feature data stays strictly local; in-app update checks contact GitHub Releases directly.
- **⚡ Built Natively:** Built in native Swift 6 and SwiftUI on macOS, and Kotlin with Jetpack Compose (Material 3) on Android.
- **🛡️ Secure by Design:** Mutual P-256 ECDSA authentication and encrypted transport protect every interaction between paired devices.

## Features

#### Use the Mac without opening its main window

- **[Edge Drop](docs/features/FILE_TRANSFER.md#sending):** On by default at the right edge. Drag regular Finder files to the Mac screen edge to send them to the selected compatible phone; change the edge or turn the shelf off in Settings → File transfer.
- **[Quick Paste Tray](docs/features/CLIPBOARD.md#quick-paste-tray-on-macos):** `⌥⌘V` opens searchable local clipboard history with previews, filters and pins. Copy a selection for ordinary paste, even without a connected phone.
- **[Floating Key](docs/features/KEYBOARD_TRACKPAD.md#floating-key):** `⌥⌘K` toggles a floating button to send input directly to your phone from your Mac keyboard in a click—with an expandable trackpad control.
- **Menu Bar Companion:** Click the menu bar icon to check phone battery and connection state, control active media playback, track transfer progress, access pinned features directly and quickly send files or clipboard text.

### File sharing and clipboard

- **[File transfer](docs/features/FILE_TRANSFER.md):**
  - **Send instantly:** Drag files to the screen edge (Edge Drop), drop them into the app window, or share from Android via **Share → Send to Mac**.
  - **Receiving:** Choose a local save folder and enable automatic receiving per trusted sender. Incoming files are verified and saved without overwriting existing files.
  - **Resilient recovery:** Interrupted transfers keep verified progress for up to 15 minutes and resume automatically over the local network or Bluetooth.
- **[Clipboard sync](docs/features/CLIPBOARD.md):** Share text and links manually or enable automatic sharing separately on each device. Keep optional local history and open shared HTTP(S) links directly in the Mac browser. Android clipboard observation requires input focus; images and rich text are unsupported.
- **[Quick Paste Tray](docs/features/CLIPBOARD.md#quick-paste-tray-on-macos):** Option–Command–V opens searchable Mac clipboard history with filters, previews, pins and keyboard selection. Return copies the selection for ordinary paste; the tray does not inject text into another app.

### Keyboard, trackpad and workspace controls

- **[Control Mac](docs/features/PHONE_TO_MAC.md):** Use your phone as a keyboard and trackpad to type, move the pointer, click, drag and scroll over an authenticated Bluetooth session. Mac input permission is required.
- **[Control Android](docs/features/KEYBOARD_TRACKPAD.md):** Use your Mac keyboard and trackpad through system Bluetooth HID, including Android Home, Back and Recents controls. Option–Command–K toggles the floating control; native Bluetooth pairing and an explicit device link are required.
- **[Mac Desk Deck](docs/features/MAC_DESK_DECK.md):** See CPU, memory, thermal pressure and power status on your phone. Request Mac lock, open screenshot controls, toggle DND, adjust volume, switch audio output devices and launch Mac-approved apps. Screenshots stay on the Mac; controls depend on permissions and hardware.

### Playback, messages and notifications

- **[Notification mirroring](docs/features/NOTIFICATION_MIRRORING.md):** Act on selected phone notifications from native Mac alerts: send inline replies, use supported app actions, open the source app on Android and dismiss alerts across both devices. Source icons arrive over LAN; available content and actions depend on Android and the source app.
- **[Incoming calls](docs/features/NOTIFICATION_MIRRORING.md#what-is-mirrored):** Answer or decline supported incoming-call alerts from the Mac, with optional caller names or numbers after permission setup. Call audio stays on the phone.
- **[Messages](docs/features/SMS.md):** Browse and search Android SMS conversations, receive Mac alerts and send replies, with an active SIM choice where available. RCS and MMS sending are unsupported.
- **[Now Playing](docs/features/NOW_PLAYING.md):** Control your Mac’s playback from your phone with live track details, album artwork, automatic or manual player selection, and supported play/pause, skip and seek controls. Adjust supported player and Mac output volume, including with the phone’s volume buttons. Use the full player or Android notification/lock-screen controls when background ownership permits; optionally show playback in the Mac companion. Artwork uses LAN; audio keeps playing on the Mac.
- **[Do Not Disturb sync](docs/features/DND_SYNC.md):** Relay phone DND changes to configured Mac Shortcuts.
- **[Find Device](docs/features/FIND_DEVICE.md):** Ring a connected phone or notify a connected Mac through an existing trusted connection.

## Technical foundation & security

- **Native platform stacks:** Swift 6, SwiftUI & AppKit on macOS; modern Kotlin, Jetpack Compose & Material 3 on Android.
- **Direct peer-to-peer transport:** Bluetooth Low Energy (BLE) and framed local-network TCP streams. Zero cloud relays or external routing; update checks contact GitHub Releases directly, and Mac-to-Android control uses system Bluetooth HID.
- **Cryptographic security:** Mutual P-256 ECDSA authentication, OPAQUE PIN pairing, an EDHOC handshake with ChaCha20-Poly1305, and directional AES-256-GCM record encryption.
- **Platform key storage:** Cryptographic identities use Android Keystore and the macOS Login Keychain; current Mac builds do not claim Secure Enclave isolation.
- **Zero telemetry:** No analytics, no tracking, and no telemetry uploads.

For full wire specifications, threat models, and architectural boundaries, see [Architecture](ARCHITECTURE.md), [Security Policy](SECURITY.md), and [Protocol Contracts](protocol/README.md).

## Install and connect

- **Mac:** Apple Silicon, macOS 14 Sonoma or newer.
- **Android:** Android 10 (API 29) or newer; background continuity features require Android 12 (API 31) or newer.

### Installation
* **Mac (Homebrew):**
  ```bash
  brew install anisharyal09/tap/anice
  ```
* **Direct Downloads:** Available on [GitHub Releases](https://github.com/anisharyal09/aniCe/releases).
* **Setup Guides:**
  - Follow the [First Installation & Permissions Guide](docs/FIRST_INSTALL_GUIDE.md) for step-by-step help with Google Play Protect, Unknown Apps, Android 13+ restricted settings, battery optimization, and macOS Keychain / Gatekeeper.
  - Follow [Getting Started](docs/GETTING_STARTED.md) for device pairing, everyday controls, and update configuration.

## Build and contribute

Install the prerequisites in [Mac setup](apps/macos/README.md), [Android setup](apps/android/README.md) and [Rust setup](core/rust/pairing/README.md), then build from the repository root:

```sh
./scripts/dev.sh mac
./scripts/dev.sh android
./scripts/dev.sh android --serial DEVICE_SERIAL
```

See [contributing](CONTRIBUTING.md) for development checks and contribution guidance.

## Documentation and repository structure

For the complete directory of guides, feature walkthroughs, and architecture specs, see **[Documentation Directory (DOCS.md)](DOCS.md)**.

```text
apps/android/       Native Android app and tests
apps/macos/         Native Mac app, Xcode project and tests
core/rust/pairing/  Shared OPAQUE pairing bridge
protocol/           Wire contracts, schemas and test vectors
scripts/            Build, release and verification tools
docs/               Feature guides, design, decisions and architecture
```

- [Architecture](ARCHITECTURE.md) · [Decisions](docs/decisions/README.md) · [Protocol contracts](protocol/README.md)
- [Design](docs/design/DESIGN.md) · [Performance](docs/PERFORMANCE.md)
- [Background Bluetooth](docs/BACKGROUND_CONNECTIONS.md) · [LAN ownership](docs/LAN_CONNECTIONS.md)
- [Changelog](CHANGELOG.md) · [Android changes](apps/android/CHANGELOG.md) · [Mac changes](apps/macos/CHANGELOG.md) · [Protocol changes](protocol/CHANGELOG.md)
- [Third-party notices](apps/macos/aniCe/Features/NowPlaying/Adapter/THIRD_PARTY_NOTICES.md)

## Support and feedback

If you run into any issues, have feedback, or want to reach out directly:
- Open an issue on [GitHub Issues](https://github.com/anisharyal09/aniCe/issues)
- Or reach out via email: [anish.creations.hq@gmail.com](mailto:anish.creations.hq@gmail.com?subject=%5BaniCe%5D%20Feedback%20%26%20Support)

Licensed under [GPL-3.0-or-later](LICENSE).
