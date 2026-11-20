<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Nearby numeric comparison — pairing method 3

Status: provisional application-layer SAS profile; independent integration review is required before production security claims. This is not Bluetooth bonding or the Bluetooth SMP protocol. QR (method 1) and OPAQUE PIN (method 2) are unchanged.

Physical release acceptance is pending: automated suites and native-provider fixtures pass, but real BLE completion, floating-card interaction, lock/sleep cancellation and immediate post-pair connection must still be verified on devices.

SAS means **Short Authentication String**. Users compare all six digits on their own two screens, then confirm on both. They do not enter a password. Discovery, RSSI, key confirmation and one device's approval do not establish trust.

## Transport and admission

Use the existing pairing service, bounded version-1 GATT fragmentation, length-prefixed `fields`, 4,096-byte messages and 32-KiB attempt traffic budget. Discovery flag `0x0001` optionally announces method-3 availability; unknown flags remain ignorable. Advertising still contains only generic compatibility data. Clients require the flag after reading discovery and never downgrade a selected numeric-comparison attempt to QR, PIN or an unauthenticated session.

The Mac owns one slot and admits at most five subscriptions per rolling 120-second interval, with at least ten seconds between admissions. The budget is global, not keyed by a forgeable locator. Dismissal suppresses new admission for 60 seconds. Explicit retries cannot erase these process-local limits. Availability may remain open; each subscription has 15 seconds to start, each exchange has 30 seconds, numeric comparison 60 seconds, and identity/proof/receipt completion is bounded. The total attempt is at most 120 seconds. Deadlines are monotonic. Lock, sleep, radio loss, Quit and Android foreground loss cancel it. Security deadlines use event-driven absolute waits; a visible countdown must not create a crypto/storage polling loop. Cancellation revokes an operation generation before suspended signing/storage work can publish further trust traffic.

## Commit and reveal

`role` is one byte: Android client `1`, Mac server `2`. All strings below are literal UTF-8, fields use uint32 big-endian lengths, and concatenated identities use their exact received JSON bytes. Native ephemeral keys are P-256; public points are the validated, uncompressed 65-byte X9.63 representation.

Each attempt creates fresh ephemeral keys, 32-byte random comparison nonces and 32-byte identity salts. Private keys and buffers are never persisted or logged.

```
IC(role) = SHA256(fields("aniCe sas identity v1", role, identitySalt, identityJSON))
C(role)  = SHA256(fields("aniCe sas commitment v1", 0x03,
                        rendezvous16, serverNonce32, role,
                        ephemeralPublic65, comparisonNonce32, IC(role)))
```

The identity salt stays secret until both comparison confirmations. No stable identity, fingerprint or device name is disclosed by these salted commitments.

| Type | Direction | Exact fields |
| --- | --- | --- |
| 1 query | client → server | none |
| 2 invitation | server → client | `0x03`, rendezvous16, serverNonce32 |
| 3 client commitment | client → server | `0x03`, rendezvous16, C(1)32 |
| 4 server commitment | server → client | serverNonce32, C(2)32 |
| 8 client reveal | client → server | clientPublic65, clientNonce32, IC(1)32 |
| 9 server reveal | server → client | serverPublic65, serverComparisonNonce32, IC(2)32 |
| 5 client finish | client → server | client key-confirmation MAC32 |
| 6 server finish | server → client | existing channel-confirmation MAC32 |

The client sends its reveal only after recording the server commitment. The server sends its reveal only after verifying the client commitment. Both verify the peer opening, reject identical/reflected ephemeral points and unexpected, repeated, out-of-order, missing or incorrectly sized fields. A failed opening retires the attempt. A new attempt must not reuse comparison material.

Canonical transcript, always in client/server order:

```
T = fields("aniCe pairing sas v1", 0x03, rendezvous, serverNonce,
           clientCommitment, serverCommitment, clientPublic, serverPublic,
           clientComparisonNonce, serverComparisonNonce,
           clientIdentityCommitment, serverIdentityCommitment)
H = SHA256(T)
K = HKDF-SHA256(ECDH, salt=H, info=fields("aniCe sas bootstrap v1", H), L=32)
```

Reuse the pairing channel's directional HKDF keys, AES-GCM counters, AAD and role-separated confirmations with this transcript. Client finish is `HMAC-SHA256(derive(K,"client-auth",H), T)`; server finish is the existing `HMAC-SHA256(derive(K,"channel-confirm",H), T)`.

## Six digits

For counter `i = 0,1,…`, compute `HMAC-SHA256(derive(K,"sas-digits",H), fields("aniCe sas digits v1", H, uint32BE(i)))`. Read the first four bytes as an unsigned big-endian integer `n`. If `n >= 4,294,000,000`, advance the counter. Otherwise display `n % 1,000,000` as exactly six ASCII digits, retaining leading zeros. Never transmit the digits. The commitments and fixed reveal ordering prevent adapting committed keys, nonces or identity commitments after learning all honest comparison randomness.

Six digits provide only about 20 bits of human verification (approximately one in a million per independent active attempt when users compare correctly), not 256-bit authentication. Rate limits and explicit comparison are necessary. RSSI cannot prevent relays; a compromised host or a user confirming mismatched codes is outside this protection. This construction is not an audited protocol.

## Mutual comparison and identity binding

Before comparison approval, the provisional encrypted channel may carry only `15 compareApproved` (no fields) or `14 cancel` (no fields). The UI uses generic device labels. Confirm sends one type 15, bound to the displayed attempt and code. Only after **both** local and peer type-15 confirmations may either device send:

- `10 identity`: exactly two fields, `identityJSON` (≤2,048 bytes), `identitySalt32`.
- `11 proof`: existing long-term native signature over `fields("aniCe identity proof v1", H, clientIdentityJSON, serverIdentityJSON, role)`.

The recipient verifies the salted identity opening against IC(role), validates platform and device identity, and verifies key ownership. The local identity snapshot must still match; rename or identity reset cancels instead of changing the identity behind the displayed code. Only then mark local trust approval, send the existing type-12 approval, and reuse the pending-record/signed-receipt flow. No second UI confirmation is needed.

Require both comparison approvals, both proof/approval prerequisites and valid durable receipts before completion. Early identity, proof, type-12 approval or receipt is fatal. Pending records never authorize sessions. A native persistence failure preserves earlier active trust and reports failure. Local activation is atomic; cross-device activation is not a distributed transaction.

After completion, erase ephemeral material and establish a **fresh EDHOC** authenticated session through the existing owners. Never reuse the pairing channel as an application session. Background companion setup remains separate.

The Android native locator from the completed channel may select one fresh connection to that same full peer credential for fifteen seconds, once only. It is process-local, never transmitted or persisted, and cannot replace pinned EDHOC authentication. A missing/stale handoff does not select another anonymous candidate automatically. The fixed discovery profile may still offer comparison while Mac cleanup finishes; before EDHOC, a trusted connection may repeat only that unauthenticated read at most twelve times 500 ms apart, within its original setup deadline. Status `14` remains failure unless a subsequent valid profile is read; no cache reset, successful-read fabrication or sealed-write replay is allowed.

## Compatibility and stored evidence

The public identity schema and journal version remain unchanged. New records store pairing method `3` as evidence of numeric comparison. Older binaries understand only methods `1` and `2` and reject journals containing method `3`; do not downgrade an installation after SAS pairing. Updated devices still pair with older peers through explicitly selected QR/PIN. An unsupported selected SAS attempt fails without changing earlier trust or automatically downgrading.
