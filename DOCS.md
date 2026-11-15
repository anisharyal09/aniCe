<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Documentation Directory

A complete, categorized index of all user setup guides, feature notes, architectural specifications, wire protocol contracts, developer setups, and technical decision records for aniCe.

---

## 🚀 Getting Started & Setup

* **[First Installation & Permissions Guide](docs/FIRST_INSTALL_GUIDE.md)** — Step-by-step walkthrough for Google Play Protect ("Install anyway" / scan toggle), Unknown Apps, Android 13+ restricted settings (⋮ menu unlock), battery optimization, and macOS Keychain / Gatekeeper approval.
* **[Getting Started](docs/GETTING_STARTED.md)** — Device pairing (QR code & 6-digit PIN), everyday connection controls, and update configuration.

---

## ✨ Feature Guides

* **[File Transfer](docs/features/FILE_TRANSFER.md)** — Peer-to-peer file sharing, Edge Drop desktop shelf, automatic receiving per sender, and 15-minute interrupted transfer recovery.
* **[Clipboard Sync](docs/features/CLIPBOARD.md)** — Bidirectional clipboard sharing, link handoff to Mac browser, and the macOS Quick Paste Tray (`⌥⌘V`).
* **[Phone to Mac Remote Control](docs/features/PHONE_TO_MAC.md)** — Turn your phone into an encrypted trackpad and keyboard for your Mac.
* **[Control Android from Mac](docs/features/KEYBOARD_TRACKPAD.md)** — Control Android with your Mac keyboard and trackpad over Bluetooth HID, with the Floating Key (`⌥⌘K`).
* **[Mac Desk Deck](docs/features/MAC_DESK_DECK.md)** — Monitor Mac CPU, memory, battery, and thermals; lock Mac, trigger DND, control audio output, and launch approved apps from Android.
* **[Notification Mirroring & Call Alerts](docs/features/NOTIFICATION_MIRRORING.md)** — Mirror notifications with inline replies, action buttons, icon caching, and incoming call alerts.
* **[SMS & Messaging](docs/features/SMS.md)** — Read and reply to SMS conversations from your Mac with dual-SIM selection.
* **[Now Playing Media Controls](docs/features/NOW_PLAYING.md)** — Remote media controls, live track artwork, player selection, and volume synchronization.
* **[Do Not Disturb (DND) Sync](docs/features/DND_SYNC.md)** — Synchronize Android DND states with macOS Shortcuts.
* **[Find Device](docs/features/FIND_DEVICE.md)** — Trigger audible rings or screen alerts between paired devices.

---

## 🏛️ Architecture & System Design

* **[Architecture Overview](ARCHITECTURE.md)** — Layered architecture, subsystem boundaries, trust model, and transport topology.
* **[Security Policy & Trust Model](SECURITY.md)** — Cryptographic primitives, key management (Android Keystore / Mac Keychain), and vulnerability reporting.
* **[Performance Profile & Limits](docs/PERFORMANCE.md)** — Hot-path allocation discipline, throughput gates, and wire resource budgets.
* **[Background Bluetooth Connections](docs/BACKGROUND_CONNECTIONS.md)** — BLE advertising intervals, companion scan states, battery trade-offs, and reconnection state machines.
* **[LAN Connection Ownership](docs/LAN_CONNECTIONS.md)** — Wi-Fi peer discovery, TCP framing, encrypted session handoff, and automatic reconnection.
* **[Design & UI Principles](docs/design/DESIGN.md)** — Design language, typography, semantic color palette, dark mode, and desktop layout guidelines.

---

## 📡 Protocol Specifications & Wire Contracts

* **[Protocol Specification Overview](protocol/README.md)** — Master framing contracts, CBOR schemas, and test vector verification.
* **[Pairing Protocol](protocol/pairing/README.md)** — QR bootstrap (P-256 ECDH) and PIN exchange (OPAQUE over Ristretto255).
* **[Session Handshake & Records](protocol/session/README.md)** — RFC 9528 EDHOC method 0, cipher suite 5, and directional AES-256-GCM records.
* **[Bluetooth Transport & Framing](protocol/bluetooth/README.md)** — Stable GATT attribute layout, fragmentation v2, and MTU negotiation.
* **[Local Network (LAN) Transport](protocol/lan/README.md)** — Framed TCP streaming, bulk probe discovery, and 512 KiB transfer profile.
* **[File Transfer Protocol](protocol/transfer/README.md)** — Sequential batch chunking, SHA-256 prefix commitments, and 15-minute resumption.

---

## 🛠️ Development & Testing

* **[Contributing & Verification Suite](CONTRIBUTING.md)** — Pre-commit verification (`verify-suite.py`), multi-lane test matrix, coding standards, and pull request workflow.
* **[Android App Development](apps/android/README.md)** — Gradle configuration, JVM test execution (`cleanTestDebugUnitTest`), Compose previews, and build variants.
* **[macOS App Development](apps/macos/README.md)** — Xcode workspace configuration, Swift 6 compiler settings, hosted test suites, and code signing.
* **[Rust Pairing Engine](core/rust/pairing/README.md)** — OPAQUE pairing core library, Cargo unit tests, and cross-platform compilation targets.

---

## 📋 Architectural Decision Records (ADRs)

* **[Architecture Decisions Index](docs/decisions/README.md)**
  * [0001: Provisional Device Identity](docs/decisions/0001-provisional-device-identity.md)
  * [0002: Provisional BLE Discovery](docs/decisions/0002-provisional-ble-discovery.md)
  * [0003: Provisional Pairing and Trust](docs/decisions/0003-provisional-pairing-and-trust.md)
  * [0004: Stable BLE Attribute Layout](docs/decisions/0004-stable-ble-attribute-layout.md)
  * [0005: EDHOC Secure Sessions](docs/decisions/0005-edhoc-secure-sessions.md)
  * [0006: Independent LAN Sessions](docs/decisions/0006-independent-lan-sessions.md)
  * [0007: macOS Unsandboxed Playback Prototype](docs/decisions/0007-macos-unsandboxed-playback-prototype.md)
  * [0008: Application Data Feature Boundaries](docs/decisions/0008-application-data-feature-boundaries.md)
  * [0009: Remote Playback Presentation](docs/decisions/features/now-playing/0009-remote-playback-presentation.md)
  * [0010: macOS Transfer Notifications](docs/decisions/features/file-transfer/0010-macos-transfer-notifications.md)
  * [0011: macOS Classic HID Input](docs/decisions/features/keyboard-trackpad/0011-macos-classic-hid-input.md)

---

## 🗺️ Project & Releases

* **[Project Roadmap](docs/ROADMAP.md)** — Milestone sequence, beta release phases, and upcoming capabilities.
* **[Root Changelog](CHANGELOG.md)** — Cumulative project change history across Android, macOS, and protocol releases.
  * [Android Changelog](apps/android/CHANGELOG.md)
  * [macOS Changelog](apps/macos/CHANGELOG.md)
  * [Protocol Changelog](protocol/CHANGELOG.md)
