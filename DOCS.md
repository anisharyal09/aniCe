<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Documentation Directory

A complete index of documentation, architectural specifications, feature guides, and technical decisions for aniCe.

---

## 🚀 Getting Started & Setup

* **[First Installation & Permissions Guide](docs/FIRST_INSTALL_GUIDE.md)** — Step-by-step walkthrough for Google Play Protect, Unknown Apps, Android 13+ restricted settings, battery optimization, and macOS Keychain / Gatekeeper.
* **[Getting Started](docs/GETTING_STARTED.md)** — App installation, device pairing (QR & 6-digit code), connection management, and in-app updates.
* **[Android Development Setup](apps/android/README.md)** — Gradle setup, build targets, preview builds, and local testing.
* **[macOS Development Setup](apps/macos/README.md)** — Xcode project structure, Swift 6 compiler requirements, and code signing.
* **[Rust Pairing Bridge](core/rust/pairing/README.md)** — OPAQUE pairing protocol shared library and cross-compilation.

---

## ✨ Feature Guides

* **[File Transfer](docs/features/FILE_TRANSFER.md)** — Peer-to-peer file sharing, Edge Drop desktop shelf, automatic receiving, and 15-minute interrupted transfer recovery.
* **[Clipboard Sync](docs/features/CLIPBOARD.md)** — Bidirectional clipboard sharing, link opening, and the macOS Quick Paste Tray (`⌥⌘V`).
* **[Phone to Mac Remote Control](docs/features/PHONE_TO_MAC.md)** — Turn your phone into an encrypted trackpad and keyboard for your Mac.
* **[Control Android from Mac](docs/features/KEYBOARD_TRACKPAD.md)** — Control Android with your Mac keyboard and trackpad over Bluetooth HID, with the Floating Key (`⌥⌘K`).
* **[Mac Desk Deck](docs/features/MAC_DESK_DECK.md)** — Monitor Mac CPU, memory, battery, and thermals; lock Mac, trigger DND, control audio output, and launch apps from Android.
* **[Notification Mirroring & Call Alerts](docs/features/NOTIFICATION_MIRRORING.md)** — Mirror notifications with inline replies, action buttons, icon caching, and incoming call alerts.
* **[SMS & Messaging](docs/features/SMS.md)** — Read and reply to SMS conversations from your Mac with dual-SIM selection.
* **[Now Playing Media Controls](docs/features/NOW_PLAYING.md)** — Remote media controls, live track artwork, player selection, and volume synchronization.
* **[Do Not Disturb (DND) Sync](docs/features/DND_SYNC.md)** — Synchronize Android DND states with macOS Shortcuts.
* **[Find Device](docs/features/FIND_DEVICE.md)** — Trigger audible rings or screen alerts between paired devices.

---

## 🏛️ Architecture & Technical Foundation

* **[Architecture Overview](ARCHITECTURE.md)** — Layered architecture, subsystem boundaries, trust model, and transport topology.
* **[Security & Trust Model](SECURITY.md)** — Cryptographic primitives, key management, security policy, and vulnerability reporting.
* **[Design & UI Principles](docs/design/DESIGN.md)** — Design language, typography, color palette, dark mode, and desktop layout guidelines.
* **[Performance Profile & Limits](docs/PERFORMANCE.md)** — Resource usage targets, frame rate budgets, transfer chunk sizes, and wire latency expectations.
* **[Background Bluetooth Connections](docs/BACKGROUND_CONNECTIONS.md)** — BLE advertising intervals, companion scan states, battery trade-offs, and reconnection state machines.
* **[LAN Connection Ownership](docs/LAN_CONNECTIONS.md)** — Wi-Fi peer discovery, TCP framing, encrypted session handoff, and automatic reconnection.
* **[Wire Protocol & Schemas](protocol/README.md)** — Framing contracts, CBOR schemas, and test vector verification.

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

## 🧪 Testing & Verification

* **[Verification Status](docs/A&V/VERIFICATION_STATUS.md)** — Current status of automated suites across platforms.
* **[Test Audit](docs/A&V/TEST_AUDIT.md)** — Breakdown of unit, integration, and platform test suites.
* **[Session Verification](docs/A&V/SESSION_VERIFICATION.md)** — End-to-end cryptographic handshake validation.
* **[Background Connection Verification](docs/A&V/BACKGROUND_CONNECTION_VERIFICATION.md)** — Reconnection and lifecycle persistence checks.
* **[Idle Connection Performance](docs/A&V/IDLE_CONNECTION_PERFORMANCE.md)** — Standby power, CPU, and memory audits.
* **[macOS Code Signing Guide](docs/testing/MAC_SIGNING.md)** — Self-signing and notarization requirements.

---

## 🗺️ Project, Releases & Community

* **[Project Roadmap](docs/ROADMAP.md)** — Planned milestones, beta release phases, and feature roadmap.
* **[Contributing Guidelines](CONTRIBUTING.md)** — Code style, pull request checklist, and pre-commit verification suites.
* **[Root Changelog](CHANGELOG.md)** — Cumulative project change history.
  * [Android Changelog](apps/android/CHANGELOG.md)
  * [macOS Changelog](apps/macos/CHANGELOG.md)
  * [Protocol Changelog](protocol/CHANGELOG.md)

