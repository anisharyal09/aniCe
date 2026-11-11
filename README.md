<h2 align="center">
  <img src="assets/logo/anice-mark-final.svg" width="168" alt="aniCe silver interlocking ribbon mark"><br>
  ani<span style="color: #D26458;">Ce</span>
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

### Seamless Zero-Window File Transfer
Send files instantly without the friction of opening app windows, scanning codes, or waiting on foreground screens:
* **Mac (Zero-Window):**
  * **Edge Drop:** Drag any file from Finder directly to your screen edge (right, left, or top) onto the popout shelf.
  * **Menu Bar Companion:** Quick-send and drag target directly from the menu bar status icon.
  * **Overview Drop:** Drop files anywhere onto the main app window.
* **Android (Direct Share Sheet):**
  * Tap **Share → aniCe** from Gallery, Files, or any app.
  * Send with one tap, or hit **Continue in background** to keep using your phone while files transfer via a background service.
* **Custom Destination Folders & Silent Auto-Receive:**
  * Choose custom save destinations on both devices (`~/Downloads/aniCe` by default on Mac, or custom folder on Android).
  * Automatic receiving: Incoming files land silently in your Downloads folder without prompt fatigue.

### Control Android (Keyboard & Trackpad)
Control your Android phone with your Mac's physical keyboard and trackpad over Classic Bluetooth HID:
* Fluid two-finger scrolling, left/right pointer dragging, and native modifier mapping.
* Persistent **Floating Key** button with full-header dragging, collapse, and hide controls.
* Quick shortcuts for Android **Back**, **Home**, **Recents**, and clipboard text typing.

### Control Mac (Phone as Remote Control)
Use your phone as a remote control cursor and keyboard directly:
* Navigate the Mac pointer, perform left/right clicks, and type text on your Mac directly from your phone screen over an authenticated Bluetooth session.

### Clipboard Sync & Direct Link Forwarding
Instant, encrypted clipboard sharing between devices:
* **Direct Browser Forwarding:** Share or send links from Android to open immediately in your Mac's default browser *without cluttering your clipboard history*.
* Automatic or manual clipboard sync with sensitive text protection (passwords/tokens stay local unless explicitly confirmed).
* Optional local history and Quick Paste Tray on macOS.

### Mac Desk Deck (Remote Control & Telemetry)
Monitor and control your Mac from your Android phone:
* **Launch Mac Apps:** Open any approved Mac application directly from your phone with one tap.
* **Audio & Power Controls:** Remote Mac volume slider, input mute toggle, and switch active Mac audio output devices (e.g. Speakers vs Headphones).
* **System Telemetry:** Real-time Mac CPU load, memory utilization, thermal pressure, and battery status.
* **Quick Actions:** Remote screen lock and screenshot triggers.

### Notification Sync & Call Controls
Real-time notification mirroring from Android to macOS:
* Filter which Android apps mirror to Mac; synced dismissal clears alerts on both devices.
* Live incoming call relay with caller ID, Answer, Decline, and Silence buttons directly from macOS notifications.

### Messages (SMS Relay)
Read and reply to phone text messages directly on Mac:
* Full conversation browsing, search, and message history cache.
* Multi-SIM origin chips, phone carrier status, and inline reply directly from macOS notifications.

### Now Playing
Live media playback controls and album artwork synchronized between Android and Mac:
* Play, pause, skip, and scrub media playing on either device.
* Overview and menu bar companion widget support.

### Do Not Disturb Sync
One-way sync from phone DND to macOS Focus modes via native macOS Shortcuts.

### Find Device
Ping and locate a misplaced phone by ringing (alarm) from Mac or alert your Mac from your phone with one tap.

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
