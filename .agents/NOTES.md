# Unresolved matters

Notes are not architectural decisions. Resolve these through concrete requirements and record the resulting decisions in appropriate human documentation.

- Final minimum Android and macOS versions. Android API 29 / Android 10 and macOS 14 are provisional foundation baselines, physically verified on Samsung A34 / macOS 27; full legacy OS hardware matrix validation remains open.
- Authenticated secure session suite (Phase 5 / next). Pairing provisionally selects P-256 ECDH, AES-256-GCM, and OPAQUE 4.0.1 (ADR 0003 / ADR 0004). Ongoing session key exchange, directional AEAD framing, replay windows, and re-keying rotation remain to be settled in next phase.
- BLE topology beyond pairing. Discovery and pairing use Mac peripheral / Android central with stable GATT layout (ADR 0004); bidirectional session and LAN negotiation remain open.
- Exact LAN transport and network framing/serialization (Phase 6).
- Signed Mac data-protection Keychain/Secure Enclave verification and eventual development-to-distribution identity migration. Current ad-hoc builds explicitly use the development Keychain backend; never silently change backend or identity after a storage/signing error.
- Shared Rust usage. Ephemeral in-memory PAKE justified `core/rust/pairing`; whether session cryptography or LAN transport warrants further Rust logic remains open.
- Platform feasibility and permissions for automatic background clipboard sharing and future integrations.
