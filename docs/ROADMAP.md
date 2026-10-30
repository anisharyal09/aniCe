# aniCe Roadmap

| Milestone | Scope | Status |
| :--- | :--- | :--- |
| **Native app foundations & identity** | Native shells, lifecycle, navigation, protected local P-256 keys | Implemented |
| **Pairing & mutual trust** | Ephemeral QR & OPAQUE PIN authentication, mutual approval, atomic trust journal | Implemented |
| **Independent Bluetooth Low Energy (BLE)** | Compatibility discovery, EDHOC session handshake, AES-GCM records, GATT framing | Implemented |
| **Independent Local Network (LAN)** | Anonymous DNS-SD discovery, bounded TCP framing, shared peer reservation | Implemented |
| **Connected-idle performance optimization** | Event-driven monotonic deadline scheduling, zero idle storage reads | Implemented |
| **Local File Transfer** | Approved batch streaming, bounded checkpoints and restart recovery | Implemented; coordinated LAN renewal deferred |
| **Application continuity** | Now Playing, File Transfer, Find Device, text Clipboard and Android→Mac SMS relay implemented. | In progress |

Physical feature/UI exercises, transfer measurements, ringing/lifecycle checks and automated protocol/interchange suites provide complementary coverage. Current release: v0.3.0, build 3. New work is tracked under Unreleased.

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
- **Discovery & Framing:** Anonymous Bonjour/NSD discovery (`_anice._tcp`) and 5-byte TCP framing with standard 4,096-byte envelopes and separately negotiated larger LAN records. Native Wi-Fi socket binding, serialized legacy NSD resolution, and scoped IPv6 addressing. See [LAN Connections](LAN_CONNECTIONS.md), [LAN Contract](../protocol/lan/README.md), and [ADR 0006](decisions/0006-independent-lan-sessions.md).
- **Automatic LAN:** Opt-in Settings/pairing controls on both platforms coordinate bounded Mac admission over secured BLE, Android foreground discovery on connection events, ordinary BLE feature activity or feature demand, without a separate LAN retry loop. See [rendezvous](../protocol/lan/AUTOMATIC.md).
- **Concurrent Coexistence:** Independent fresh sessions and key material over BLE and LAN to the same pinned peer, coordinated under a shared peer reservation lock.

### 4. Connected-Idle Performance

Maintenance waits for absolute monotonic deadlines and transport events. Idle waits perform no KeyStore, Keychain or disk reads; authenticated operations retain native identity and trust validation. Reset and revocation retire both transports. Measurements and remaining performance work are recorded in [Performance](PERFORMANCE.md).

### 5. Application Continuity
- **Now Playing:** Remote Mac playback, source selection, seek previews, native Android notifications (`MediaSession` / `Notification.MediaStyle`), and player/output volume controls are implemented. Mac Home/companion display is optional. See [Now Playing](features/NOW_PLAYING.md), [ADR 0007](decisions/0007-macos-unsandboxed-playback-prototype.md), and [ADR 0009](decisions/features/now-playing/0009-remote-playback-presentation.md).

- **Local File Transfer:** Bidirectional sequential batch streaming (1..128 files) over authenticated LAN/BLE DATA records with negotiated cumulative credit (four 3,072-byte chunks on BLE; up to eight 262,016-byte chunks on capable LAN), recipient offer approval, exclusive partial staging with checked SHA-256 verification and finalization, on-demand connection, and presentation across Features and Home live-activity. See [Local File Transfer](features/FILE_TRANSFER.md) and [Transfer Contract](../protocol/transfer/README.md).

- **Find Device:** Native peer alerts, Android alarm playback with Stop and sixty-second expiry, Mac notifications and explicit notification setup. See [Find Device](features/FIND_DEVICE.md).

- **Messages (SMS relay):** Incoming SMS becomes a Mac notification with an inline reply, and the Mac reads the phone's conversations and history on demand over the secured session without storing content. See [Messages](features/SMS.md) and the [SMS Contract](../protocol/sms/README.md).

- **Native UI:** Dedicated feature panels, Favourites and About, compact phone Home, direct transport controls in Devices, accessible disclosure labels and responsive Mac activity panels.


## Messages (SMS relay)

[Messages](features/SMS.md) relays incoming SMS to Mac notifications and lets the Mac read provider conversations and history, search them and reply. Relay needs Android SMS permissions (RECEIVE_SMS live, READ_SMS history, SEND_SMS replies), an active secured session and the Mac app running; nothing is stored on the Mac or replayed after process death. Conversations, history and the thread list load incrementally, mixed-SIM conversations label each message’s subscription, replies can pick an active subscription and paint as a provisional row until the phone confirms them, and per-phone notification and sound switches live in Settings → Messages and behind the Messages panel's gear. RCS, MMS send, group MMS content, attachments, contacts resolution and mark-as-read are excluded.

## Text Clipboard

[Clipboard](features/CLIPBOARD.md) includes native text sharing, Android selection and Share-sheet actions, optional local history, focus-limited Android observation, permission-aware Mac observation and LAN-preferred/BLE-fallback delivery.
