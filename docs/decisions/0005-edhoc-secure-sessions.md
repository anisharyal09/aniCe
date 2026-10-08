# ADR 0005 — EDHOC trusted-device sessions

Status: accepted for native feasibility implementation; transport integration gated.

## Decisions

- Android initiates; Mac responds. Both require an active pinned trust record belonging to the current local identity. Android pins the selected Mac's device ID, fingerprint and public key.
- Use RFC 9528 method 0 and suite 5, deterministic CBOR, referenced CCS credentials, mandatory message 4 and no EAD. Existing P-256 identity keys authenticate COSE ES256 signing inputs through their native protected signing services. DER conversion exists only at the session boundary.
- Native Kotlin/JCA and Swift/CryptoKit/Security implementations perform ephemeral P-256 ECDH, SHA-256, HMAC/HKDF and ChaCha20-Poly1305. No private identity-key export or new production crypto dependency is introduced.
- Connection IDs are fresh eight-byte random values. Credential IDs are encrypted 32-byte SHA-256 fingerprints. Credentials bind canonical device IDs and complete public keys, excluding display names.
- Message 2 follows EDHOC's XOR keystream construction. Messages 3 and 4 use the suite's ChaCha20-Poly1305 construction. No pairing key, PIN, receipt or QR secret becomes a reusable session key.
- Application records will use exporter-derived directional AES-256-GCM keys under the separate aniCe record profile. EDHOC suite 5's default application algorithm remains ChaCha20-Poly1305; aniCe explicitly specifies AES-GCM for its application and does not describe this record protocol as OSCORE.
- All attempts use fresh ephemeral keys. Resume and in-place key update are excluded. Session secrets remain in memory; cleanup on managed/copy-on-write runtimes is best effort.

## Gate and implementation boundary

The initial implementation includes the contract, independent suite-5 oracle, native handshake engines, conformance tests and isolated native signature interchange. It does not expose session controls or enable GATT session access.

Record/transport integration requires conformance, Android–Mac interoperability, protected-key signing and API 29/macOS 14 runtime evidence. Missing baseline hardware evidence remains pending. No protocol substitution follows a failed feasibility check.

Trust journals and pairing/discovery contracts retain their existing formats and access rules. A separate integration change will implement session operating modes and update ADR 0004 after this gate passes.

References: [RFC 9528](https://www.rfc-editor.org/rfc/rfc9528.html), [RFC 9529](https://www.rfc-editor.org/rfc/rfc9529.html), [session application profile](../../protocol/session/README.md), local [verification](../A&V/SESSION_VERIFICATION.md).
