# Shared Communication Contracts

This directory contains the cross-platform communication contracts, schemas, and shared verification fixtures for **aniCe**.

Contracts define required behavior. Comprehensive manual acceptance remains pending; automated unit tests and independent test vectors validate wire implementations.

---

## Active Contracts

| Contract | Version | Status | Primary Reference | Scope |
| :--- | :--- | :--- | :--- | :--- |
| **Device Identity** | `1` | Provisional | [`schemas/identity.schema.json`](schemas/identity.schema.json) | Protected native P-256 public identity and fingerprint |
| **BLE Discovery** | `1` | Provisional | [`bluetooth/README.md`](bluetooth/README.md) | Unauthenticated 20-byte BLE compatibility probe |
| **Pairing** | `1` | Provisional | [`pairing/README.md`](pairing/README.md) | QR/PIN authentication, mutual approval and peer trust |
| **Trusted-device sessions** | `1` | Implemented; acceptance pending | [`session/README.md`](session/README.md) | Pinned EDHOC, directional AES-GCM records and BLE v2 |
| **LAN Binding** | `1` | Implemented; acceptance pending | [`lan/README.md`](lan/README.md) | Anonymous DNS-SD discovery and bounded TCP stream framing |

---

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
- **Application Records:** AES-256-GCM, directional 64-bit sequence counters, 4,000-byte plaintext limit.
- **Liveness & Renewal:** Encrypted HELLO/ACK, PING/PONG keepalive, and coordinated session renewal before lifetime or sequence limits.
- **BLE Transport:** Session v2 fragmentation header, 10-second reassembly deadline, 32 KiB queue limit.

---

## 5. LAN Binding Contract (`v1`)

Full specification, DNS-SD locator rules, and TCP stream framing are documented in [`lan/README.md`](lan/README.md).

- **Discovery:** `_anice._tcp` DNS-SD service registration with anonymous instance name (`aniCe-<UUID>`) and `v=1` TXT record.
- **Stream Framing:** 5-byte header (`version:u8=1`, `length:u32BE`) preceding logical session envelope (2–4096 bytes).
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
├── fixtures/
│   └── identity/                  # Sample valid JSON records (android.json, macos.json)
├── lan/
│   └── README.md                  # Local network stream framing and mDNS discovery contract
├── pairing/
│   └── README.md                  # Pairing protocol, framing, cryptography & state machine
├── schemas/
│   └── identity.schema.json       # Canonical JSON Schema for public identity
├── session/
│   ├── README.md                  # EDHOC, encrypted records and BLE session contract
│   ├── session.cddl               # Restricted deterministic CCS/EDHOC definitions
│   └── control.cddl               # Bounded CBOR compatibility, liveness and renewal controls
└── test-vectors/
    ├── discovery-vectors.json     # Positive & negative BLE discovery test vectors
    ├── identity-vectors.json      # Positive & negative P-256 identity & DER signature vectors
    ├── generate_identity_vectors.py # Deterministic OpenSSL fixture regeneration script
    ├── lan/
    │   ├── lan-vectors.json       # Positive & negative TCP stream envelope framing vectors
    │   └── generate_lan_vectors.py # Independent Python oracle and fixture generator
    ├── pairing-vectors.json       # Deterministic QR, HKDF, MAC & encryption test vectors
    ├── generate_pairing_vectors.py  # Independent Python/cryptography test vector generator
    └── session/
        ├── session-vectors.json  # Complete method-0/suite-5 traces and invalid handshakes
        ├── record-vectors.json   # AES-GCM records, nonce/counter boundaries and tampering cases
        ├── control-vectors.json  # Valid/invalid compatibility, ping and renewal controls
        ├── rfc9529-components.json # Published suite-0 derivations used for common components
        ├── requirements.txt      # Pinned independent Python crypto/CBOR oracle dependencies
        └── *.py                  # Fixture generation and independent oracle regressions
```

## Media

[Media v1](media/README.md) defines foreground playback subscriptions, revision-bound commands and LAN-only bounded artwork within existing authenticated DATA. [Independent fixtures](test-vectors/media/media-vectors.json) contain positive and negative media envelopes.
