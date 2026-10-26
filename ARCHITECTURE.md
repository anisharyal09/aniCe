<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Describes shared identity, trust, sessions and native transport ownership. -->
# Architecture

Pairing and transport owners share identity and trust services. BLE and LAN reuse the same session protocol while retaining independent keys and lifecycle ownership.

---

## 1. Platform-Native Device Identity

- **Android:** P-256 signing keys in `AndroidKeyStore`, with actual hardware/software protection reported and metadata excluded from backup.
- **macOS:** Actor-isolated P-256 lifecycle through Security and Keychain. Current app builds select development Keychain storage; the separate signed backend prefers Secure Enclave when available and still requires verification.
- **Boundary Format:** Signatures use ASN.1 DER at the native identity boundary. Identity reset retires sessions and automatic connection setup; trust bound to the previous identity no longer authorizes connections, so devices must pair again. It does not erase the other device's stored records.
- **Specifications & Decisions:** Defined in [ADR 0001 (Device Identity)](docs/decisions/0001-provisional-device-identity.md) and enforced by the [Identity Schema](protocol/schemas/identity.schema.json) with test cases in [`identity-vectors.json`](protocol/test-vectors/identity-vectors.json).

---

## 2. Cryptographic Bootstrap & Mutual Trust

- **QR Pairing:** Ephemeral P-256 ECDH with a 256-bit PSK and SHA-256 identity fingerprint commitment. Android scans the Mac's invitation using CameraX/ZXing.
- **Manual 6-Digit PIN Pairing:** Password-Authenticated Key Exchange (PAKE) powered by an isolated, in-memory [OPAQUE bridge](core/rust/pairing/README.md) (`opaque-ke 4.0.1`, Argon2id).
- **Mutual Approval:** Both devices require explicit on-screen approval before local trust activation. Each device persists its own journal atomically; completion across devices is not a distributed atomic transaction.
- **Specifications & Decisions:** Full protocol flow, wire framing, and state machines are documented in the [Pairing Protocol Contract](protocol/pairing/README.md), recorded in [ADR 0003 (Pairing & Trust)](docs/decisions/0003-provisional-pairing-and-trust.md), and verified by [`pairing-vectors.json`](protocol/test-vectors/pairing-vectors.json).

---

## 3. Authenticated Secure Sessions

- **EDHOC Handshake:** RFC 9528 EDHOC (method 0, cipher suite 5: P-256, SHA-256, ChaCha20-Poly1305) with mandatory message 4 authenticating pinned active trust.
- **Directional Record Channel:** Exporter-derived AES-256-GCM keys, strict ordered 64-bit counters, plaintext bounds of 4,000 bytes for standard records and 262,144 bytes for negotiated LAN profile 3, one-hour lifetime, and a hard limit of `2^20` records per direction. AES-GCM is aniCe's application profile; EDHOC suite 5 uses ChaCha20-Poly1305.
- **Encrypted Readiness:** Strict `ready` / `readyAck` handshake completion before any application payload can be submitted.
- **Specifications & Decisions:** Detailed wire envelopes, CBOR structures, and crypto derivation rules are specified in the [Session Protocol Contract](protocol/session/README.md), recorded in [ADR 0005 (EDHOC Secure Sessions)](docs/decisions/0005-edhoc-secure-sessions.md), and tested against [Session Test Vectors](protocol/test-vectors/session/).

---

## 4. Independent BLE & LAN Transports

- **BLE Transport:** Unauthenticated 20-byte compatibility discovery and bounded GATT v2 session framing. Mac is peripheral; Android is central. Opt-in Android companion ownership supplies background BLE lifetime on supported API 31+ platforms in Debug and Release.
  - Contract: [BLE Discovery Wire Format](protocol/bluetooth/README.md)
  - Lifecycle: [Background BLE Connections](docs/BACKGROUND_CONNECTIONS.md)
  - Decisions: [ADR 0002 (BLE Discovery)](docs/decisions/0002-provisional-ble-discovery.md) · [ADR 0004 (GATT Layout)](docs/decisions/0004-stable-ble-attribute-layout.md)
  - Vectors: [`discovery-vectors.json`](protocol/test-vectors/discovery-vectors.json)
- **LAN Transport:** Anonymous Bonjour/NSD discovery (`_anice._tcp`) and a five-byte TCP frame header with bounded envelopes. Android streams resolved Wi-Fi discovery candidates into selected-peer authentication during a bounded browse; Mac accepts local connections. LAN carries connection checks, subscribed media DATA and preferred file-transfer DATA, with a 4,000-byte standard plaintext bound or a 262,144-byte plaintext bound under negotiated profile 3. BLE retains standard records.
  - Mac frame assembly, submission accounting and watchdogs run in a transport actor; Android socket work runs on IO dispatchers. Frame parsing samples time once per receive buffer, retaining queue/nonce bounds. Secured encrypted-frame assembly allows ten seconds without byte progress, capped at sixty seconds total; pre-readiness assembly remains bounded to ten seconds.
  - Contract: [LAN Binding Contract](protocol/lan/README.md)
  - Lifecycle: [Independent LAN Connections](docs/LAN_CONNECTIONS.md)
  - Decisions: [ADR 0006 (Independent LAN Sessions)](docs/decisions/0006-independent-lan-sessions.md)
  - Vectors: [`lan-vectors.json`](protocol/test-vectors/lan/lan-vectors.json)
- **Concurrent Coexistence:** Simultaneous BLE and LAN sessions to the same pinned peer with independent session keys, nonces, and counters under a shared reservation lock.
- **Ownership:** Android idle LAN follows its configured background timeout after final activity stop or screen lock; bounded pickers and user-approved transfer-service leases retain active work. Network loss still retires the channel. Mac window and menu companion share its LAN owner; sleep and Quit retire it. Opt-in authenticated BLE rendezvous coordinates bounded LAN admission on BLE connection events, live BLE feature activity and feature demand while Android is foreground and interactive.

---

## 5. Encrypted Liveness & BLE Session Renewal

- **Encrypted Liveness:** HELLO/ACK negotiation and Android-initiated PING/PONG after 60 seconds without authenticated activity, with monotonic deadlines.
- **Event-Driven Idle:** Connection maintenance replaced earlier periodic 1-second polling loops with absolute monotonic deadline waits and transport events. Quiet deadline evaluation performs zero storage or Keystore/Keychain reads; full native identity and active-trust validation are enforced on authenticated operations.
- **Automatic BLE Renewal:** Fresh EDHOC at 55 minutes or the `2^20 - 1024` record threshold. The old session retires before reconnection; keys and counters are never resumed. Manual LAN requires another Connect after expiry; automatic LAN waits for a connection event or feature demand before establishing another session through authenticated BLE rendezvous.
- **Specifications & Decisions:** Keepalive envelopes, event-driven scheduling, and renewal thresholds are specified in the [Session Protocol Contract](protocol/session/README.md) and recorded in [ADR 0005 (EDHOC Secure Sessions)](docs/decisions/0005-edhoc-secure-sessions.md).

---

## Complete Reference Index

### Architecture Decisions (ADRs)

See the [decision index](docs/decisions/README.md) for shared foundations and feature-specific decisions.

### Protocol Contracts & Schemas
- [Protocol Overview & Active Contracts](protocol/README.md)
- [Public Device Identity Schema v1](protocol/schemas/identity.schema.json)
- [BLE Discovery Wire Format](protocol/bluetooth/README.md)
- [Pairing Bootstrap Protocol](protocol/pairing/README.md)
- [Secure Sessions & Record Channel](protocol/session/README.md)
- [LAN TCP Stream & mDNS Binding](protocol/lan/README.md)
- [Now Playing DATA](protocol/media/README.md)
- [Local File Transfer Protocol](protocol/transfer/README.md)

### Operational Guides & Implementation Roadmaps
- [Background BLE Connections Lifecycle](docs/BACKGROUND_CONNECTIONS.md)
- [Local Network Connections Specification](docs/LAN_CONNECTIONS.md)
- [Local File Transfer Feature Guide](docs/features/FILE_TRANSFER.md)
- [Authenticated Record Performance & Cost Model](docs/PERFORMANCE.md)
- [Design Guide & Palette](docs/design/DESIGN.md)
- [Project Roadmap & Verification Gates](docs/ROADMAP.md)

## Now Playing

One application-scoped MacPlaybackModel owns playback state, selection and observation leases; its MediaProcessBridge owns the packaged native adapter and MediaSessionLink owns subscriptions. Android controls this owner through one existing secured channel, preferring foreground LAN and using BLE otherwise. Background requires existing companion ownership. Artwork stays on LAN; channel replacement requires fresh state and never replays commands.

Mac output volume and verified selected-player volume are independently negotiated controls. See [feature behavior](docs/features/NOW_PLAYING.md), [media contracts](protocol/media/README.md) and the [playback decision](docs/decisions/features/now-playing/0009-remote-playback-presentation.md).

App Sandbox is disabled for the entire Mac app. Identity/trust paths, Keychain policy and session cryptography remain unchanged; [ADR 0007](docs/decisions/0007-macos-unsandboxed-playback-prototype.md) records the access and signing consequences.

## Local File Transfer

Local file transfer streams sequential multi-file batches (1..128 files) between trusted peers over authenticated LAN DATA records, using negotiated cumulative credit flow control (four 3,072-byte chunks on BLE; up to eight larger chunks on capable LAN), recipient offer approval, exclusive partial staging with incremental SHA-256 verification and checked finalization, full-duplex ACK pipelining, and presentation across Features and Home live-activity. See [feature behavior](docs/features/FILE_TRANSFER.md) and [transfer contracts](protocol/transfer/README.md). Android receive-storage instances share an injected IO dispatcher limited to one blocking operation at a time, with per-file mutex ownership. Mac receive storage remains actor-owned. Capable LAN senders qualify their large window with a small acknowledged probe and constrain delayed paths to at most two 65,536-byte chunks within peer credit, amortizing per-record validation under a 128-KiB fallback backlog cap. Recovery drains outstanding data before a fresh probe; source preparation and fully drained idle time do not count as submission-to-ACK delay. Each transfer owner queues authenticated chunks in a bounded FIFO, so shared feature delivery does not await their decode or storage work.

## Application DATA and source organization

Application-scoped BLE/LAN owners and nearby presence policy live under Connections. Native Bluetooth/LAN adapters and Session cryptography remain separate. Android manifest companion activity/service packages retain their original names; only their policy implementation moves. Existing identity, association and appearance persistence keys remain unchanged.

App registers media and transfer FeatureHandlers before DATA delivery. Android feature mutations are delivered on the main dispatcher; transport framing and cryptography remain off-main. FeatureDispatch publishes authenticated channel descriptors (instance ID, transport and peer identity/fingerprint), availability, retirement and capacity events. SecuredChannel rejects retired instances and bounds submissions to the authenticated channel profile; transport owners retain capacity preflight, readiness ordering, liveness priority and nonce ownership. Authenticated application delivery remains ordered. Transfer chunks enter a feature-owned bounded FIFO; unrelated handlers can proceed while its worker decodes and writes. A full FIFO suspends delivery without dropping valid chunks. Receiver resume verification shares the chunk FIFO through channel rebinding; cancellation and retirement invalidate pending work and fence active completions. Normal EOF and authenticated close drain accepted work for at most ten seconds. Generation checks reject retired callbacks. Handlers distinguish handled, queued, discarded and unrecognized DATA; unrecognized records retain connection-check fallback. Dispatch owns no transfer scheduler or sealed-record queue. Session DATA admission bounds unsealed callers, prioritizes standard-sized requests with bounded bulk turns, and removes cancelled waiters before nonce reservation. Cancellation remains effective through pre-seal native validation; nonce-owned submissions and post-write validation complete independently of producer cancellation or retire the session.

Native navigation types and Features destination content are separated from app shells. MacPlaybackModel is the sole playback authority; its owned process bridge fences native delivery by launch generation, and its session link coalesces logical snapshots before sealing. The fixture generator lives beside the media fixture; native and interchange scripts remain supported entry points. `python3 scripts/check-structure.py` checks dependency direction, local documentation links and explicit Xcode membership.

Approved Android reception uses document-tree grants and provider preflight. TransferService presents foreground-approved jobs through the existing owner; unapproved offers have no transfer background lease. Mac publication uses an exclusive same-filesystem link. Feature-owned recovery journals retain prepared jobs and verified prefixes across app restarts for 15 minutes. Native hard-link publication can be reconciled by file identity and SHA-256; ambiguous provider/copy publication requires confirmation. Coordinated LAN renewal remains unimplemented.

## Messages (SMS relay)

Application-scoped SMS owners register with FeatureDispatch and share authenticated LAN/BLE channels; the Mac never stores SMS content on disk and drops peer data when the last link retires, trust is removed or the app quits. Android remains the source of truth: an IO-dispatched store reads `content://mms-sms/conversations` with a direct `content://sms`/`content://mms` fallback, sanitizes provider rows, pages the thread list on a `(dateMillis, threadId)` cursor and history on a `(dateMillis, messageId)` cursor with a bounded provider window and in-memory byte-wise tie-break, and reports the subscription each message arrived on; a manifest `SMS_RECEIVED` receiver decodes PDUs through Android telephony and passes ordered parts to a pure event assembler. The Mac reassembles live and provider records through one fragment/digest path, paints thread cards and conversation pages as they arrive, shows an outgoing reply as a provisional row stamped with its submit time until the phone's result settles or removes it, retains local submit/receive ordering independently of carrier timestamps when provider copies replace observed rows, merges provider copies by a subscription-aware content key, and posts one notification per previously unknown live message with an inline reply clamped to the protocol bound, under per-phone notification and sound switches reachable from Settings → Messages and the panel's own gear. Search reuses the same bounded, cancellable page scan with the query as a `LIKE … ESCAPE '\'` match over SMS bodies and text/plain MMS parts and keeps no index on either side; replies use the phone's default SMS subscription unless the Mac sends an explicit active one from a SIM listing the phone answers on demand. See [Messages](docs/features/SMS.md) and the [wire contract](protocol/sms/README.md).

## Clipboard

Application-scoped native clipboard owners register with FeatureDispatch and share authenticated LAN/BLE channels. Clipboard v1 bounds text to 64 KiB, applies complete items to native clipboards, and shares in-memory deduplication/revision floors across transports. Automatic consent is credential-scoped and off by default; Android reads require actual input focus, while Mac observation respects native pasteboard access behavior. A separate device-local, default-off history owner persists eligible items with a local 20/50/100-item capacity through bounded atomic file operations off the presentation thread. Its saved collection preference is independent of its retained entries; pausing collection, restarting, identity reset and trust removal preserve history. Android text-selection and text Share-sheet actions pass literal text or URLs directly into manual delivery without clipboard reads. A system-bound Quick Settings tile opens a focused manual-read panel without activating observers. One process-local successful activity retains eligible text for five minutes, independently of saved history, with a bounded preview and full-item local Copy on Android Home and the Mac overview/companion. See [feature behavior](docs/features/CLIPBOARD.md) and the [wire contract](protocol/clipboard/README.md).
