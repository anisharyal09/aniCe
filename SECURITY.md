# Security Policy

aniCe is a secure, cross-platform bridge connecting macOS and Android devices through peer-to-peer Bluetooth Low Energy (BLE) and Local Area Network (LAN) transports. Protecting user cryptographic keys, authentication state, and communication channels is paramount.

## Supported Versions

Only the latest release and the `main` development branch receive security updates:

| Version | Supported |
| :--- | :--- |
| `main` (trunk) | :white_check_mark: |
| Latest stable tag (`v*`) | :white_check_mark: |
| Older releases | :x: |

Official Mac builds and updates require Apple Silicon (`arm64`) and macOS 14 or newer. Intel Macs are not supported.

## Security Architecture & Scope

aniCe relies on explicit, defense-in-depth cryptographic primitives:
- **Device Identity:** P-256 keys in `AndroidKeyStore` with actual hardware/software protection reported, and actor-isolated macOS Keychain storage. Current Mac app builds use the development Keychain backend, not hardware isolation; the separate Secure Enclave backend requires appropriate signing and entitlements.
- **Pairing Bootstrap:** Ephemeral ECDH QR codes with SHA-256 fingerprint commitments, or 6-digit PIN pairing via an in-memory OPAQUE (`opaque-ke` 4.0.1) password-authenticated key exchange.
- **Session Transport:** RFC 9528 EDHOC (method 0, cipher suite 5: P-256, SHA-256, ChaCha20-Poly1305) authenticated record channels with directional AES-256-GCM encryption, monotonic sequence counters, and explicit rekeying schedules.
- **LAN Discovery & Transfer:** Anonymous DNS-SD advertisements (`_anice._tcp`) and mutual credential verification prior to admission.

### In Scope
- Cryptographic bypass or side-channel leakage in pairing, EDHOC handshake, or AES-GCM record processing.
- Unauthorized privilege escalation or access to peer device capabilities (SMS, notifications, clipboard, playback controls, file transfer).
- Arbitrary code execution, memory safety issues in native Rust bridge (`libanice_pairing.a`), Kotlin Android components, or Swift macOS modules.
- Man-in-the-Middle (MitM) attacks on BLE or LAN channels.

### Out of Scope
- Attacks requiring physical device disassembly, hardware fault injection, or JTAG access.
- Compromised host operating systems (e.g. rooted Android devices or compromised macOS kernels with root/SIP disabled) extracting keys from memory.
- Social engineering attacks tricking users into manually approving untrusted pairing requests or entering arbitrary PINs.

## Reporting a Vulnerability

If you discover a security vulnerability in aniCe, please **do not open a public issue**.

Instead, report it through one of the following private channels:
1. **GitHub Private Vulnerability Reporting:** Submit a report via the [Security Advisories](https://github.com/anisharyal09/aniCe/security/advisories/new) tab on GitHub.
2. **Security Contact:** Email the maintainer at `anisharyal09@gmail.com` with the subject `[SECURITY] aniCe Vulnerability Report`.

Please include:
- A clear description of the vulnerability and potential impact.
- Step-by-step reproduction instructions or a minimal Proof of Concept (PoC).
- Affected versions, platforms (macOS / Android), and transport layers (BLE / LAN).

### Response SLA
- **Initial acknowledgment:** Within 48 hours of receipt.
- **Assessment & reproduction:** Within 5 business days.
- **Fix development & coordinated release:** Target resolution within 30 days depending on complexity and severity.
- Credit will be attributed in the security advisory and release changelog (unless anonymity is requested).
