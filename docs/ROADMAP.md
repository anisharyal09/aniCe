# aniCe Roadmap

| Phase | Scope | Status |
| :--- | :--- | :--- |
| **1 — Native app foundations** | Native shells, lifecycle, navigation, palette | Completed |
| **2 — Persistent device identity** | Protected local P-256 keys, public identity records | Implemented; verification gaps below |
| **3 — BLE discovery** | Nearby BLE compatibility check (Mac peripheral, Android central) | Implemented; verification gaps below |
| **4 — Pairing and trust** | QR/PIN authentication, mutual approval, peer trust store | Completed (4A–4D physically verified; release review tracked) |
| **5 — Authenticated secure sessions** | Authenticated key exchange (ECDH), encryption, replay defense | Planned |
| **6 — LAN transport and synchronization** | Local network transport and feature synchronization | Planned |


## Phase 4 milestones

- 4A: contracts, ADR 0003, ADR 0004, shared vectors.
- 4B: bounded bidirectional GATT, MTU fallback, cache invalidation recovery, physical over-the-air verification.
- 4C: native QR authentication, mutual consent, atomic peer trust journal.
- 4D: OPAQUE six-digit pairing via Rust PAKE bridge, trusted-device management (renaming, forgetting).

Phase 2 signed Mac Secure Enclave verification remains pending. Phase 3 and Phase 4 are physically verified on Samsung Android and macOS hardware; full minimum-OS runtime coverage (physical API 29/macOS 14 matrix) and formal external cryptographic review remain tracked release milestones.
