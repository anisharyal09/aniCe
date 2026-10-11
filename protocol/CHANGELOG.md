# Protocol changelog

Records shared communication-contract changes, compatibility implications, and protocol releases independently of application versions. Repository scaffolding and shared documentation are recorded in the [root changelog](../CHANGELOG.md).

## Unreleased

### Added

- Media v1 deterministic CBOR capability/subscription/snapshot/selection/command/result/artwork contracts and independent bounded fixtures within existing authenticated DATA records.

- Versioned LAN TCP envelope binding and independent framing fixtures; existing EDHOC and encrypted-record formats remain unchanged.

- Coordinated RENEWAL_REQUEST behavior, 55-minute/record-margin thresholds and old-session retirement before fresh EDHOC.

- Bounded deterministic CBOR application controls in DATA kind 3/envelope 6, authoritative CDDL, and eight valid/26 invalid independent cbor2 fixtures.
- HELLO/ACK compatibility, one outstanding PING/PONG and monotonic liveness deadlines.
- Independent AES-GCM positive and negative record test vectors covering directional sequence bounds and lifetime limits.
- Shared session v2 GATT framing with 9-byte header (`messageId`, `totalLength`, `offset`) and logical payload discrimination.
- Trusted-device session profile v1: EDHOC method 0 / suite 5, mandatory message 4, deterministic CCS credentials, CDDL, and positive/negative handshake vectors.
- Provisional pairing v1: compact QR identity commitment, PAKE manual bootstrap, bounded GATT framing with stable attribute layout (ADR 0004), encrypted identity proof, and signed storage receipts.
- Fixed public aniCe BLE service/characteristic UUIDs and version 1 20-byte discovery payload with rotating nonce.
- Public device identity schema version 1: canonical P-256 public keys, SHA-256 fingerprints, and native DER signature interoperability.

### Changed

- Clarify deadline-driven handshake retirement and per-operation validation without changing session or control bytes.

- Update active contracts table, add trusted-device sessions and LAN binding sections, and update directory layout with LAN specifications and test vectors in README.
- Clarify manual verification boundaries and add purpose summaries to oracle regression modules and dependency configuration.
- Update BLE GATT primary service and characteristic UUIDs.
