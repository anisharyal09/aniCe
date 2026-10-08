# aniCe trusted-device session profile v1

Status: native handshake feasibility implemented; application records and BLE binding specified for gated integration.

## Authentication profile

Android is EDHOC Initiator I; Mac is Responder R. RFC 9528 method is `0`; selected suite is integer `5`. Other methods, suite lists, fallback and all EAD are rejected. Message 4 is mandatory. Correlation belongs to one exclusive transport candidate and its operation generation, not to a stable advertised device identifier.

Primitives: P-256 ECDH, ES256, SHA-256, HMAC-SHA256/HKDF, ChaCha20-Poly1305 with 32-byte keys, 12-byte nonces and 16-byte tags. The identity service signs complete COSE `Sig_structure` bytes and hashes them exactly once. Its DER interface is unchanged; session signatures are fixed-width 32-byte big-endian `r || s`, with `1 <= r,s < P-256 order`.

Ephemeral public keys `G_X`, `G_Y` are 32-byte x coordinates. Import validates the curve point and reconstructs even y; native ECDH returns the shared point's x coordinate. Both signs of an imported point produce that same shared x coordinate. Private scalar operations stay in JCA/CryptoKit.

`C_I` and `C_R` are fresh eight-byte CSPRNG byte strings. This fixed length avoids one-byte integer connection-ID compaction. A malformed/unsupported candidate aborts; it cannot downgrade into pairing.

## Credentials

`kid = SHA256(uncompressedPublicPoint65)` as 32 raw bytes, not hexadecimal text. Both sides reconstruct credentials from validated local/pinned public identities:

```cbor-diag
CRED_x = {
  2: deviceId,                         / canonical UUID-v4 text subject /
  8: {1: {                            / cnf: COSE_Key /
    1: 2,                             / kty: EC2 /
    3: -7,                            / alg: ES256 /
    -1: 1,                            / crv: P-256 /
    -2: X,                            / 32-byte x coordinate /
    -3: Y                             / 32-byte y coordinate /
  }}
}
ID_CRED_x = {4: kid_x}
```

Deterministic credential CBOR excludes `deviceName`, protection labels and pairing dates. `ID_CRED_x` is the complete map in MAC/signature inputs; its compact byte-string representation appears only in message plaintexts. Trust lookup requires exactly one active peer with the fingerprint, correct platform and current local fingerprint. The Initiator additionally matches selected device ID and public key. No key or credential supplied by a connection replaces local trust. Pending records confer no session access.

## CBOR and exact handshake inputs

Use RFC 8949 deterministic length-first map ordering. Limits: 4,096 encoded bytes, 512 decoded items, eight nested container levels. Map keys are scalar integers, byte/text strings or booleans; compound keys, indefinite lengths, duplicate/unordered keys, nonminimal integers/lengths, malformed UTF-8, tags, floats, null, excess nesting and trailing data are rejected. Integer values are limited to signed 64-bit because all accepted profile fields fit that range.

`cbor(x)` encodes one item. `seq(x,...)` concatenates encoded items without an array wrapper. `H` is SHA-256. Complete handshake payloads are CBOR sequences with exactly these items:

| Message | Direction | Items | Encoded bytes |
| --- | --- | --- | --- |
| 1 | I → R | `0, 5, G_X, C_I` | 45 |
| 2 | R → I | `G_Y || CIPHERTEXT_2` as one bstr | 143 |
| 3 | I → R | `CIPHERTEXT_3` as one bstr | 118 |
| 4 | R → I | `CIPHERTEXT_4` as one bstr | 17 |

For method 0, `PRK_3e2m = PRK_4e3m = PRK_2e = HMAC-SHA256(TH_2, G_XY)`.

```text
KDF(PRK, label, context, L) = HKDF-Expand(PRK, seq(label, context as bstr, L), L)
TH_2 = H(seq(G_Y, H(message_1)))
context_2 = seq(C_R, ID_CRED_R, TH_2, CRED_R)
MAC_2 = KDF(PRK_3e2m, 2, context_2, 32)
SignInput_2 = cbor(["Signature1", cbor(ID_CRED_R), seq(TH_2, CRED_R), MAC_2])
PLAINTEXT_2 = seq(C_R, kid_R, signature_R)
KEYSTREAM_2 = KDF(PRK_2e, 0, TH_2, len(PLAINTEXT_2))
CIPHERTEXT_2 = PLAINTEXT_2 XOR KEYSTREAM_2
TH_3 = H(cbor(TH_2) || PLAINTEXT_2 || cbor(CRED_R))
context_3 = seq(ID_CRED_I, TH_3, CRED_I)
MAC_3 = KDF(PRK_4e3m, 6, context_3, 32)
SignInput_3 = cbor(["Signature1", cbor(ID_CRED_I), seq(TH_3, CRED_I), MAC_3])
PLAINTEXT_3 = seq(kid_I, signature_I)
K_3 = KDF(PRK_3e2m, 3, TH_3, 32)
IV_3 = KDF(PRK_3e2m, 4, TH_3, 12)
A_3 = cbor(["Encrypt0", h'', TH_3])
TH_4 = H(cbor(TH_3) || PLAINTEXT_3 || cbor(CRED_I))
K_4 = KDF(PRK_4e3m, 8, TH_4, 32)
IV_4 = KDF(PRK_4e3m, 9, TH_4, 12)
A_4 = cbor(["Encrypt0", h'', TH_4])
PLAINTEXT_4 = empty byte sequence
PRK_out = KDF(PRK_4e3m, 7, TH_4, 32)
PRK_exporter = KDF(PRK_out, 10, h'', 32)
```

AEAD ciphertexts contain the ciphertext followed by the tag and omit the nonce. Message-4 plaintext must be empty. Completion exposes only a derived exporter operation; the Initiator cannot export before verifying message 4. The Responder can export after authenticating message 3 and composing message 4. Neither completion state implies application readiness or remote delivery.

The engines permit a single operation. Repeated/unexpected messages terminate the attempt. A signing result must match the initial device ID, fingerprint, key and operation generation. Recheck active trust and local identity before completion/export. The 30-second handshake deadline is monotonic; callers must schedule `checkDeadline` to erase idle attempts, not rely only on incoming messages.

## Errors and privacy

Typed local failures: `malformed`, `unsupportedProfile`, `untrustedPeer`, `authentication`, `state`, `cancelled`, `expired`. Native identity/storage/provider errors retain their original typed failure and retire the handshake.

Accepted EDHOC error sequences: `(1, tstr <= 64 UTF-8 bytes)`, `(2, 5)`, `(3, true)`. Error code zero, unknown codes and extra data are rejected. Received errors are fatal with no suite retry. Outgoing generic error is `(1, "Handshake failed")`; callers do not emit credential identifiers in errors. During an established application session, handshake envelopes/errors are invalid.

Credentials are protected against passive handshake observation. This is not anonymity: an active initiator can obtain responder credential information, and radio identifiers, lengths and timing remain observable. No stable identity appears in discovery or advertising. No handshake/application key is persisted or logged. Buffer overwrite and object release are best effort on Swift/JVM.

## Exporter and record profile — integration pending

Exporter label `32768` is private-use. Context bytes are deterministic CBOR:

```text
cbor(["aniCe session", 1, cbor(CRED_I) as bstr, cbor(CRED_R) as bstr, direction, purpose])
direction = 1 (I→R), 2 (R→I), 0 (session-id only)
purpose = "key" (32 bytes), "iv" (12 bytes), "session-id" (32 bytes)
output = KDF(PRK_exporter, 32768, context, outputLength)
```

Planned AES-256-GCM record: `version:u8=1 | kind:u8 | sequence:u64BE | ciphertextLength:u32BE | ciphertext | tag:16B`. Kind: `1 ready`, `2 readyAck`, `3 data`, `4 close`. Control plaintexts are empty. Data plaintext is at most 4,000 bytes. Length excludes the tag. AAD is `header14 || sessionID32 || direction1`; nonce is `IVBase12 XOR (00000000 || sequence64BE)`.

Directional counters start at zero. Receive only the exact next value and advance after authentication. Reserve/burn send sequence before encryption; failure after reservation closes the session. Do not reseal or roll back. Ready/readyAck consume the initial sequences. Initiator readiness requires verified readyAck; responder readiness requires verified ready and successful readyAck submission. Ten-second readiness, 120-second idle, one-hour age and `2^20` records per direction are hard bounds. Limits close the session; no in-place key update.

## BLE binding — integration pending

The published service and three characteristic UUIDs remain as in pairing v1. Session v2 fragmentation header is `version:u8=2 | messageId:u32BE | totalLength:u16BE | offset:u16BE`. IDs start at zero per direction and increment per logical message, never wrap. Fragments are contiguous; logical length is 1..4096. MTU 23 gives 11 payload bytes per fragment. Reassembly deadline is ten seconds from first fragment, without extension.

Each logical payload is `kind:u8 || payload`; kinds `1..4` carry unmodified EDHOC messages, `5` EDHOC error, `6` application record. Mode determines accepted fragmentation version; never sniff a fragment into another mode. One candidate, one receive buffer and at most eight queued logical messages/32 KiB are allowed. Backpressure is returned before sequence reservation. Queue budget includes sealed records/envelopes retained until submission completes.

Mac admission window: 120 seconds, five failed candidates maximum. Android scan: 15 seconds. Candidate admission stops advertising; connection traffic must not depend on advertising confirmation afterward. A failed candidate may resume advertising within the original window. Exclusive idle/discovery/pairing/session modes share one owner. Teardown is bounded to two seconds; Mac retires application access when Core Bluetooth cannot force disconnection.

References: [RFC 9528](https://www.rfc-editor.org/rfc/rfc9528.html), [RFC 9529](https://www.rfc-editor.org/rfc/rfc9529.html), [ADR 0005](../../docs/decisions/0005-edhoc-secure-sessions.md).
