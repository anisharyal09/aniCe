# Protocol changelog

Records shared communication-contract changes, compatibility implications, and protocol releases independently of application versions. Repository scaffolding and shared documentation are recorded in the [root changelog](../CHANGELOG.md).

## Unreleased

### Added

- Trusted-device session profile v1 with EDHOC method 0/suite 5, mandatory message 4, deterministic CCS credential references, CDDL and independent positive/negative vectors. Exporter, record and BLE contracts are specified for gated integration; existing discovery/pairing wire contracts are unchanged.

- Provisional pairing v1: compact QR identity commitment, native QR bootstrap, OPAQUE manual mode, bounded GATT framing with stable attribute layout (ADR 0004), encrypted identity proof/consent and signed storage receipts. Discovery assignments and payload are preserved.

- Fixed public aniCe BLE service/characteristic UUIDs, version 1 20-byte discovery payload with optional flags and rotating nonce, and shared positive/negative vectors.

- Added provisional public identity schema version 1, with canonical P-256 public keys, SHA-256 fingerprints, and native DER signature interoperability.
- Added shared positive/negative identity and signature fixtures, public test-only key scalars, and a reproducible fixture generator using OpenSSL.
- Documented runtime semantic validation and the test-only interchange bundle. Network serialization, framing, generated models, and a transport protocol version remain undecided; no protocol release has been assigned.
