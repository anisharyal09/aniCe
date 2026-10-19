# aniCe

A native, local-first continuity bridge, starting with Android and macOS. Connects your phone and Mac directly over Bluetooth Low Energy and local-network TCP, using authenticated, encrypted sessions — no cloud accounts, external relays or telemetry.

The goal is to bring the continuity of native single-vendor ecosystems (like Apple or Samsung) to Android and Mac setups, with room for other platforms. Built on standard cryptographic primitives, documented protocols and local transports.

The pairing and transport foundations include P-256 identities, QR and OPAQUE PIN pairing, RFC 9528 EDHOC key exchange, and AES-256-GCM encrypted records. Authenticated connections, native feature workflows and UI have been exercised on physical Mac and Android hardware. See [ARCHITECTURE.md](ARCHITECTURE.md) for technical design and protocol details.

## Current development milestone

**0.2.0-dev · build 2**, following 0.1.0. Now Playing, bidirectional Local File Transfer, Find Device, text Clipboard with optional local history and Android sharing actions, and SMS relay from Android to Mac with Mac notifications and replies are implemented, alongside the native Home/Devices/Features/Favourites/Settings/About redesign.

Physical testing includes authenticated connections, real transfers in both directions, Find Device ringing/Stop/timeout, and manual feature/UI use on an Apple M5 MacBook Air and Samsung Galaxy A34.

---

Automatic LAN connection is available through an opt-in preference in Settings and pairing on both apps. It coordinates over secured Bluetooth; [LAN behavior and limits](docs/LAN_CONNECTIONS.md#automatic-connection-on-events-and-demand) describe eligibility and event-triggered initiation.

## Repository Structure

```text
ARCHITECTURE.md         Shared identity, trust, sessions and transport ownership
apps/
  android/              Android app and tests (Kotlin, Jetpack Compose, Material 3)
  macos/                Mac app, Xcode project, and tests (Swift 6, SwiftUI, AppKit)
protocol/
  bluetooth/            BLE discovery contract (unauthenticated 20-byte probe)
  lan/                  Local network stream framing and mDNS discovery contract
  pairing/              Authenticated bootstrap and control-pipe contract (QR & OPAQUE PIN)
  session/              EDHOC, encrypted records, controls and session envelopes
  media/                Now Playing DATA contract and bounded artwork
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

- **Architecture Overview:** [Identity, trust, sessions and transports](ARCHITECTURE.md)
- **Architecture Decisions:** [Shared foundations and feature decisions](docs/decisions/README.md)
- **Setup & Building:** [Android app setup](apps/android/README.md) · [macOS app setup](apps/macos/README.md) · [Native Rust toolchain](core/rust/pairing/README.md)
- **Protocol & Design:** [Shared Contracts](protocol/README.md) · [Design Guide](docs/design/DESIGN.md) · [Roadmap](docs/ROADMAP.md)
- **Features:** [Now Playing](docs/features/NOW_PLAYING.md) · [Local File Transfer](docs/features/FILE_TRANSFER.md) · [Find Device](docs/features/FIND_DEVICE.md) · [Clipboard](docs/features/CLIPBOARD.md) · [Messages (SMS relay)](docs/features/SMS.md)
- **Transport Specifications:** [Background BLE Connections](docs/BACKGROUND_CONNECTIONS.md) · [Local Network Connections](docs/LAN_CONNECTIONS.md) · [LAN bulk benchmark](protocol/lan/BENCHMARK.md) · [Performance Guide](docs/PERFORMANCE.md)

Android compiles/targets API 36 with `minSdk = 29`; the Mac deployment target is macOS 14 and Swift language mode is 6. Current Mac app builds use development Keychain storage; configured signing alone does not select the protected backend.

---

## License & Changelogs

Licensed under [GPL-3.0-or-later](LICENSE).

Changelogs: [Repository](CHANGELOG.md) · [Android](apps/android/CHANGELOG.md) · [macOS](apps/macos/CHANGELOG.md) · [Protocol](protocol/CHANGELOG.md).
