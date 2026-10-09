# Independent LAN sessions

Status: accepted for the manual LAN increment.

## Context

Trusted-device sessions already use native EDHOC and directional AES-GCM records over BLE. LAN adds a higher-bandwidth local path without changing pairing, protected identity storage or trust. Android API 29 and macOS 14 remain provisional minimum baselines.

## Decision

Use native TCP with Android as client/EDHOC initiator and Mac as listener/responder. Bonjour/Android NSD advertise and resolve anonymous ephemeral service locators. Authenticate each socket independently against existing active trust. The [LAN contract](../../protocol/lan/README.md) owns byte framing, discovery bounds and admission.

Reuse transport-independent SessionConnection, handshake and record implementations. Preserve the existing profile, hard bounds and application diagnostics. No TLS layer, additional crypto/runtime dependency, Rust networking layer, key resumption or BLE-derived LAN keys are introduced.

Permit one BLE and one LAN session to the same trusted peer. A shared reservation binds full peer credentials and the current local fingerprint before work starts. Mac unresolved Any-phone BLE admission remains exclusive until it resolves; concrete selections allow concurrent transports. Each channel has fresh keys and counters. Explicit controls determine which transport receives a diagnostic; feature routing and mutual endpoint bootstrap remain deferred.

LAN is manual and foreground-owned on Android. Native BLE companion ownership does not grant LAN background lifetime. Mac retains explicit availability through its existing companion and closes on sleep/Quit. Keep failure, disconnection and admission state independent per transport; trust revocation and identity reset retire both.

## Consequences

IPv6 destinations must preserve their selected interface scope in addition to socket network binding. Legacy Android resolutions remain serialized until native completion, even after timeout; a stalled native operation can prevent immediate Retry. Modern resolution subscriptions are explicitly unregistered.

The sandboxed Mac app enables client/server network entitlements and declares its Bonjour type and local-network purpose. Build verification inspects the packaged plist and signed entitlements. Terminal interchange does not prove packaged-app privacy or sandbox behavior.

The initial LAN record size remains bounded to the existing 4,000-byte plaintext maximum. Bulk streaming, synchronization, automatic recovery, handover and mutual transport bootstrap require subsequent contracts. Existing BLE and minimum-OS verification gaps remain independent release gates.

## References

- [RFC 6763 — DNS-Based Service Discovery](https://www.rfc-editor.org/rfc/rfc6763.html), sections 4–6: service instance naming and SRV/TXT discovery. Random instance names and identity-free TXT records are aniCe privacy choices; discovery does not authorize a peer.
- [RFC 9293 — TCP](https://www.rfc-editor.org/rfc/rfc9293.html), section 2.2: TCP transports a byte stream. The [LAN contract](../../protocol/lan/README.md) defines envelope boundaries, length validation and assembly deadlines independently of socket read/write boundaries.
- [Android NsdManager](https://developer.android.com/reference/android/net/nsd/NsdManager): asynchronous resolution callbacks, `FAILURE_ALREADY_ACTIVE`, and API 34 service-info subscriptions. Keeping the legacy resolution lane occupied until its terminal callback is an aniCe concurrency guard; a coroutine timeout does not establish native completion.
- [Android Network.bindSocket](https://developer.android.com/reference/android/net/Network#bindSocket(java.net.Socket)) and [Inet6Address](https://developer.android.com/reference/java/net/Inet6Address): bind an unconnected socket to the selected network and supply an IPv6 interface scope separately. Network selection and address scope are distinct inputs.
- [Apple network server entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server): TCP sandbox entitlements govern incoming/outgoing connection initiation, not bidirectional data flow. Enabling both entitlements is this implementation's configuration, not a universal requirement for every listener.
- [Apple TN3179 — Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy): Bonjour declarations, usage descriptions, responsible-code attribution and privacy testing. These requirements motivate packaged-app verification rather than relying on command-line interchange.
- [ADR 0005 — EDHOC trusted-device sessions](0005-edhoc-secure-sessions.md) and the [session application profile](../../protocol/session/README.md): pinned authentication, exporter-derived directional keys, fresh handshakes and record limits reused independently by each transport.
