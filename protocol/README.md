# Shared Communication Contracts

This directory contains the cross-platform communication contracts, schemas, and shared verification fixtures for **aniCe**.

---

## Active Contracts

| Contract | Version | Status | Primary Reference | Scope |
| :--- | :--- | :--- | :--- | :--- |
| **Device Identity** | `1` | Provisional | [`schemas/identity.schema.json`](schemas/identity.schema.json) | Hardware-backed P-256 public identity and fingerprint |
| **BLE Discovery** | `1` | Provisional | [`bluetooth/README.md`](bluetooth/README.md) | Unauthenticated 20-byte BLE compatibility probe |

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
Cross-platform signature exchange uses native hardware-backed keystores without third-party crypto glue:
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

- **Service UUID:** `414E4953-4853-4149-4A49-4C4365090901`
- **Discovery Characteristic UUID:** `414E4953-4853-4149-4A49-4C4365090902` (Read-only)
- **Payload:** Exactly 20 bytes (`version` [2B] + `optional capability flags` [2B] + `nonce` [16B]).
- **Role:** Compatibility probe only. Establishes no trust, exchanges no public identity, and requests no pairing.

---

## 3. Directory Layout & Shared Fixtures

```text
protocol/
├── CHANGELOG.md               # Protocol version and contract changelog
├── README.md                  # This document
├── bluetooth/
│   └── README.md              # BLE discovery wire format & lifecycle
├── fixtures/
│   └── identity/              # Sample valid JSON records (android.json, macos.json)
├── schemas/
│   └── identity.schema.json   # Canonical JSON Schema for public identity
└── test-vectors/
    ├── discovery-vectors.json # Positive & negative BLE discovery test vectors
    ├── identity-vectors.json  # Positive & negative P-256 identity & DER signature vectors
    └── generate_identity_vectors.py # Deterministic fixture regeneration script
```
