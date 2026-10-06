# Unresolved matters

Notes are not architectural decisions. Resolve these through concrete requirements and record the resulting decisions in appropriate human documentation.

- Final minimum Android and macOS versions. Android API 29 / Android 10 and macOS 14 are provisional foundation baselines, not product freezes.
- Full pairing/session cryptographic suite. Local identity provisionally selects P-256 ECDSA/SHA-256 and DER signatures; see the identity ADR. Authenticated key exchange, encryption, replay protection, and rotation remain open.
- BLE topology.
- Exact LAN transport.
- Network serialization/framing and model-generation approach. Phase 2 public identity uses JSON Schema; it does not decide the network protocol.
- Signed Mac data-protection Keychain/Secure Enclave verification and eventual development-to-distribution identity migration. Current ad-hoc builds explicitly use the development Keychain backend; never silently change backend or identity after a storage/signing error.
- The point at which shared runtime needs justify Rust.
- Platform feasibility and permissions for automatic clipboard sharing and call-related integrations.
