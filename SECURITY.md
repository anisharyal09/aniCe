# Security Policy

aniCe connects Android and macOS over local Bluetooth and LAN. Report suspected vulnerabilities privately using the channels below.

## Supported Versions

The first public beta is being prepared. Security fixes target `main` and the latest published beta or stable release; older builds are not maintained. A development version in source is not a published release.

Official Mac builds and updates require Apple Silicon (`arm64`) and macOS 14 or newer. Intel Macs are not supported.

## Security Architecture & Scope

Security boundaries:

- **Device Identity:** P-256 keys in `AndroidKeyStore` with actual hardware/software protection reported, and actor-isolated macOS Keychain storage. Current Mac app builds use the development Keychain backend, not hardware isolation; the separate Secure Enclave backend requires appropriate signing and entitlements.
- **Pairing Bootstrap:** Ephemeral ECDH QR codes with SHA-256 fingerprint commitments, or 6-digit PIN pairing via an in-memory OPAQUE (`opaque-ke` 4.0.1) password-authenticated key exchange.
- **Session Transport:** RFC 9528 EDHOC (method 0, cipher suite 5: P-256, SHA-256, ChaCha20-Poly1305) authenticated record channels with directional AES-256-GCM encryption, monotonic sequence counters, and explicit rekeying schedules.
- **LAN Discovery & Transfer:** Anonymous DNS-SD advertisements (`_anice._tcp`) and mutual credential verification prior to admission.

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
2. **Security Contact:** If the form is unavailable, email the maintainer at `anish.creations.hq@gmail.com` with the subject `[SECURITY] aniCe Vulnerability Report`.

Please include:

- A clear description of the vulnerability and potential impact.
- Step-by-step reproduction instructions or a minimal Proof of Concept (PoC).
- Affected versions, platforms (macOS / Android), and transport layers (BLE / LAN).

### Handling reports

Include the affected version and platform, impact, and reproduction steps. The maintainer will assess the report and coordinate disclosure and a fix. Response times depend on availability; there is no guaranteed service-level agreement. Credit can be included in the advisory unless you prefer anonymity.

### Current limits

Discovery is unauthenticated; trust is established during pairing and authenticated session setup. System Bluetooth HID uses OS-managed authentication and encryption. The Mac app is unsandboxed, uses development Keychain storage and does not claim Secure Enclave isolation. Its current release pipeline uses a self-signed certificate, without Apple notarization. Peer feature content stays local; update checks and downloads contact GitHub.

Automated security analysis is one check, not evidence of an independent cryptographic audit. See [architecture](ARCHITECTURE.md) for ownership and trust boundaries.
