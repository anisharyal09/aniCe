# Protocol changelog

Records shared communication-contract changes and compatibility implications. Protocol contracts remain independently versioned; this section groups the contract changes included with application release v0.3.0. Repository-wide changes are recorded in the [root changelog](../CHANGELOG.md).

## [Unreleased]

## [v0.3.0]

### Fixed

- Tolerate progressing encrypted LAN frames after secured readiness with a ten-second no-progress deadline and sixty-second absolute assembly cap. Partial headers and handshake frames retain ten seconds absolute; wire bytes, record authentication and socket write deadlines are unchanged.

- Clarify file-transfer acknowledgement cadence as window-relative: a quarter-window for large LAN chunks and up to eight chunks for standard/BLE, retaining the 20-ms flush and final-chunk acknowledgement. Wire messages, capability ranges and limits are unchanged.

- Document checkpoint-backed transfer resume with existing kinds 10/11 and a four-chunk BLE implementation window; framing, capability ranges, session cryptography and fixture bytes remain unchanged.

- Coalesce ordinary BLE traffic into one LAN demand per channel and eligibility interval.

### Added

- SMS Relay v3 defines deterministic CBOR capability negotiation, cursor-paginated conversations and history, acknowledged live message streams, multipart replies, phone-side search, active-SIM discovery and per-message subscription attribution inside authenticated DATA. Bodies are bounded to 24,576 UTF-8 bytes in up to eight fragments; records remain within 4,000 bytes and page limits are advertised per link. Composite cursors use byte-wise identifier ordering and terminal `(0, "")` pairs; incomplete provider reads and oversized timestamp groups do not advance them. Live events retry within their ten-minute pending lifetime, duplicate reply results are bounded, and `sendResult.dateMillis` carries the provider send time or phone send-queue time. Both applications must support v3 to exchange SMS.

- Clipboard v1 deterministic CBOR capabilities, receive settings, bounded text assembly, ordered item identities, terminal deduplication and one safe cross-transport retry, with independent positive/negative fixtures.

- Activated the reserved Local File Transfer `resume` (10) and `status` (11) messages for in-memory pause/resume after a channel change. Either side can initiate a resume: the sender proposes its acknowledged offset, or the receiver proposes the prefix it retains when the user explicitly continues over Bluetooth; the receiving side validates the offset and prefix hash and answers with states 0–4. A live LAN that becomes capable during a BLE stream runs the same handshake and upgrades the active stream in place. The verified partial is retained for 15 minutes and a resume at the final length replays the verified file result. CDDL, framing, bounds and fixture bytes are unchanged.
- Defined automatic LAN rendezvous v1, with demand from ordinary BLE feature traffic and explicit file selection, over authenticated BLE DATA without changing existing LAN framing or session profiles.

### Changed

- Document overlapping Android LAN discovery, serial resolution and endpoint authentication under the existing 15-second browse and 90-second connection bounds; framing and authentication contracts are unchanged.

- Add LAN-only transfer capability 3 for 262,016-byte chunks within the existing 262,144-byte authenticated DATA record; advertise a capability-2 baseline first so older peers retain support, with standard/BLE limits unchanged.

- Documented Android explicit tile focus and bounded process-local clipboard previews/Copy on both platforms as native behavior using existing clipboard messages.

- Clarified that optional device-local clipboard history is separate from process-local delivery state and shares native observation without changing wire messages.

## [0.2.0]

### Added

- **Find Device (v1)**:
  - Define Find Device v1 capability, request, and correlated result envelopes with per-generation replay floors.
  - Bounded duplicate history and request queues with OS-submission acknowledgement semantics (Android additionally waits for alarm-player startup).
  - 10 independent positive and negative test vectors covering valid submissions, missing fields, duplicate sequences, and expired generations.
- **Local File Transfer (v1)**:
  - Local File Transfer v1 protocol (`protocol/transfer/transfer.cddl`) over LAN-preferred authenticated LAN/BLE DATA records (≤ 4,000 bytes).
  - 11 deterministic CBOR messages, cumulative credit flow control (64-window / 3,072-byte chunks), and incremental SHA-256 chunk verification.
  - 52 independent test vectors (19 valid, 33 invalid) asserting byte-level CBOR compliance, flow control boundaries, and error rejection.
- **Now Playing & Media Controls (v1)**:
  - Media v1 deterministic CBOR contracts: capability, subscription, snapshot, selection, command, result, and artwork envelopes within authenticated DATA records.
  - Independently negotiated Mac system output volume v1 and selected-player volume v1.
- **Transports & Framing**:
  - Versioned LAN TCP envelope binding and independent framing fixtures.
  - Coordinated `RENEWAL_REQUEST` protocol semantics, 55-minute/record-margin thresholds, and old-session retirement before fresh EDHOC.

### Changed

- **Notification Lifecycle**: Specify fresh-request replacement for submitted Mac Find Device notifications while retaining Android ringing/submission busy responses and duplicate suppression. Wire bytes and result codes are unchanged.
- **LAN Telemetry**: Document production LAN benchmarking, bulk probe telemetry, and real-world file transfer performance characteristics across RF tiers in `protocol/lan/BENCHMARK.md`.

### Fixed

- **LAN Profile 3 Negotiation**: Amortize live native validation with explicitly selected LAN profile 3: domain-separated 256-KiB records, advertised 128-KiB file chunks, and at most 1 MiB of transfer credit; preserve standard BLE formats and live native identity/trust checks.
- **Routing & Interruption**: Define LAN-preferred file-transfer routing, channel-scoped capability, sliced-offer affinity, and generation-bound replies; interrupted batches require explicit resend and existing wire fixture bytes remain unchanged.
- **Transfer State Validation**: Clarify transfer inventory/state validation, written ACK semantics, and unavailable resume behavior; identify coordinated LAN renewal as unimplemented without changing existing fixture bytes.

## [0.1.0]

### Added

- Bounded deterministic CBOR application controls in DATA kind 3/envelope 6, authoritative CDDL, and eight valid/26 invalid independent cbor2 fixtures.
- HELLO/ACK compatibility, one outstanding PING/PONG and monotonic liveness deadlines.
- Independent AES-GCM positive and negative record test vectors covering directional sequence bounds and lifetime limits.
- Shared session v2 GATT framing with 9-byte header (`messageId`, `totalLength`, `offset`) and logical payload discrimination.
- Trusted-device session profile v1: EDHOC method 0 / suite 5, mandatory message 4, deterministic CCS credentials, CDDL, and positive/negative handshake vectors.
- Provisional pairing v1: compact QR identity commitment, PAKE manual bootstrap, bounded GATT transport with stable attribute layout (ADR 0004), encrypted identity proof, and signed storage receipts.
- Fixed public aniCe BLE service/characteristic UUIDs and version 1 20-byte discovery payload with rotating nonce.
- Public device identity schema version 1: canonical P-256 public keys, SHA-256 fingerprints, and native DER signature interoperability.

### Changed

- Clarify deadline-driven handshake retirement and per-operation validation without changing session or control bytes.
- Update active contracts table, add trusted-device sessions and LAN binding sections, and update directory layout with LAN specifications and test vectors in README.
- Clarify manual verification boundaries and add purpose summaries to oracle regression modules and dependency configuration.
- Update BLE GATT primary service and characteristic UUIDs.
