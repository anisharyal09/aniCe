# Independent LAN sessions

Status: accepted.

## Context

Trusted-device sessions use native EDHOC and directional AES-GCM over BLE. LAN adds a higher-bandwidth local path without changing pairing, protected identity storage or trust.

## Decision

- Use native TCP: Android is client/EDHOC initiator and Mac is listener/responder.
- Advertise anonymous ephemeral Bonjour/NSD locators. Every socket independently authenticates the selected full credential.
- Reuse the shared handshake, session, record and DATA implementations. Do not add TLS, Rust networking, BLE-derived LAN keys or resumed counters.
- Permit BLE and LAN concurrently only for the same pinned peer and local identity. An unresolved Mac Any-phone BLE window remains exclusive.
- Keep transport failure, disconnection and admission independent; trust removal and identity reset retire both.

The [LAN contract](../../protocol/lan/README.md) owns framing, profile limits and bounded admission/discovery.

## Extensions

[Rendezvous v2](../../protocol/lan/AUTOMATIC.md) exchanges authenticated IPv4 locators over live BLE before Bonjour registration, with bounded mDNS fallback. Locators are routing hints, never identity or key material.

[LAN renewal](../../protocol/lan/RENEWAL.md) drains both old record directions before fresh EDHOC/readiness on the retained socket. Feature descriptors, queues and eligible work ownership survive; all cryptographic material is replaced.

The initial increment used foreground/manual LAN and standard 4,000-byte records. [LAN ownership](../LAN_CONNECTIONS.md), [shared feature routing](0008-application-data-feature-boundaries.md) and [transfer profiles](../../protocol/lan/TRANSFER_PROFILE.md) define the subsequent behavior.

## Consequences

- IPv6 scope and socket network binding remain separate inputs.
- A timed-out legacy NSD resolution still owns its native lane until the callback completes. Modern subscriptions are explicitly unregistered.
- Admission callbacks share the original window and failure budget; late callbacks cannot reopen it.
- Native OS permission, firewall and route policy still govern reachability.
- Mac retains its Bonjour declarations and network entitlements. Its current unsandboxed process/signing boundary is defined in [ADR 0007](0007-macos-unsandboxed-playback-prototype.md).

## References

- [RFC 6763 — DNS-SD](https://www.rfc-editor.org/rfc/rfc6763.html)
- [RFC 9293 — TCP](https://www.rfc-editor.org/rfc/rfc9293.html)
- [Android NSD](https://developer.android.com/reference/android/net/nsd/NsdManager) and [network binding](https://developer.android.com/reference/android/net/Network#bindSocket(java.net.Socket))
- [Apple local-network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Secure sessions](0005-edhoc-secure-sessions.md)
