# aniCe Roadmap

| Milestone | Scope | Status |
| :--- | :--- | :--- |
| **Native app foundations & identity** | Native shells, lifecycle, navigation, protected local P-256 keys | Implemented |
| **Pairing & mutual trust** | Ephemeral QR & OPAQUE PIN authentication, mutual approval, atomic trust journal | Implemented |
| **Independent Bluetooth Low Energy (BLE)** | Compatibility discovery, EDHOC session handshake, AES-GCM records, GATT framing | Implemented |
| **Independent Local Network (LAN)** | Anonymous DNS-SD discovery, bounded TCP framing, shared peer reservation | Implemented |
| **Connected-idle performance optimization** | Event-driven monotonic deadline scheduling, zero idle storage reads, ~90% CPU reduction* | Implemented |
| **Local File Transfer** | Basic approved batch streaming and UI; storage/lifecycle repairs implemented | Implemented; bidirectional app transfers verified; durable recovery/renewal pending |
| **Application continuity** | Now Playing, File Transfer and Find Device implemented; native UI overhaul in 0.2.0-dev. | In progress |

Manual feature/UI tests, physical transfer measurements, native ringing/lifecycle checks and automated protocol/interchange suites provide complementary coverage. Current milestone: 0.2.0-dev, build 2.

---

## Technical Milestones

### 1. Identity & Cryptographic Bootstrap
- **Platform Identity:** Actor-isolated P-256 keys in `AndroidKeyStore` and macOS Keychain with ASN.1 DER boundary signatures and JSON Schema v1 public records. Ordinary reads avoid signing; creation and reset retain cryptographic signing proof. See [ADR 0001](decisions/0001-provisional-device-identity.md).
- **Pairing Bootstrap:** Ephemeral P-256 ECDH QR code pairing with SHA-256 fingerprint commitments. 6-digit manual PIN pairing using an isolated in-memory OPAQUE bridge (`opaque-ke 4.0.1`, Argon2id). See [Pairing Contract](../protocol/pairing/README.md) and [ADR 0003](decisions/0003-provisional-pairing-and-trust.md).
- **Mutual Trust:** Explicit on-screen approval on both devices before trust activation, persisted atomically in local trust journals. Trusted peer management includes selectable credentials and confirmed forgetting; local device names can be edited without replacing identity.

### 2. Independent Bluetooth Low Energy (BLE) Sessions
- **Handshake & Record Channel:** RFC 9528 EDHOC (method 0, cipher suite 5: P-256, SHA-256, ChaCha20-Poly1305) with mandatory message 4 authenticating pinned active trust. Directional AES-256-GCM application records with 64-bit sequence counters, 4,000-byte plaintext limit, one-hour lifetime, and hard cap of `2^20` records. Strict bidirectional `ready` / `readyAck` confirmation before payload delivery. See [Session Contract](../protocol/session/README.md) and [ADR 0005](decisions/0005-edhoc-secure-sessions.md).
- **Native BLE Transport:** Unauthenticated 20-byte compatibility discovery probe and bounded GATT v2 session framing with 10-second reassembly deadlines. Android companion ownership provides background lifecycle on supported API 31+ platforms; Mac provides shared allowed-device selection with credential pinning. See [Background BLE](BACKGROUND_CONNECTIONS.md) and [ADR 0004](decisions/0004-stable-ble-attribute-layout.md).
- **Liveness & Renewal:** Encrypted HELLO/ACK negotiation, Android-initiated PING/PONG after 60 seconds of inactivity, and fresh EDHOC session renewal at 55 minutes or the `2^20 - 1024` record threshold.

### 3. Independent Local Network (LAN) Transport
- **Discovery & Framing:** Anonymous Bonjour/NSD discovery (`_anice._tcp`) and 5-byte TCP stream framing with bounded session envelopes (2–4,096 bytes). Native Wi-Fi socket binding, serialized legacy NSD resolution, and scoped IPv6 addressing. See [LAN Connections](LAN_CONNECTIONS.md), [LAN Contract](../protocol/lan/README.md), and [ADR 0006](decisions/0006-independent-lan-sessions.md).
- **Automatic LAN:** Opt-in Settings/pairing controls on both platforms coordinate bounded Mac admission over secured BLE, Android foreground discovery on connection events, ordinary BLE feature activity or feature demand, without a separate LAN retry loop. Physical lifecycle acceptance remains pending. See [rendezvous](../protocol/lan/AUTOMATIC.md).
- **Concurrent Coexistence:** Independent fresh sessions and key material over BLE and LAN to the same pinned peer, coordinated under a shared peer reservation lock.

### 4. Connected-Idle Performance Optimization
- **Stage 1 (Initial 200 ms Polling):** Originally, maintenance ran a fixed 200 ms polling loop. Every 200 ms, Android signed an ECDSA self-check challenge against `AndroidKeyStore` and re-read `identity-v1.json` and `trusted_peers.json` from flash storage. This produced severe CPU overhead (~16% CPU in early locked-screen Doze tests) and thread spinning on both platforms.
- **Stage 2 (1-Second Polling & Read Signing Removal):** Removed redundant private-key signing on ordinary identity reads (reserving signatures only for creation, reset, and requested authentication). Slowed secured-session maintenance loops from 200 ms to 1 second (keeping 200 ms only for initial handshake/readiness). This established the initial workload baseline: median CPU of ~3.166% on Android and ~0.385% on macOS.
- **Stage 3 (Event-Driven Architecture):** Completely eliminated periodic polling (`delay(1000)` / `Timer(1.0)`). Replaced with cancellable waits for the earliest absolute monotonic deadline (`min(admission, handshake, readiness, liveness PING/PONG, idle, lifetime, renewal, reassembly)`). Quiet deadline waits perform zero KeyStore, Keychain, or disk reads. Full native identity, hardware protection, and in-memory trust validation are preserved on all authenticated operations. Explicit identity reset or peer revocation immediately retires both BLE and LAN transport owners through service invalidation callbacks.
- **Measured Result:** Validated in 17-minute physical connected-idle tests, dropping single-core CPU medians from 3.166% down to 0.322% on Android and 0.385% down to 0.030% on macOS (~90% reduction).

### 5. Application Continuity
- **Now Playing:** Remote Mac playback, source selection, seek previews, native Android notifications (`MediaSession` / `Notification.MediaStyle`), and player/output volume controls are implemented. Mac Home/companion display is optional. See [Now Playing](features/NOW_PLAYING.md), [ADR 0007](decisions/0007-macos-unsandboxed-playback-prototype.md), and [ADR 0009](decisions/features/now-playing/0009-remote-playback-presentation.md).

- **Local File Transfer:** Bidirectional sequential batch streaming (1..128 files) over authenticated LAN DATA records with cumulative credit flow control (64-chunk window / 3,072-byte chunks), recipient offer approval, exclusive partial staging with checked SHA-256 verification and finalization, on-demand connection, and presentation across Features and Home live-activity. See [Local File Transfer](features/FILE_TRANSFER.md) and [Transfer Contract](../protocol/transfer/README.md).

- **Find Device:** Native peer alerts, Android alarm playback with Stop and sixty-second expiry, Mac notifications and explicit notification setup. Samsung native ringing/Stop/timeout checks pass. See [Find Device](features/FIND_DEVICE.md).

- **Native UI:** Dedicated feature panels, Favourites and About, compact phone Home, direct transport controls in Devices, accessible disclosure labels and responsive Mac activity panels.

- **Continuous Hardening & Resilience:** Iterative end-to-end testing, protocol interchange fuzzing, reconnection recovery edge cases, and ongoing device interoperability fixes.
