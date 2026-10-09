# aniCe Roadmap

| Phase | Scope | Status |
| :--- | :--- | :--- |
| **1 — Native app foundations** | Native shells, lifecycle, navigation, palette | Implemented; UI and accessibility verification pending |
| **2 — Persistent device identity** | Protected local P-256 keys, public identity records | Implemented; verification gaps below |
| **3 — BLE discovery** | Nearby BLE compatibility check (Mac peripheral, Android central) | Implemented; verification gaps below |
| **4 — Pairing and trust** | QR/PIN authentication, mutual approval, peer trust store | Implemented; physical radio acceptance and security review pending |
| **5 — Authenticated secure sessions** | EDHOC authenticated key exchange, encryption, replay defense | Handshake, record channel, BLE lifecycle and UI controls implemented; radio verification, minimum-OS baseline, and security review pending |
| **6 — LAN transport and synchronization** | Local network transport and feature synchronization | Manual authenticated TCP implemented; native IPv4/scoped IPv6 interchange verified; packaged-app/coexistence/minimum-OS acceptance pending; synchronization deferred |

Automated unit and integration test suites validate core protocol contracts. Physical radio inspection, minimum-OS baseline coverage, and independent security review remain tracked as release gates.

## Phase 5 milestones

- 5A: native method-0/suite-5 EDHOC, ADR 0005, deterministic CCS/CBOR/CDDL, strict DER/COSE adapters, independent Python oracle, three valid/21 invalid vectors.
- Background connections: shared ownership, companion-owned nearby retry, Mac automatic availability, encrypted liveness and coordinated fresh-session renewal implemented. One automatic switch per device; Disconnect pauses recovery on that device. Authenticated peer closure preserves eligible nearby recovery on the other device. Android Release ownership remains gated pending current-build physical range/process/address/endurance acceptance. Foreground-service fallback and reboot recovery remain deferred. [Implementation boundary](BACKGROUND_CONNECTIONS.md).
- Baseline runtime coverage: API 29 and macOS 14 runtime verification remain pending.
- Idle work: ordinary Android identity reads avoid signing; creation/reset retain signing proof and requested signatures are verified. Secured maintenance uses one-second intervals while admission/readiness retain 200 ms. Regression tests and builds pass; matched before/after CPU measurements and current-build physical acceptance remain pending.
- 5B/5C: directional AES-GCM records, shared GATT v2, readiness, lifecycle and explicit connection UI implemented. Independent record fixtures, native test suites, and isolated interchange harnesses validate bidirectional 4,000-byte payloads and lifecycle cleanup. Mac supports shared allowed-device selection with full credential pinning.

## Phase 4 milestones

- 4A: contracts, ADR 0003, ADR 0004, shared vectors.
- 4B: bounded bidirectional GATT, MTU fallback and cache invalidation recovery implemented; physical over-the-air acceptance pending.
- 4C: native QR authentication, mutual consent, atomic peer trust journal.
- 4D: OPAQUE six-digit pairing via Rust PAKE bridge, trusted-device management (renaming, forgetting).

Signed Mac Secure Enclave verification, discovery/pairing manual radio acceptance, minimum-OS runtime coverage and independent integration security review remain pending. Earlier debugging observations do not establish completed acceptance.

## LAN transport increment

Manual LAN discovery, native TCP framing, fresh EDHOC/readiness, independent liveness and transport controls coexist with BLE for one pinned peer. Android owns LAN only while a presentation is started; Mac shares one explicit listener/session across its window and companion. Legacy NSD serialization and scoped IPv6 binding are enforced. [Implementation and acceptance](LAN_CONNECTIONS.md) · [Wire contract](../protocol/lan/README.md).
