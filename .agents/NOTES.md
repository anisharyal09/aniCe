# Unresolved matters

Notes are not architectural decisions. Resolve these through concrete requirements and record the resulting decisions in appropriate human documentation.

- Final minimum Android and macOS versions. Android API 29 / Android 10 and macOS 14 are provisional foundation baselines. Automated verification covers API 36 / macOS 15; physical radio acceptance and minimum-OS native runtime validation remain open.
- Secure-session native runtime feasibility on API 29/macOS 14 remains pending. ADR 0005 settles EDHOC method 0 / suite 5, mandatory message 4, deterministic CCS, strictly pinned trust and directional exporter-derived AES-256-GCM records. Handshake and record/BLE/UI integration are implemented; minimum-OS runtime evidence remains outstanding. No re-keying, resumption or background reconnect in this profile.
- BLE session integration contract keeps Mac peripheral / Android central and ADR 0004 UUIDs, adds v2 fragmentation and explicit admission/readiness. LAN topology and negotiation remain open.
- Exact LAN transport and network framing/serialization (Phase 6).
- Signed Mac data-protection Keychain/Secure Enclave verification and eventual development-to-distribution identity migration. Current builds use the development Keychain backend with local ad-hoc code signing; prompt-free rebuilt-binary access remains unresolved; never silently change backend or identity after a storage/signing error.
- Shared Rust usage beyond pairing. Ephemeral in-memory PAKE justified `core/rust/pairing`; session cryptography is native Kotlin/Swift under ADR 0005. LAN runtime choices remain open.
- Platform feasibility and permissions for automatic background clipboard sharing and future integrations.

- Comprehensive physical radio acceptance remains incomplete. Interactive BLE connection, directional checks, Mac termination and Android lifecycle cleanup function on API 36; multi-device concurrency and minimum-OS validation remain pending.
- Complete handshake/factory/durable-storage and transport lifecycle fault matrices remain open; existing component faults and negative fixtures provide partial coverage.

- Notification-free companion ownership of the Mac peripheral remains a physical feasibility gate. Basic BLE screen-navigation retention is verified; exploratory background use lacks recorded scenario/duration. Locked-screen/Recents traffic, address rotation, OS binding, process/range recovery and battery behavior require measured evidence. Keep production automatic operation disabled; later application controls use CDDL as the authoritative CBOR contract.
