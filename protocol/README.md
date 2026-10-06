# Shared Identity Protocol & Contract

This directory defines the shared Phase 2 public device identity schema and cross-platform verification fixtures for **aniCe**.

Architecture and storage rationale are documented in [ADR 0001: Provisional Device Identity](../docs/decisions/0001-provisional-device-identity.md).

---

## 1. Public Identity Schema (`v1`)

The canonical schema is defined in [`schemas/identity.schema.json`](schemas/identity.schema.json). Unknown properties are strictly rejected.

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

---

## 2. Cryptographic Signatures

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

## 3. Fixtures & Test Vectors

| Path | Purpose |
| :--- | :--- |
| [`schemas/identity.schema.json`](schemas/identity.schema.json) | JSON Schema definition for public identity records. |
| [`fixtures/identity/`](fixtures/identity/) | Sample valid public identity payloads for Android and macOS. |
| [`test-vectors/identity-vectors.json`](test-vectors/identity-vectors.json) | Shared vector suite containing valid cases, invalid identity variations, and invalid DER signatures. |

### Test Interchange Bundle Format
Ephemeral cross-platform verification between native test suites uses this payload format:

| Field | Type | Description |
| :--- | :--- | :--- |
| `identity` | object | Complete public identity record matching schema v1. |
| `messageBase64` | string | Standard Base64 of raw test message bytes. |
| `signatureBase64` | string | Standard Base64 of ASN.1 DER signature bytes. |

### Regenerating Vectors
Test vector signatures can be deterministically refreshed using OpenSSL:
```sh
python3 protocol/test-vectors/generate_identity_vectors.py --output protocol/test-vectors/identity-vectors.json
```
