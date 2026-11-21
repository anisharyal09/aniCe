# Security Policy

aniCe connects Android and macOS over local Bluetooth and LAN. Report suspected vulnerabilities privately using the channels below.

## Supported Versions

Security fixes target `main` and the latest published beta or stable release; older builds are not maintained. A development version in source is not a published release.

Official Mac builds and updates require Apple Silicon (`arm64`) and macOS 14 or newer. Android builds require Android 10 (API 29) or newer.

Compatibility is defined for these minimums, but runtime validation currently exercises newer OS baselines. Minimum-OS runtime coverage and an independent security review remain open.

## Security Architecture & Scope

Security boundaries:

- **Device Identity:** P-256 keys in `AndroidKeyStore` with actual hardware/software protection reported, and actor-isolated macOS Keychain storage. Current Mac app builds use the development Keychain backend, not hardware isolation; the separate Secure Enclave backend requires appropriate signing and entitlements.
- **Pairing Bootstrap:** Ephemeral ECDH QR codes with SHA-256 fingerprint commitments, or 6-digit PIN pairing via an in-memory OPAQUE (`opaque-ke` 4.0.1) password-authenticated key exchange.
- **Nearby comparison:** Provisional [method-3 SAS](protocol/pairing/SAS.md) uses committed P-256 exchange and deferred salted-identity openings. Users must compare all six digits and confirm on both screens. RSSI is only a UX filter; the application profile is not independently audited.
- **Session Transport:** RFC 9528 EDHOC (method 0, cipher suite 5: P-256, SHA-256, ChaCha20-Poly1305) authenticated record channels with directional AES-256-GCM encryption, monotonic sequence counters, and explicit rekeying schedules.
- **LAN Discovery & Transfer:** Authenticated BLE IPv4 locators with anonymous DNS-SD fallback (`_anice._tcp`); independent pinned EDHOC authentication and fresh directional record keys on every initial/renewed cryptographic session.

### In Scope

- Cryptographic bypass or side-channel leakage in pairing, EDHOC handshake, or AES-GCM record processing.
- Unauthorized privilege escalation or access to peer device capabilities (SMS, notifications, clipboard, playback controls, file transfer).
- Arbitrary code execution, memory safety issues in native Rust bridge (`libanice_pairing.a`), Kotlin Android components, or Swift macOS modules.
- Man-in-the-Middle (MitM) attacks on BLE or LAN channels.
- Release signing, update signature/version checks, archive extraction and rollback failures.

### Out of Scope

- Attacks requiring physical device disassembly, hardware fault injection, or JTAG access.
- Compromised host operating systems (e.g. rooted Android devices or compromised macOS kernels with root/SIP disabled) extracting keys from memory.
- Social engineering attacks tricking users into manually approving untrusted pairing requests or entering arbitrary PINs.

## Reporting a Vulnerability

If you discover a security vulnerability in aniCe, please **do not open a public issue**.

Instead, report it through one of the following private channels:

1. **GitHub Private Vulnerability Reporting:** Use the [Security Advisories form](https://github.com/anisharyal09/aniCe/security/advisories/new) if it is available for this repository.
2. **Security Contact:** If the form is unavailable, email the maintainer at [anish.creations.hq@gmail.com](mailto:anish.creations.hq@gmail.com?subject=%5BSECURITY%5D%20aniCe%20Vulnerability%20Report) with the subject `[SECURITY] aniCe Vulnerability Report`.

Please include:

- A clear description of the vulnerability and potential impact.
- Step-by-step reproduction instructions or a minimal Proof of Concept (PoC).
- Affected versions, platforms (macOS / Android), and transport layers (BLE / LAN).

### Handling reports

Include the affected version and platform, impact, and reproduction steps. The maintainer will assess the report and coordinate disclosure and a fix. Response times depend on availability; there is no guaranteed service-level agreement. Credit can be included in the advisory unless you prefer anonymity.

### Current limits

BLE advertisements and DNS-SD discovery are unauthenticated; direct LAN locators exchanged over an established encrypted BLE channel are authenticated routing hints, not credentials or LAN keys. Trust is established during pairing, and each LAN socket/renewed cryptographic session independently authenticates the full pinned credential. The Mac app is unsandboxed, uses development Keychain storage and does not claim Secure Enclave isolation. Its current release pipeline uses a self-signed certificate, without Apple notarization. Peer feature content stays local; update checks and downloads contact GitHub.

Automated security analysis is one check, not evidence of an independent cryptographic audit. See [architecture](ARCHITECTURE.md) for ownership and trust boundaries.

### Dependency-review limit

The locked `opaque-ke 4.0.1` / `voprf 0.5.0` graph includes `crypto-bigint 0.5.5` through `elliptic-curve 0.13.8`, covered by [RUSTSEC-2026-0387](https://rustsec.org/advisories/RUSTSEC-2026-0387.html). aniCe's selected Ristretto255 OPRF and TripleDH use `curve25519-dalek` scalars/points; the affected big-integer operations have not been identified on that selected path. This source inspection is not a side-channel audit or a clean dependency scan. Keep the advisory visible and track a compatible upstream fix; forcing `crypto-bigint 0.7.6` into the older trait graph or switching to a prerelease PAKE library is not a validated remediation.
