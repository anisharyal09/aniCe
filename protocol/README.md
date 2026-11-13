# Shared Communication Contracts

This directory contains the cross-platform communication contracts, schemas, and shared verification fixtures for **aniCe**.

Contracts define required behavior.

---

## Active Contracts

| Contract | Version | Status | Primary Reference | Scope |
| :--- | :--- | :--- | :--- | :--- |
| **Device Identity** | `1` | Provisional | [`schemas/identity.schema.json`](schemas/identity.schema.json) | Protected native P-256 public identity and fingerprint |
| **BLE Discovery** | `1` | Provisional | [`bluetooth/README.md`](bluetooth/README.md) | Unauthenticated 20-byte BLE compatibility probe |
| **Classic Bluetooth HID input** | System profile | Implemented on macOS | [`bluetooth/classic-hid.md`](bluetooth/classic-hid.md) | Local keyboard and pointer reports to a system-paired Android HID host |
| **Pairing** | `1` | Provisional | [`pairing/README.md`](pairing/README.md) | QR/PIN authentication, mutual approval and peer trust |
| **Trusted-device sessions** | `1` | Implemented | [`session/README.md`](session/README.md) | Pinned EDHOC, directional AES-GCM records and BLE v2 |
| **Now Playing** | `1` | Implemented | [`media/README.md`](media/README.md) | Subscribed playback and directed commands in secured DATA |
| **Player volume** | `1` | Capability gated | [`media/PLAYER_VOLUME.md`](media/PLAYER_VOLUME.md) | Separately negotiated selected-player integer volume |
| **Mac Desk Deck** | `1`–`5` | Implemented | [`desk-deck/README.md`](desk-deck/README.md) | Subscribed Mac telemetry, renewable leases, approved app shortcuts and trusted-phone controls in secured DATA |
| **Device Power** | `1` | Implemented | [`device-power/README.md`](device-power/README.md) | Peer battery and charging status on existing device surfaces over authenticated DATA, with no new connection lease |
| **LAN Binding** | `3` (legacy `1`/`2`) | Implemented | [`lan/README.md`](lan/README.md) | Anonymous DNS-SD discovery and bounded TCP stream framing |
| **Automatic LAN rendezvous** | `1` | Implemented | [`lan/AUTOMATIC.md`](lan/AUTOMATIC.md) | Opt-in authenticated BLE coordination of event/demand-triggered LAN admission |
| **Clipboard** | `1` | Implemented | [`clipboard/README.md`](clipboard/README.md) | Native text delivery, per-peer consent and bounded cross-transport retries |
| **SMS Relay** | `3` | Implemented | [`sms/README.md`](sms/README.md) | Provider thread/history/search reads, live SMS events, optional SIM choice and replies inside secured DATA |
| **Notification Mirroring** | `1` | Implemented | [`notifications/README.md`](notifications/README.md) | Selected Android app alerts and bounded source icons, native Mac actions and synchronized dismissal inside secured DATA |
| **File Transfer** | `1` | Implemented | [`transfer/README.md`](transfer/README.md) | Bounded sequential batch file transfer over authenticated DATA |
| **Phone-to-Mac input** | 1 | Implemented | [phone-input/README.md](phone-input/README.md) | Authenticated Android-to-Mac text and input events over secured BLE DATA |

---

The macOS-only [Classic Bluetooth HID input profile](bluetooth/classic-hid.md) is a system input transport, not an aniCe application-session contract. Its exact descriptor and report fixtures live in [`test-vectors/bluetooth-hid/hid-vectors.json`](test-vectors/bluetooth-hid/hid-vectors.json).

## 1. Device Identity Contract (`v1`)

Architecture and storage rationale are documented in [ADR 0001: Provisional Device Identity](../docs/decisions/0001-provisional-device-identity.md).

### Public Identity Schema
The canonical JSON Schema is defined in [`schemas/identity.schema.json`](schemas/identity.schema.json). Unknown properties are strictly rejected.

| Field | Type | Description & Validation Constraints |
| :--- | :--- | :--- |
| `identitySchemaVersion` | integer | Must be `1`. Independent of future transport or capability versions. |
| `deviceId` | string | Canonical lowercase UUID v4 (hyphenated). Resetting identity generates a new ID. |
| `deviceName` | string | Display name trimmed of surrounding whitespace. Max 64 Unicode code points. |
| `platform` | string | Enum: `"android"` or `"macos"`. |
| `algorithm` | string | Constant: `"ECDSA_P256_SHA256"`. |
| `publicKey` | string | Canonical Base64 of the 65-byte uncompressed P-256 point (`0x04 || X[32] || Y[32]`). Coordinates are 32-byte big-endian. |
| `fingerprint` | string | 64-character lowercase hex SHA-256 digest of the raw 65-byte uncompressed public key. |

### Semantic Validation Rules
Beyond standard JSON type checks, both platform implementations strictly validate:
- **Canonical Base64:** Re-encoded after decode to detect non-canonical padding, invalid characters, or whitespace.
- **Key Structure:** Length must be exactly 65 bytes starting with prefix byte `0x04`. Both coordinates must be valid curve points.
- **Fingerprint Verification:** Recomputed SHA-256 hash must match the `fingerprint` field exactly.
- **Display Metadata:** Device names and protection labels are local display metadata and do not confer cryptographic trust by themselves.

### Cryptographic Signatures
Cross-platform signature exchange uses native protected key stores. Actual hardware protection is reported by each backend:
- **Algorithm:** P-256 (NIST P-256 / secp256r1) with SHA-256 digest.
- **Hashing:** Message bytes are passed directly to platform signing APIs (not pre-hashed).
- **Format:** Strict ASN.1 DER `SEQUENCE(INTEGER r, INTEGER s)`.
  - Parsers reject trailing bytes, non-minimal length encodings, and negative or out-of-range integers ($1 \le r, s < n$).
  - IEEE P1363 raw $r \parallel s$ signatures are rejected.
- **Platform APIs:**
  - **Android:** `SHA256withECDSA` via `AndroidKeyStore`.
  - **macOS:** Security framework (`kSecKeyAlgorithmECDSASignatureMessageX962SHA256`) and CryptoKit DER verification.

---

## 2. BLE Discovery Contract (`v1`)

Full specification, timing limits, and validation rules are documented in [`bluetooth/README.md`](bluetooth/README.md).

- **Service UUID:** `414E4953-4843-654A-494C-534149303901`
- **Discovery Characteristic UUID:** `414E4953-4843-654A-494C-534149303902` (Read-only)
- **Payload:** Exactly 20 bytes (`version` [2B] + `optional capability flags` [2B] + `nonce` [16B]).
- **Role:** Compatibility probe only. Establishes no trust, exchanges no public identity, and requests no pairing.

---

## 3. Pairing & Trust Contract (`v1`)

Full specification, byte framing, cryptographic derivation, and lifetime rules are documented in [`pairing/README.md`](pairing/README.md).

- **Service UUID:** `414E4953-4843-654A-494C-534149303901`
- **Pairing Write UUID:** `414E4953-4843-654A-494C-534149303903` (Write with response)
- **Pairing Indicate UUID:** `414E4953-4843-654A-494C-534149303904` (Indicate)
- **Authentication Modes:**
  - **QR Code:** P-256 ECDH with 256-bit PSK and SHA-256 identity fingerprint commitment.
  - **Six-Digit PIN:** OPAQUE PAKE (`opaque-ke 4.0.1`, Ristretto255, TripleDH, Argon2id).
- **Transport Security:** AES-256-GCM directional encryption, transcript-bound identity proofs, and mutually signed storage receipts.

---

## 4. Trusted-Device Sessions Contract (`v1`)

Full specification, record framing, CBOR definitions, and keepalive controls are documented in [`session/README.md`](session/README.md).

- **Handshake:** RFC 9528 EDHOC method 0, cipher suite 5 (P-256, SHA-256, ChaCha20-Poly1305), mandatory message 4.
- **Application Records:** AES-256-GCM with directional 64-bit counters; standard/BLE plaintext is bounded to 4,000 bytes. Negotiated LAN profiles use the larger bounds in the [LAN profile](lan/TRANSFER_PROFILE.md).
- **Liveness & Renewal:** Encrypted HELLO/ACK and PING/PONG; automatic BLE reconnects with fresh sessions before lifetime/record limits. Manual LAN requires another Connect after expiry; automatic LAN waits for an eligible event or feature demand.
- **BLE Transport:** Session v2 fragmentation header, 10-second reassembly deadline, 32 KiB queue limit.

---

## 5. LAN Binding Contract (revision 3)

Full specification, DNS-SD locator rules, and TCP stream framing are documented in [`lan/README.md`](lan/README.md).

- **Discovery:** `_anice._tcp` DNS-SD registration with an anonymous `aniCe-<UUID>` instance and current `v=3` TXT revision; legacy revisions are `1` and `2`. Locators confer no trust.
- **Stream Framing:** A five-byte version/length header precedes each session envelope. Current profile 4 uses frame version 4 and a 2–524,447-byte envelope; legacy profile 3 and standard profile 1 retain their own negotiated limits. Handshakes remain bounded to 4,096 bytes.
- **Transport Security:** Independent fresh EDHOC session and directional AES-GCM records over TCP.
- **Coexistence:** Shared peer reservation permits concurrent BLE and LAN sessions only to the same pinned peer.

---

## 6. Directory Layout & Shared Fixtures

```text
protocol/
├── CHANGELOG.md                   # Protocol version and contract changelog
├── README.md                      # This document
├── bluetooth/
│   └── README.md                  # BLE discovery wire format & lifecycle
├── desk-deck/
│   ├── README.md                  # Mac telemetry, app approval and control behavior
│   └── desk-deck.cddl             # Bounded Desk Deck v1–v4 messages
├── device-power/
│   ├── README.md                  # Reciprocal phone power status behavior
│   └── device-power.cddl          # Shared device-power capability and report
├── fixtures/
│   └── identity/                  # Sample valid JSON records (android.json, macos.json)
├── lan/
│   ├── README.md                  # Local network stream framing and mDNS discovery contract
│   ├── BENCHMARK.md               # Production LAN throughput benchmark harness & gates
│   └── BULK_PROBE.md              # Isolated bulk record profiling specification
├── pairing/
│   └── README.md                  # Pairing protocol, framing, cryptography & state machine
├── phone-input/
│   ├── README.md                  # Phone-to-Mac input v1 contract and lifecycle rules
│   └── phone-input.cddl           # Phone-to-Mac input message shapes
├── notifications/
│   ├── README.md                  # Android-to-Mac alert mirroring behavior and lifecycle
│   └── notifications.cddl         # Notification message shapes
├── schemas/
│   └── identity.schema.json       # Canonical JSON Schema for public identity
├── session/
│   ├── README.md                  # EDHOC, encrypted records and BLE session contract
│   ├── session.cddl               # Restricted deterministic CCS/EDHOC definitions
│   └── control.cddl               # Bounded CBOR compatibility, liveness and renewal controls
├── transfer/
│   ├── README.md                  # Local file transfer protocol, flow control & lifecycle
│   └── transfer.cddl              # Authoritative message and envelope CDDL definitions
└── test-vectors/
    ├── discovery-vectors.json     # Positive & negative BLE discovery test vectors
    ├── desk-deck-vectors.json      # Desk Deck v1–v4 samples, actions and invalid records
    ├── device-power-vectors.json   # Phone power states and invalid records
    ├── identity-vectors.json      # Positive & negative P-256 identity & DER signature vectors
    ├── generate_identity_vectors.py # Deterministic OpenSSL fixture regeneration script
    ├── lan/
    │   ├── bulk-probe-vectors.json # Positive & negative bulk probe framing vectors
    │   ├── generate_bulk_probe_vectors.py # Bulk probe fixture generator
    │   ├── lan-vectors.json       # Positive & negative TCP stream envelope framing vectors
    │   └── generate_lan_vectors.py # Independent Python oracle and fixture generator
    ├── pairing-vectors.json       # Deterministic QR, HKDF, MAC & encryption test vectors
    ├── generate_pairing_vectors.py  # Independent Python/cryptography test vector generator
    ├── phone-input/
    │   ├── phone-input-vectors.json # Positive & negative Phone-to-Mac input fixtures
    │   └── generate.py              # Independent Phone-to-Mac input fixture generator
    ├── notifications/
    │   ├── notification-vectors.json # Positive & negative notification mirroring fixtures
    │   └── generate_notification_vectors.py # Independent CBOR fixture generator
    ├── session/
    │   ├── session-vectors.json  # Complete method-0/suite-5 traces and invalid handshakes
    │   ├── record-vectors.json   # AES-GCM records, nonce/counter boundaries and tampering cases
    │   ├── control-vectors.json  # Valid/invalid compatibility, ping and renewal controls
    │   ├── rfc9529-components.json # Published suite-0 derivations used for common components
    │   ├── requirements.txt      # Pinned independent Python crypto/CBOR oracle dependencies
    │   └── *.py                  # Fixture generation and independent oracle regressions
    └── transfer/
        ├── transfer-vectors.json  # Positive & negative transfer message fixtures
        └── generate_transfer_vectors.py # Fixture generator
```

## Mac Desk Deck and Device Power

[Mac Desk Deck v1–v5](desk-deck/README.md) defines subscription-bound Mac telemetry and controls. V2 adds renewable leases, richer memory and Mac power readings, and paged launches for Mac-approved app bundles; v4 adds one locally selected Do Not Disturb Shortcut; v5 adds default-output selection. Older peers remain supported. [Device Power v1](device-power/README.md) shares peer battery and charging state on Mac device surfaces and Android Home and Devices over a secured channel that is already open. Both contracts have shared Kotlin/Swift fixtures under [test-vectors](test-vectors/desk-deck-vectors.json).

## Media

[Media v1](media/README.md) defines foreground playback subscriptions, revision-bound commands and LAN-only bounded artwork within existing authenticated DATA. [Independent fixtures](test-vectors/media/media-vectors.json) contain positive and negative media envelopes.

Now Playing also defines separately advertised [Mac output volume](media/OUTPUT_VOLUME.md), with independent positive/negative fixtures and unchanged media/player-volume v1 encodings.

## File Transfer

[File Transfer v1](transfer/README.md) defines sequential multi-file batches over authenticated LAN/BLE DATA, negotiated chunk/window limits, per-sender approval, exclusive partial staging, incremental SHA-256 verification and checked non-overwriting publication. Current LAN profile 4 permits 512-KiB chunks and eight-chunk credit; both native BLE implementations advertise four 3,072-byte chunks within the v1 protocol's 64-chunk ceiling. Document-provider finalization is not guaranteed atomic. [Independent fixtures](test-vectors/transfer/transfer-vectors.json) validate the envelopes and bounds.

## Find Device

[Find Device v1](find-device/README.md) defines bidirectional notification requests and correlated OS-submission results over existing authenticated DATA.

## Phone-to-Mac input

[Phone-to-Mac input v1](phone-input/README.md) defines committed Unicode text separately from physical key transitions, with session-bound sequencing, fail-safe release and BLE motion coalescing. Its [CDDL](phone-input/phone-input.cddl) and [independent fixtures](test-vectors/phone-input/phone-input-vectors.json) lock the cross-platform encoding.

## Clipboard

[Clipboard v1](clipboard/README.md) defines bounded text fragments, per-peer automatic consent, live-process idempotent application and one cross-transport retry. [CDDL](clipboard/clipboard.cddl) and [independent fixtures](test-vectors/clipboard/clipboard-vectors.json) specify canonical DATA messages.

## SMS Relay

[SMS relay v3](sms/README.md) defines provider thread, paged history and search reads, live `SMS_RECEIVED` events with capability gating and `messageResult` acknowledgement, an optional SIM listing for per-reply subscription choice, and Mac-composed replies reassembled by Android before SMS submission. [CDDL](sms/sms.cddl) and [independent fixtures](test-vectors/sms/sms-vectors.json) specify canonical DATA messages; the thread list and history/search pages are ordered with byte-wise lexical id ties, each message carries the subscription it arrived on, and live/provider copies merge by content key. Version 3 requires both applications to update together.

## Notification Mirroring

[Notification Mirroring v1](notifications/README.md) carries selected Android app alerts over authenticated DATA to native Mac notifications, with revision- and peer-bound source taps, available actions, simple text replies and synchronized dismissal. Android excludes aniCe and the current default SMS app; snapshot reconciliation keeps BLE/LAN handoffs idempotent. [CDDL](notifications/notifications.cddl) and [independent fixtures](test-vectors/notifications/notification-vectors.json) define the bounded canonical records.

## Do Not Disturb sync

[DND sync v1](dnd-sync/README.md) carries explicit phone-to-Mac DND state changes independently of Desk Deck. Android requires Notification Policy access to observe phone changes, and Mac applies them through selected On/Off Shortcuts. Mac-to-phone state changes are unsupported. It uses only existing secured connections and opens no feature lease. [Shared fixtures](test-vectors/dnd-sync-vectors.json) cover both codecs.
