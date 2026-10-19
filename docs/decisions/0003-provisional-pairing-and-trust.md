# ADR 0003 — Provisional pairing and trust

Status: accepted.

Mac is the BLE peripheral and invitation owner. Android is the central. QR is the default and manual six-digit entry is an equal supported alternative. Both require authenticated public-identity proof and explicit approval on both devices. Discovery is not trust.

QR contains an ephemeral rendezvous ID, 256-bit secret, and full SHA-256 identity commitment instead of the entire public identity record. This deliberate compacting preserves identity pinning; the record is exchanged privately after authentication. QR contains no Bluetooth address or peer UUID. Native P-256 ECDH, HKDF, role-separated HMAC confirmation and AES-GCM form the provisional QR bootstrap.

Six digits cannot safely authenticate ordinary ECDH with a checkable PIN-derived MAC: captured exchanges would permit offline guesses. Manual mode uses opaque-ke 4.0.1 (Ristretto255 / TripleDH-SHA512 / Argon2id 64 MiB, t=3, p=1). Registration runs entirely on the Mac in memory. The narrow shared Rust runtime is justified by identical security-critical PAKE behavior, not code-sharing aesthetics. MIT/Apache-2.0 upstream licenses are GPL-3.0 compatible; preserve their notices. The upstream 2021 NCC audit covered earlier versions, not this release or aniCe's integration.

No second numeric comparison screen is required. Authenticated peer details require explicit approval on both devices. Local pending records are atomically persisted before signed storage receipts; activation is local and does not pretend distributed atomicity. Interrupted completion is reported truthfully and fresh pairing repairs it. Private keys remain in existing native stores; public trust records live in no-backup application storage.

GATT writes and indications use bounded framing at every MTU, including 23. Larger MTU is an optimization. L2CAP and ongoing secure sessions are deferred. See protocol/pairing/README.md for exact wire definitions.

References: https://github.com/facebook/opaque-ke/tree/v4.0.1 and https://docs.rs/opaque-ke/4.0.1/opaque_ke/ . Independent integration review is required before production security claims.

The peripheral publication lifecycle is refined by [ADR 0004](0004-stable-ble-attribute-layout.md): a stable public characteristic layout with invitation-gated application access replaces conditional characteristic publication.
