<h2 align="center">
  <img src="assets/logo/anice-mark-final.svg" width="168" alt="aniCe silver interlocking ribbon mark"><br>
  aniCe
</h2>

A native, local-first continuity bridge, starting with Android and macOS. Connects your phone and Mac directly over Bluetooth Low Energy and local-network TCP, using authenticated, encrypted sessions — no cloud accounts, external relays or telemetry.

The pairing and transport foundations include P-256 identities, QR and OPAQUE PIN pairing, RFC 9528 EDHOC key exchange, and AES-256-GCM encrypted records. See [ARCHITECTURE.md](ARCHITECTURE.md) for technical design and protocol details.

## Current release

**v0.3.0 · build 3**, following v0.2.0. Now Playing, bidirectional Local File Transfer, Find Device, text Clipboard with optional local history and Android sharing actions, and SMS relay from Android to Mac with Mac notifications and replies are implemented.

Physical testing includes authenticated connections, real transfers in both directions, Find Device ringing/Stop/timeout, and manual feature/UI use on an Apple M5 MacBook Air and Samsung Galaxy A34.

## In development (unreleased)

- **[Mac Desk Deck](docs/features/MAC_DESK_DECK.md):** View Mac CPU, memory, thermal pressure and battery status from Android. Control output volume and audio devices, lock the Mac, open Screenshot controls, and launch apps approved for that phone. Open **Features → Mac Desk Deck** on Android.
- **[Do Not Disturb sync](docs/features/DND_SYNC.md):** Send phone DND changes to Mac through locally configured Shortcuts. Desk Deck also offers a separate Mac-local DND button.
- **[Seamless file sharing](docs/features/FILE_TRANSFER.md):** Send files between Mac and Android using Mac drop targets, the optional Edge Drop shelf, or Android’s Share sheet. Choose receive folders and per-sender automatic receiving.
- **[Control Android (Keyboard & Trackpad)](docs/features/KEYBOARD_TRACKPAD.md):** Use the Mac’s keyboard and trackpad to type, move the pointer, scroll, and navigate on a trusted Android phone over separately paired Classic Bluetooth HID. In the Mac app, open **Features → Control Android**.
- **[Control Mac](docs/features/PHONE_TO_MAC.md):** Use Android’s keyboard and trackpad to control the Mac over aniCe’s authenticated Bluetooth session. macOS Event Posting access is configured in **Settings → Permissions**.
- **[Notification mirroring](docs/features/NOTIFICATION_MIRRORING.md):** Select Android apps and mirror their active alerts to Mac, including source icons and supported actions. Includes live SIM call relay with optional caller identification and Answer/Decline from Mac while audio stays on the phone. Calling-app controls use the actions Android exposes.

---

Automatic LAN connection is available through an opt-in preference in Settings and pairing on both apps. It coordinates over secured Bluetooth; [LAN behavior and limits](docs/LAN_CONNECTIONS.md#automatic-connection-on-events-and-demand) describe eligibility and event-triggered initiation.

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
  device-power/         Shared phone battery status
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
- **Features:** [Mac Desk Deck (unreleased)](docs/features/MAC_DESK_DECK.md) · [Do Not Disturb sync (unreleased)](docs/features/DND_SYNC.md) · [Now Playing](docs/features/NOW_PLAYING.md) · [Local File Transfer](docs/features/FILE_TRANSFER.md) · [Find Device](docs/features/FIND_DEVICE.md) · [Clipboard](docs/features/CLIPBOARD.md) · [Messages (SMS relay)](docs/features/SMS.md) · [Notification mirroring (unreleased)](docs/features/NOTIFICATION_MIRRORING.md) · [Mac keyboard & trackpad for Android (unreleased)](docs/features/KEYBOARD_TRACKPAD.md) · [Control Mac (unreleased)](docs/features/PHONE_TO_MAC.md)
- **Transport Specifications:** [Background BLE Connections](docs/BACKGROUND_CONNECTIONS.md) · [Local Network Connections](docs/LAN_CONNECTIONS.md) · [LAN bulk benchmark](protocol/lan/BENCHMARK.md) · [Performance Guide](docs/PERFORMANCE.md)

Android compiles/targets API 36 with `minSdk = 29`; the Mac deployment target is macOS 14 and Swift language mode is 6. Current Mac app builds use development Keychain storage; configured signing alone does not select the protected backend.

---

## License & Changelogs

Licensed under [GPL-3.0-or-later](LICENSE).

Changelogs: [Repository](CHANGELOG.md) · [Android](apps/android/CHANGELOG.md) · [macOS](apps/macos/CHANGELOG.md) · [Protocol](protocol/CHANGELOG.md).
