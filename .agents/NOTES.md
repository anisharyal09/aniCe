# Unresolved matters

Notes are not architectural decisions. Resolve these through concrete requirements and record the resulting decisions in appropriate human documentation.

- Final minimum Android and macOS versions. Android API 29 / Android 10 and macOS 14 are provisional foundation baselines. Agent-run automated native evidence covers Samsung API 36 / macOS 27 via ADB/process pipes; user manual/radio acceptance and minimum-OS native runtime validation remain open.
- Secure-session native runtime feasibility on API 29/macOS 14 remains pending. ADR 0005 settles EDHOC method 0 / suite 5, mandatory message 4, deterministic CCS, strictly pinned trust and directional exporter-derived AES-256-GCM records. The implemented handshake has passed API 36/macOS 27.0.1 native interchange; record/BLE/UI integration is implemented at the user's 2026-10-08 request; minimum-OS runtime evidence remains outstanding. No re-keying, resumption or background reconnect in this profile.
- BLE session integration proceeded at the user's request with baseline evidence still outstanding. The session contract keeps Mac peripheral / Android central and ADR 0004 UUIDs, adds v2 fragmentation and explicit admission/readiness. LAN topology and negotiation remain open.
- Exact LAN transport and network framing/serialization (Phase 6).
- Signed Mac data-protection Keychain/Secure Enclave verification and eventual development-to-distribution identity migration. Current builds explicitly use the development Keychain backend; the user declined certificate setup and local ad-hoc signing is restored as the default; prompt-free rebuilt-binary access remains unresolved; never silently change backend or identity after a storage/signing error.
- Shared Rust usage beyond pairing. Ephemeral in-memory PAKE justified `core/rust/pairing`; session cryptography is native Kotlin/Swift under ADR 0005. LAN runtime choices remain open.
- Platform feasibility and permissions for automatic background clipboard sharing and future integrations.

- Comprehensive manual acceptance remains incomplete. On 2026-10-08 the user reported working connection, send/receive, Mac Quit and Android background cleanup and approved the minimal phone layout. Retain these named reports as passes; latest UI/reason/device-selection, physical multi-phone and minimum-OS checks remain pending. Follow local `docs/A&V/VERIFICATION_STATUS.md`.
- Complete handshake/factory/durable-storage and transport lifecycle fault matrices remain open; existing component faults and negative fixtures are partial coverage.
