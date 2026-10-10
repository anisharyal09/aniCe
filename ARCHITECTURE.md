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
- **Directional Record Channel:** Exporter-derived AES-256-GCM keys, strict ordered 64-bit counters, a 4,000-byte plaintext bound, one-hour lifetime, and a hard limit of `2^20` records per direction. AES-GCM is aniCe's application profile; EDHOC suite 5 uses ChaCha20-Poly1305.
- **Encrypted Readiness:** Strict `ready` / `readyAck` handshake completion before any application payload can be submitted.
- **Specifications & Decisions:** Detailed wire envelopes, CBOR structures, and crypto derivation rules are specified in the [Session Protocol Contract](protocol/session/README.md), recorded in [ADR 0005 (EDHOC Secure Sessions)](docs/decisions/0005-edhoc-secure-sessions.md), and tested against [Session Test Vectors](protocol/test-vectors/session/).

---

## 4. Independent BLE & LAN Transports

- **BLE Transport:** Unauthenticated 20-byte compatibility discovery and bounded GATT v2 session framing. Mac is peripheral; Android is central. Opt-in Android companion ownership supplies background BLE lifetime in supported Debug builds.
  - Contract: [BLE Discovery Wire Format](protocol/bluetooth/README.md)
  - Lifecycle: [Background BLE Connections](docs/BACKGROUND_CONNECTIONS.md)
  - Decisions: [ADR 0002 (BLE Discovery)](docs/decisions/0002-provisional-ble-discovery.md) · [ADR 0004 (GATT Layout)](docs/decisions/0004-stable-ble-attribute-layout.md)
  - Vectors: [`discovery-vectors.json`](protocol/test-vectors/discovery-vectors.json)
- **LAN Transport:** Anonymous Bonjour/NSD discovery (`_anice._tcp`) and a five-byte TCP frame header with bounded envelopes. Android connects over Wi-Fi; Mac accepts local connections. LAN currently carries connection checks, with the same 4,000-byte record bound as BLE.
  - Contract: [LAN Binding Contract](protocol/lan/README.md)
  - Lifecycle: [Independent LAN Connections](docs/LAN_CONNECTIONS.md)
  - Decisions: [ADR 0006 (Independent LAN Sessions)](docs/decisions/0006-independent-lan-sessions.md)
  - Vectors: [`lan-vectors.json`](protocol/test-vectors/lan/lan-vectors.json)
- **Concurrent Coexistence:** Simultaneous BLE and LAN sessions to the same pinned peer with independent session keys, nonces, and counters under a shared reservation lock.
- **Ownership:** Android manual LAN closes on final activity stop, screen lock or network loss. Mac window and menu companion share its LAN owner; sleep and Quit retire it. Automatic LAN reconnection and feature routing are deferred.

---

## 5. Encrypted Liveness & BLE Session Renewal

- **Encrypted Liveness:** HELLO/ACK negotiation and Android-initiated PING/PONG after 60 seconds without authenticated activity, with monotonic deadlines.
- **Event-Driven Idle:** BLE and LAN connection maintenance uses absolute monotonic deadline waits and transport events instead of periodic polling. Quiet deadline evaluation performs zero storage or Keystore/Keychain reads; full native identity and active-trust validation are enforced on authenticated operations.
- **Automatic BLE Renewal:** Fresh EDHOC at 55 minutes or the `2^20 - 1024` record threshold. The old session retires before reconnection; keys and counters are never resumed. Manual LAN requires another Connect after expiry.
- **Specifications & Decisions:** Keepalive envelopes, event-driven scheduling, and renewal thresholds are specified in the [Session Protocol Contract](protocol/session/README.md) and recorded in [ADR 0005 (EDHOC Secure Sessions)](docs/decisions/0005-edhoc-secure-sessions.md).

---

## Complete Reference Index

### Architecture Decisions (ADRs)
- [ADR 0001: Platform-Native Device Identity](docs/decisions/0001-provisional-device-identity.md)
- [ADR 0002: Provisional BLE Discovery](docs/decisions/0002-provisional-ble-discovery.md)
- [ADR 0003: Provisional Pairing and Trust Establishment](docs/decisions/0003-provisional-pairing-and-trust.md)
- [ADR 0004: Stable BLE Attribute Layout](docs/decisions/0004-stable-ble-attribute-layout.md)
- [ADR 0005: EDHOC Secure Sessions & Directional Record Channel](docs/decisions/0005-edhoc-secure-sessions.md)
- [ADR 0006: Independent LAN Sessions Alongside BLE](docs/decisions/0006-independent-lan-sessions.md)

### Protocol Contracts & Schemas
- [Protocol Overview & Active Contracts](protocol/README.md)
- [Public Device Identity Schema v1](protocol/schemas/identity.schema.json)
- [BLE Discovery Wire Format](protocol/bluetooth/README.md)
- [Pairing Bootstrap Protocol](protocol/pairing/README.md)
- [Secure Sessions & Record Channel](protocol/session/README.md)
- [LAN TCP Stream & mDNS Binding](protocol/lan/README.md)

### Operational Guides & Implementation Roadmaps
- [Background BLE Connections Lifecycle](docs/BACKGROUND_CONNECTIONS.md)
- [Local Network Connections Specification](docs/LAN_CONNECTIONS.md)
- [Design Guide & Palette](docs/design/DESIGN.md)
- [Project Roadmap & Verification Gates](docs/ROADMAP.md)
