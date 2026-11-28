<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Documentation

## Setup and use

- [Installation and permissions](docs/FIRST_INSTALL_GUIDE.md)
- [Pairing, connections and updates](docs/GETTING_STARTED.md)
- [Bluetooth background connections](docs/BACKGROUND_CONNECTIONS.md)
- [Local-network connections](docs/LAN_CONNECTIONS.md)

## Features

- [File transfer](docs/features/FILE_TRANSFER.md) — Batches, Edge Drop, destinations and interrupted-transfer recovery.
- [Clipboard](docs/features/CLIPBOARD.md) — Manual/automatic sharing, local history and Quick Paste Tray.
- [Phone to Mac](docs/features/PHONE_TO_MAC.md) — Phone keyboard and trackpad input.
- [Mac to Android](docs/features/KEYBOARD_TRACKPAD.md) — Bluetooth HID input and Floating Key.
- [Mac Desk Deck](docs/features/MAC_DESK_DECK.md) — System readings, output controls and approved app shortcuts.
- [Notifications and call alerts](docs/features/NOTIFICATION_MIRRORING.md)
- [Messages](docs/features/SMS.md) — SMS relay, history, replies and SIM selection.
- [Now Playing](docs/features/NOW_PLAYING.md) — Playback, artwork and player/output volume.
- [Private Listening and Phone Audio](docs/features/PRIVATE_LISTENING.md) — Bidirectional Mac/phone audio over LAN, routing privacy and OS boundaries.
- [Do Not Disturb](docs/features/DND_SYNC.md) — Android-to-Mac sync through selected Shortcuts.
- [Find Device](docs/features/FIND_DEVICE.md) — Native peer alerts and Android ringing.

## Architecture and contracts

- [Architecture](ARCHITECTURE.md) — Subsystem boundaries and native ownership.
- [Security](SECURITY.md) — Identity, trust, storage and reporting.
- [Design](docs/design/DESIGN.md) — Native interaction, layout and semantic tokens.
- [Performance](docs/PERFORMANCE.md) — Resource budgets, record costs and instrumentation.
- [Protocol index](protocol/README.md) — Wire contracts, schemas and shared fixtures.
- [LAN rendezvous](protocol/lan/AUTOMATIC.md) — Authenticated BLE endpoint hints and bounded discovery.
- [LAN renewal](protocol/lan/RENEWAL.md) — Drain barriers and fresh sessions on the retained socket.
- [Architecture decisions](docs/decisions/README.md) — Decision rationale and superseded behavior.

## Development

- [Contributing](CONTRIBUTING.md)
- [Android](apps/android/README.md) — Gradle, preview packages and native builds.
- [macOS](apps/macos/README.md) — Xcode, preview bundles and signing.
- [Rust pairing bridge](core/rust/pairing/README.md) — PAKE interface and toolchain setup.

## Change history

- [Project](CHANGELOG.md)
- [Android](apps/android/CHANGELOG.md)
- [macOS](apps/macos/CHANGELOG.md)
- [Protocol](protocol/CHANGELOG.md)
