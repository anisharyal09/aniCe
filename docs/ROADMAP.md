# aniCe Roadmap

| Phase | Scope | Status |
| :--- | :--- | :--- |
| **1 — Native app foundations** | Native shells, lifecycle, navigation, palette | Implemented; user manual acceptance pending |
| **2 — Persistent device identity** | Protected local P-256 keys, public identity records | Implemented; verification gaps below |
| **3 — BLE discovery** | Nearby BLE compatibility check (Mac peripheral, Android central) | Implemented; verification gaps below |
| **4 — Pairing and trust** | QR/PIN authentication, mutual approval, peer trust store | Implemented; user manual/radio acceptance and security review pending |
| **5 — Authenticated secure sessions** | EDHOC authenticated key exchange, encryption, replay defense | Native handshake feasibility implemented; baseline runtime gate pending; record/BLE/UI integration deferred |
| **6 — LAN transport and synchronization** | Local network transport and feature synchronization | Planned |

User manual verification is pending for all implemented areas. Agent-run automated/native checks are recorded separately in the local [verification status](A&V/VERIFICATION_STATUS.md); they do not complete physical acceptance.

## Phase 5 milestones

- 5A: native method-0/suite-5 EDHOC, ADR 0005, deterministic CCS/CBOR/CDDL, strict DER/COSE adapters, independent Python oracle, three valid/21 invalid vectors. Agent-run native signing/exporter interchange passed on API 36/macOS 27.0.1 over ADB/process pipes; no BLE or user acceptance.
- 5A gate: API 29/macOS 14 native runtime coverage pending. See local [session verification](A&V/SESSION_VERIFICATION.md).
- 5B/5C: AES-GCM application records, shared GATT v2, readiness, lifecycle and explicit connection UI held at the feasibility gate. Physical BLE acceptance and independent integration security review remain separate requirements.

## Phase 4 milestones

- 4A: contracts, ADR 0003, ADR 0004, shared vectors.
- 4B: bounded bidirectional GATT, MTU fallback and cache invalidation recovery implemented; physical over-the-air acceptance pending.
- 4C: native QR authentication, mutual consent, atomic peer trust journal.
- 4D: OPAQUE six-digit pairing via Rust PAKE bridge, trusted-device management (renaming, forgetting).

Signed Mac Secure Enclave verification, discovery/pairing manual radio acceptance, minimum-OS runtime coverage and independent integration security review remain pending. Earlier debugging observations do not establish completed acceptance.
