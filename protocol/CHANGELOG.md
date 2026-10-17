# Protocol changelog

Records shared communication-contract changes, compatibility implications, and protocol releases independently of application versions. Repository scaffolding and shared documentation are recorded in the [root changelog](../CHANGELOG.md).

## [0.2.0]

### Added

- Define Find Device v1 capability, request and correlated result envelopes with per-generation replay floors, bounded duplicate history and queues, OS-submission acknowledgement semantics (Android additionally waits for alarm-player startup) and independent positive/negative fixtures.
- Local File Transfer v1 protocol (`protocol/transfer/transfer.cddl`, `README.md`) over LAN-preferred authenticated LAN/BLE DATA records (≤ 4,000 bytes) with 11 deterministic CBOR messages, cumulative credit flow control (64-window / 3,072-byte chunks), incremental SHA-256 verification, and 52 independent test vectors (19 valid, 33 invalid).
- Media v1 deterministic CBOR capability/subscription/snapshot/selection/command/result/artwork contracts, independently negotiated Mac output volume v1, and selected-player volume v1 within existing authenticated DATA records.
- Versioned LAN TCP envelope binding and independent framing fixtures.
- Coordinated RENEWAL_REQUEST behavior, 55-minute/record-margin thresholds and old-session retirement before fresh EDHOC.

### Changed

- Specify fresh-request replacement for submitted Mac Find Device notifications while retaining Android ringing/submission busy responses and duplicate suppression. Wire bytes and result codes are unchanged.
- Document production LAN benchmarking, bulk probe telemetry, and real-world file transfer performance characteristics across RF tiers in `protocol/lan/BENCHMARK.md`.

### Fixed

- Amortize live native validation with explicitly selected LAN profile 3: domain-separated 256-KiB records, advertised 128-KiB file chunks and at most 1 MiB of transfer credit; preserve standard BLE formats and live native identity/trust checks.
- Define LAN-preferred file-transfer routing, channel-scoped capability, sliced-offer affinity and generation-bound replies; interrupted batches require explicit resend and existing wire fixture bytes remain unchanged.
- Clarify transfer inventory/state validation, written ACK semantics and unavailable resume behavior; identify coordinated LAN renewal as unimplemented without changing existing fixture bytes.

## [0.1.0]

### Added

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
