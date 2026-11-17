<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Defines authenticated drain barriers and consecutive fresh EDHOC sessions over one LAN socket. -->
# In-flight LAN renewal v1

Android remains EDHOC initiator and Mac responder. Renewal preserves the TCP socket, authenticated application-channel instance, pinned peer reservation and feature ownership. It replaces the entire cryptographic session after bidirectional drain; it never resumes keys, exporters, IV bases, counters, connection IDs or ephemeral keys. BLE retains its teardown/reconnect renewal.

## Negotiation and wire

The deterministic CBOR [renewal envelope](renewal.cddl) is carried inside encrypted DATA kind 3 / session envelope 6, at most 128 bytes:

| Type | Sender | Envelope |
| --- | --- | --- |
| 1 support | Both | `["aniCe LAN renewal", 1, 1, []]` |
| 2 begin | Android | `["aniCe LAN renewal", 1, 2, [renewalId, reason]]` |
| 3 drained | Mac | `["aniCe LAN renewal", 1, 3, [renewalId]]` |

`renewalId` is a fresh 16-byte CSPRNG byte string per renewal. Reason 1 denotes lifetime; reason 2 denotes record margin. Exact types, arities, canonical encoding, size and roles are enforced. Invalid recognized envelopes terminate with `malformed`, unsupported versions/types with `unsupportedProfile`, and invalid ordering/roles/identifiers with `state`. The tag is consumed by LAN Session infrastructure, not feature dispatch. It grants no BLE capability.

Each peer publishes support once after successful HELLO/ACK compatibility. Renewal requires local support submission and authenticated remote support on that same cryptographic channel. Unknown tags remain ordinary ignored DATA on legacy peers; the existing HELLO and RENEWAL_REQUEST bytes are unchanged. Without mutual support, LAN retains its original hard limits and reconnection policy.

## State machine

Trigger at 3,300 seconds of record-channel age or when either directional count reaches `2^20 - 1024`. Mac may submit its existing `["aniCe control", 1, 5, {"reason": 1 / 2}]`; Android coalesces that request with its local threshold. Neither path starts a second renewal.

1. Close application sealing admission. Already nonce-owned submissions finish with their original post-write native validation; waiting plaintext remains feature-owned.
2. Android drains its old-direction submissions and sends begin under the old keys. It sends no later old-key application DATA or keepalive request.
3. Mac accepts ordered old-key traffic through begin, closes its own application sealing admission, settles pending old controls, and drains its old-direction submissions. It sends drained as its final old-key record.
4. Android accepts ordered old-key traffic through the matching drained record. Both retire the old cryptographic channel/exporter after their final submission/receipt has completed; TCP and ingress queues remain intact.
5. Android sends fresh EDHOC message 1. Messages 1–4 retain the selected LAN frame profile, existing transcript, suite 5 and mandatory message 4. The full pinned peer credential and current native identity are validated again.
6. Fresh exporter material creates a new SecureSession. New-key ready/readyAck consume sequence zero in their respective directions. New HELLO/ACK negotiation follows readiness. Application sealing reopens and capacity waiters wake.

Handshake envelopes are accepted on an established socket only in the negotiated, expected renewal phase. Errors remain fatal. Old-key records after their directional barrier, unexpected handshake messages and premature new-key DATA terminate the channel. No socket EOF, authenticated CLOSE, feature retirement or capability replay marks a successful renewal.

Quiescence and drain acknowledgement share one ten-second absolute monotonic deadline. Fresh EDHOC has thirty seconds; encrypted readiness has ten seconds. Old-channel lifetime, record, idle and outstanding-PONG deadlines remain enforced until old-key retirement, including while native signing or validation is suspended. Renewal never extends a hard deadline. Disconnect, network loss, identity/trust invalidation and ownership loss outrank suspended completion. Failure retires normally; there is no rollback to the old keys or replay of sealed records.

## Feature and work ownership

The same authenticated channel publishes a bounded maintenance interval without changing its descriptor or availability. Transfer capacity, resume and file-confirmation timeout budgets exclude only that interval; credit waiters retain their existing correlated progress. Fixed offer-assembly, recovery-retention and security deadlines remain absolute. No feature queue or full transfer is drained as a prerequisite to rekeying. Pending ACKs and unsealed DATA resume on the same channel.

Android work leases remain owner/job-scoped and independent of cryptographic epochs. Only existing approved service, bounded picker or companion-media ownership permits background work. Final lease release starts the configured idle timeout when backgrounded or locked. Explicit Disconnect, invalid trust, unusable network and process retirement remain terminal independently of work demand.

## Fixtures

[Renewal fixtures](../test-vectors/lan/renewal-vectors.json) cover support, begin, drained and rejected encodings. The adjacent `generate_lan_control_vectors.py --check` command uses an independent CBOR oracle.
