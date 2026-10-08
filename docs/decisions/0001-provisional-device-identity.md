# 1. Provisional Device Identity Architecture

Date: 2026-10-06  
Status: **Provisional** (revisable upon pairing and secure session protocol design)

## Context

aniCe connects Android and macOS devices local-first without mandatory cloud accounts. To establish persistent trust, devices must pair once, recognize each other securely across network reconnections, and authenticate session handshakes.

The repository initially left identity algorithms and transport choices open. Local identity now needs a concrete, testable implementation; pairing and session security remain separate decisions.

## Decision

We establish a provisional local device identity foundation adhering to the following choices:

1. **Algorithm Suite:**
   - Elliptic Curve **P-256** (secp256r1 / NIST P-256) for identity signing keys.
   - **SHA-256** for message digests and identity fingerprinting.
   - **ASN.1 DER** signature encoding (`SHA256withECDSA` on Android, `kSecKeyAlgorithmECDSASignatureMessageX962SHA256` on macOS). This matches native platform keystore hardware implementations out-of-the-box without custom serialization glue or external dependencies.

2. **Public Identity & Fingerprint Contract:**
   - Canonical 65-byte ANSI X9.63 uncompressed point (`0x04 || X || Y`), Base64-encoded. Android coordinates are normalized to 32 bytes big-endian; macOS uses `SecKeyCopyExternalRepresentation` / `x963Representation`.
   - Fingerprint is the raw SHA-256 hash of the 65-byte uncompressed point, represented as 64 lowercase hexadecimal characters.
   - Schema versioning: Explicitly labeled `"identitySchemaVersion": 1` in `protocol/schemas/identity.schema.json`, independent of future transport or capability versions.

3. **Platform Protected Storage:**
   - **Android:** Android Keystore (`AndroidKeyStore` provider). Keys are generated without user authentication / biometric prompts (`setUserAuthenticationRequired(false)`) to permit background and proximity reconnection without UI interruption. Metadata is stored atomically under `context.noBackupFilesDir` to prevent cloud backup duplication.
   - **macOS:** Security framework `SecKey` references. Current builds explicitly select a development login Keychain backend with atomic public metadata in the app container. It provides neither hardware isolation nor a guarantee against Keychain migration. The separate signed backend uses data-protection Keychain, synchronization disabled, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and Secure Enclave when available. Its native verification requires configured signing and entitlements. Application code never exports or serializes private keys; software-backed storage is not a claim that key bytes never enter system memory.

4. **Lifecycle & Atomic Reset:**
   - Key aliases are immutable (Android: `anice.identity.v1.<uuid>`; Mac: the selected backend namespace plus a generation UUID). Aliases are never renamed.
   - Key creation and reset follow a two-phase journal (`pending` $\to$ validate $\to$ atomic commit to `active` $\to$ `cleanup` retired alias).
   - Identity is never silently regenerated on transient storage failure. Transient failures surface typed `IdentityException` / `IdentityError` states to the user.

## Consequences

### Positive
- **No Third-Party Crypto Dependencies:** Signing and verification use native platform frameworks. Hardware protection is preferred and reported from the actual backend; platform-protected fallback remains supported.
- **Deterministic Cross-Platform Verification:** Public key normalization and ASN.1 DER signatures verify cleanly between Android Keystore and macOS Keychain.
- **Auditability & Safety:** Serialized lifecycle operations and an atomic active-record switch preserve the committed identity through interruption. Retired-key cleanup is retryable; interrupted cleanup may temporarily leave an older key stored.

### Trade-offs & Future Revisions
- **Provisional Status:** If pairing protocols (Phase 4) or secure session handshakes (Phase 5) demonstrate that Edwards curves (e.g. Ed25519) provide superior performance or smaller message sizes, this decision may be revised with an explicit migration path.
- **Display vs Trust:** Device names (e.g., "Pixel 9", "MacBook Pro") are display metadata only and do not establish cryptographic trust.
- **Identity lifetime:** Identity persists until explicit reset or storage removal. Mac Keychain items can outlive app deletion. Backend changes and future algorithm changes require an explicit migration/reset decision; storage errors never trigger fallback or replacement.
- **Legacy Keychain policy:** The legacy Mac generator requires the non-extractable setting at the top level. The backend inspects policy attributes without key data, exports only the public point, and preserves/rejects older exportable keys until explicit confirmed reset. This does not make development keys hardware isolated.
- **Deferred security:** A public record alone does not establish trust. Mutual authentication, signed transcripts, ephemeral session keys, encryption, replay resistance, revocation, BLE discovery, and QR onboarding are later phases.

## Development signing and access

Mac build configurations use Manual / Sign to Run Locally for account-free local development. Automatic Apple Development signing is optional. This does not change the development Keychain namespace or migrate its private key. Loading an existing identity validates metadata, public key and protection policy without a private signing challenge. Creation/reset prove signing access before commit; actual requested signatures are verified and denial preserves committed identity. Prompt-free signed rebuild behavior and signed Secure Enclave storage remain separate pending runtime evidence.
