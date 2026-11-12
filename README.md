<h2 align="center">
  <img src="assets/logo/anice-mark-final.svg" width="168" alt="aniCe silver interlocking ribbon mark"><br>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo/anice-wordmark-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/logo/anice-wordmark-light.svg">
    <img src="assets/logo/anice-wordmark.svg" height="27" alt="aniCe">
  </picture>
</h2>

<p align="center">
  <strong>Continuity between Android and macOS, like never before.</strong><br>
  A native, local-first continuity bridge. Connects your phone and Mac directly over Bluetooth Low Energy and local-network TCP with authenticated, end-to-end encrypted sessions — no cloud accounts, no external relays, and zero telemetry.
</p>

---

## Security & Technical Foundation

aniCe is built from scratch with zero-trust, privacy-first principles:

* **Built From Scratch:** Not based on KDE Connect, LocalSend, or legacy continuity stacks. Modern, standalone native architecture implemented exclusively in Swift 6, AppKit, and SwiftUI on macOS, and Kotlin, Jetpack Compose, and Material 3 on Android.
* **Zero-Trust Security:** Local Wi-Fi networks and Bluetooth airwaves are treated as untrusted. All traffic is mutually authenticated and encrypted with forward-secret session keys; network sniffers and routers see only ciphertext.
* **Zero Cloud & Zero Telemetry:** Purely peer-to-peer over local Wi-Fi (LAN TCP/TLS) and Bluetooth Low Energy (BLE). Data never touches an external server.
* **Mutual Cryptographic Identity:** Persistent P-256 identity key pairs per device. Discovery uses fingerprint-derived service data.
* **Secure Mutual Pairing:** Visual QR code bootstrap or zero-knowledge OPAQUE PIN exchange.
* **End-to-End Encryption:** RFC 9528 EDHOC key exchange deriving ephemeral session keys; all messages protected by AES-256-GCM authenticated encryption.
* **Strict Local Boundary:** Files, clipboard data, notifications, SMS messages, and telemetry remain strictly on your local hardware.

For low-level protocol schemas and transport state machines, see [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Features

#### Seamless File Transfer (Zero-Window AirDrop Alternative)
- **Mac Edge Drop:** Drag files directly from Finder to your screen edge (left, right, or top) to send instantly.
- **Menu Bar File Picker:** Select and send files from the macOS status bar without bringing any app forward.
- **Android Direct Share:** Share photos, videos, or documents directly from the Android system share sheet with background transfer completion.
- **Zero-Window Auto-Receive:** Inbound files save silently to your custom directory (`~/Downloads/aniCe` default) without prompt fatigue.

#### Remote Control & Workspace Input
- **Control Mac (Phone as Remote):** Use your phone screen as a wireless trackpad and keyboard to navigate, click, and type on your Mac.
- **Control Android (Mac Keyboard & Trackpad):** Control your phone with your Mac's physical keyboard and trackpad via Bluetooth HID, with a draggable floating controller for Android Home, Back, and Recents (global shortcut `⌥⌘K`).
- **macOS Menu Bar Companion:** Quick-access status bar companion for device connectivity, pinned actions, and the Quick Paste Tray (`⌥⌘V`).

#### Desk Deck (Mac Control & Telemetry from Phone)
- **Remote Mac Controls:** Lock Mac, mute/unmute audio, adjust volume, and switch Mac audio output devices right from your phone.
- **One-Tap App Launcher:** Launch approved macOS applications directly from your phone screen.
- **Live Mac Telemetry:** Real-time monitoring of Mac CPU load, memory utilization, thermal pressure, and battery percentage.
- **Remote Screenshots:** Trigger and capture macOS screenshots directly from your device deck.

#### Communication, Alerts & Media
- **Notification Mirroring:** Real-time phone notifications on Mac with synchronized cross-device dismissal.
- **Call Handling:** View caller ID and answer, decline, or silence incoming SIM phone calls directly from Mac notification banners.
- **Messages (SMS Relay):** Browse full SMS threads with multi-SIM origin chips and send inline replies from macOS notifications.
- **Now Playing:** Synchronized media playback controls and album artwork between phone and Mac.
- **Do Not Disturb Sync:** Sync phone DND state with macOS Focus modes via native Shortcuts.
- **Find Device:** Remotely ring a misplaced phone or ping your Mac with one tap.

#### Clipboard Sync & Direct Link Forwarding
- **Encrypted Clipboard Sync:** Real-time, bidirectional clipboard sharing with sensitive text detection (passwords and tokens stay local unless confirmed).
- **Direct Browser Forwarding:** Share links from Android to open immediately in your Mac's default browser without cluttering your clipboard history.
- **Quick Paste Tray:** Instant clipboard history access with global shortcut (`⌥⌘V`).

---

## Repository Structure

```text
ARCHITECTURE.md         Shared identity, trust, sessions and transport ownership
apps/
  android/              Android app and tests (Kotlin, Jetpack Compose, Material 3)
  macos/                Mac app, Xcode project, and tests (Swift 6, SwiftUI, AppKit)
protocol/
  bluetooth/            BLE discovery and independent Classic Bluetooth HID contracts
  lan/                  Local network stream framing and mDNS discovery contract
  pairing/              Authenticated bootstrap and control-pipe contract (QR & OPAQUE PIN)
  session/              EDHOC, encrypted records, controls and session envelopes
  media/                Now Playing DATA contract and bounded artwork
  desk-deck/            Mac telemetry, approved apps and remote controls
  device-power/         Peer battery and charging status
  dnd-sync/             Phone-to-Mac Do Not Disturb changes
  notifications/        Android alerts, call controls and LAN source-icon contract
  transfer/             Local file transfer protocol and CDDL schema
  schemas/              Shared public identity contract (JSON Schema v1)
  test-vectors/         Cryptographic verification cases (identity, pairing, session, LAN, media, transfer)
  fixtures/             Sample public identities
scripts/                Identity/session/LAN interchange and native pairing builds
docs/
  design/               Shared design guide
  decisions/            App-wide ADRs and features/<feature>/ decisions
  features/             Feature usage and limitations
  BACKGROUND_CONNECTIONS.md Background BLE lifecycle and gates
  LAN_CONNECTIONS.md    Independent authenticated LAN connections
  PERFORMANCE.md        Authenticated record performance budget and cost model
  ROADMAP.md            Implemented capabilities and planned work
.agents/                Operational coding context
core/rust/              Pinned ephemeral OPAQUE bridge (JNI & C ABI)
```

---

## Development & Architecture Decisions

Build, install and launch a development app from the repository root:

```sh
./scripts/dev.sh mac
./scripts/dev.sh android
./scripts/dev.sh android --serial DEVICE_SERIAL
```

See the platform setup guides below for prerequisites and local Mac signing settings.

- **Architecture Overview:** [Identity, trust, sessions and transports](ARCHITECTURE.md)
- **Architecture Decisions:** [Shared foundations and feature decisions](docs/decisions/README.md)
- **Setup & Building:** [Android app setup](apps/android/README.md) · [macOS app setup](apps/macos/README.md) · [Native Rust toolchain](core/rust/pairing/README.md)
- **Protocol & Design:** [Shared Contracts](protocol/README.md) · [Design Guide](docs/design/DESIGN.md) · [Roadmap](docs/ROADMAP.md)
- **Features:** [Mac Desk Deck](docs/features/MAC_DESK_DECK.md) · [Do Not Disturb sync](docs/features/DND_SYNC.md) · [Now Playing](docs/features/NOW_PLAYING.md) · [Local File Transfer](docs/features/FILE_TRANSFER.md) · [Find Device](docs/features/FIND_DEVICE.md) · [Clipboard](docs/features/CLIPBOARD.md) · [Messages (SMS relay)](docs/features/SMS.md) · [Notification mirroring](docs/features/NOTIFICATION_MIRRORING.md) · [Control Android (Keyboard & Trackpad)](docs/features/KEYBOARD_TRACKPAD.md) · [Control Mac](docs/features/PHONE_TO_MAC.md)
- **Transport Specifications:** [Background BLE Connections](docs/BACKGROUND_CONNECTIONS.md) · [Local Network Connections](docs/LAN_CONNECTIONS.md) · [LAN bulk benchmark](protocol/lan/BENCHMARK.md) · [Performance Guide](docs/PERFORMANCE.md)

Android compiles/targets API 36 with `minSdk = 29`; the Mac deployment target is macOS 14 and Swift language mode is 6. Current Mac app builds use development Keychain storage; configured signing alone does not select the protected backend.

---

## License & Changelogs

Licensed under [GPL-3.0-or-later](LICENSE).

Changelogs: [Repository](CHANGELOG.md) · [Android](apps/android/CHANGELOG.md) · [macOS](apps/macos/CHANGELOG.md) · [Protocol](protocol/CHANGELOG.md).
