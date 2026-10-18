# Protocol changelog

Records shared communication-contract changes, compatibility implications, and protocol releases independently of application versions. Repository scaffolding and shared documentation are recorded in the [root changelog](../CHANGELOG.md).

## [Unreleased]

### Added

- SMS relay v1 deterministic CBOR capability, thread-list, paged history, live message-stream, reply and result messages, with capability gating, `messageResult` acknowledgement for live streams only, byte-wise lexical messageId cursor ties and content-key live/provider deduplication; 119 independent fixtures (46 valid, 73 invalid).

- Clipboard v1 deterministic CBOR capabilities, receive settings, bounded text assembly, ordered item identities, terminal deduplication and one safe cross-transport retry, with independent positive/negative fixtures.

- Activated the reserved Local File Transfer `resume` (10) and `status` (11) messages for in-memory pause/resume after a channel change. Either side can initiate a resume: the sender proposes its acknowledged offset, or the receiver proposes the prefix it retains when the user explicitly continues over Bluetooth; the receiving side validates the offset and prefix hash and answers with states 0–4. A live LAN that becomes capable during a BLE stream runs the same handshake and upgrades the active stream in place. The verified partial is retained for 15 minutes and a resume at the final length replays the verified file result. CDDL, framing, bounds and fixture bytes are unchanged.
- Defined automatic LAN rendezvous v1, with demand from ordinary BLE feature traffic and explicit file selection, over authenticated BLE DATA without changing existing LAN framing or session profiles.

### Changed

- Clarified SMS capability limits: `maxThreadsPerPage` and `maxMessagesPerPage` are the advertiser's per-link limits in 1..50 rather than the fixed value 50, so a slower link can announce smaller thread lists and pages, and a peer serves within the limits it received. Layout, field order and bounds are unchanged and a 50/50 capability stays valid.

- Clarified SMS live-relay retry semantics: an event that is not acknowledged is offered again on its live channels inside its ten-minute pending lifetime rather than only once, and an idempotent capability record may be re-sent on a link whose peer capability has not arrived with the receiver answering with its own, so a lost fragment, `messageResult` or capability hello does not strand the event until a new channel generation. Messages, bounds and fixture bytes are unchanged.

- Clarified SMS `historyDone` cursor semantics: a page with no older rows sends the terminal `(0, "")` cursor so clients never offer an empty "load older" request, and `unreadCount` counts unread incoming provider rows because the threads view's `read` column is an all-read flag, not a count. An `addr:` identity carries alphanumeric sender IDs as their trimmed uppercase text, so bank and service senders keep distinct conversation identities instead of one empty-string identity. Seven-bit SMS bodies decode to their declared septet count, so the octet padding never becomes a trailing character and the message digest matches the provider copy.

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
