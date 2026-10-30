# aniCe LAN binding v1

The [LAN transfer profile](../lan/TRANSFER_PROFILE.md) defines production LAN revision 2 and record profile 3. File transfer capability 3 supports chunks up to 262,016 bytes; standard profile 1/BLE limits remain unchanged.

See [automatic LAN rendezvous](AUTOMATIC.md) for opt-in authenticated BLE coordination of bounded admission on connection events and feature demand. Run-to-run recovery remains owned by BLE. Manual behavior below remains available.

## Discovery and roles

Android is TCP client and EDHOC initiator; macOS is TCP listener and EDHOC responder. Existing active trust is mandatory. LAN does not pair devices or modify identity/trust journals.

The responder registers `_anice._tcp` through Bonjour on a dynamic port during an explicit 120-second Allow window. Its instance name is `aniCe-<fresh UUID-v4>` and TXT contains `v=1`. Device names, IDs, credentials and fingerprints are excluded. Service names, TXT, addresses and ports are unauthenticated locators; EDHOC authenticates the selected credential. Credentials retain the privacy limits of the [session profile](../session/README.md).

Android browses and resolves serially within one 15-second absolute deadline, admitting at most eight distinct service instances per attempt. Resolved endpoints stream into authentication immediately, deduplicated to at most eight address/scope/port combinations. Resolution does not identify a trusted peer: browsing continues through unsuccessful candidates and stops on selected-peer secured readiness, endpoint capacity, deadline or cancellation. Service loss fences unresolved results; late callbacks cannot reopen a retired browse. Discovery-producer failures propagate through the connection consumer; consumer exit cancels and drains discovery cleanup. On API 29–33, the multicast lock covers the active browse and resolution and is released during cleanup; API 34+ does not acquire it. Socket connections use the selected Wi-Fi network and directly connected routes. IPv4 and scoped link-local IPv6 are supported; conflicting/missing IPv6 interfaces are rejected. Each endpoint receives a fresh session attempt. The overall attempt is bounded to 90 seconds; socket connection takes at most five seconds. Failure does not authorize another credential or downgrade to pairing.

Legacy Android NSD has one process-wide resolution lane. Its five-second await timeout terminates the Connect attempt but does not release the native slot. Only the original terminal callback releases it. Cancellation and late callbacks cannot start or restore a retired attempt. Error 3 (`FAILURE_ALREADY_ACTIVE`) terminates discovery without an automatic resolution loop.

## Stream framing

Each TCP frame contains exactly:

| Field | Size | Value |
| --- | --- | --- |
| version | 1 byte | `1` |
| length | 4 bytes | Unsigned big-endian envelope length, 2–4096 |
| envelope | length bytes | Existing session discriminator and payload |

The [session envelope](../session/README.md) remains `kind:u8 || payload`, with kinds 1–4 for EDHOC messages, 5 for EDHOC error, and 6 for encrypted application records. No BLE fragmentation headers or message IDs appear on TCP. EDHOC transcript, deterministic CBOR, exporter contexts and encrypted-record bytes are unchanged.

Receivers validate version and length before body allocation, retain one partial frame and deliver complete envelopes serially. Framing consumes bounded buffer slices with block copies and one monotonic clock sample per receive buffer. Before secured ready/readyAck completion, assembly has an absolute ten-second deadline from the first header byte. After secured readiness, an envelope whose first body byte is encrypted-record kind 6 uses `min(firstHeaderByte + 60 s, lastReceivedByte + 10 s)`. Partial headers and other envelope kinds retain the absolute ten-second limit. Only nonempty input refreshes progress; input arriving at or after expiry cannot revive the frame. Byte progress is not authenticated application activity. EOF at a frame boundary ends the transport; EOF inside a frame is malformed. Invalid version, length, assembly timeout and native socket errors retire the session. This receiver deadline policy changes no wire bytes or negotiation; older receivers retain their shorter deadline.

Outgoing capacity is eight envelopes/32 KiB, including envelopes currently being submitted; each envelope additionally has a fixed five-byte framing header. Capacity refusal occurs before record sealing. An encryption or post-seal submission failure burns the sequence and retires the session. A write retained for ten seconds closes the socket. TCP submission completion establishes local acceptance, not authenticated remote delivery.

## Admission, ownership and coexistence

Mac admits one candidate and withdraws Bonjour advertising while it is occupied. An unsuccessful candidate may release its slot and advertise again within the original window; the fifth failure ends availability. Failed attempts cannot extend the Allow deadline. Additional connections are closed without joining the admitted candidate.

Each transport owns its own EDHOC ephemerals, connection IDs, exporters, directional keys, IVs, counters, readiness and liveness. A shared reservation pins all pending/secured transport owners to the same full peer credential and local fingerprint. Display-name changes do not alter it. An unresolved Mac Any-phone BLE window is exclusive until authentication or cancellation; LAN freezes a concrete trusted phone.

LAN requires fresh EDHOC and mandatory message 4, then encrypted ready/readyAck before application access. HELLO/ACK and PING/PONG use existing controls. Hard limits remain 4,000 plaintext bytes, one-hour lifetime, 120-second idle, ten-second readiness and `2^20` records per direction. Manual LAN has no automatic renewal/reconnection; the opt-in rendezvous policy waits for a new connection event or feature demand after retirement. Application features use the shared secured DATA dispatcher.

Android initiates manual LAN work from a started presentation. Background and screen lock apply the configured idle timeout, defaulting to Never (0 minutes); bounded picker, approved-transfer and companion remote-playback leases retain active work. Automatic admission follows [rendezvous eligibility](AUTOMATIC.md). Network loss retires the affected LAN channel independently of BLE companion ownership. Mac window and companion share one LAN owner; sleep and Quit retire it. Transport Disconnect affects that transport; Disconnect all, trust removal and identity reset retire both. LAN operations do not acquire the exclusive BLE radio.

## Verification

[Framing fixtures](../test-vectors/lan/lan-vectors.json) contain eight valid lengths and ten invalid version/length/truncation cases. `generate_lan_vectors.py --check` uses Python `struct` as an independent framing oracle. Native tests assert fixture inventories and exercise every split point, coalescing, timeout retirement, scoped IPv6 and peer exclusion.

Native protected-key TCP interchange verifies Android NSD discovery, IPv4 and scoped link-local IPv6, readiness, negotiated controls, 4,000-byte records in both directions and isolated key cleanup. Packaged-app Bonjour permission/sandbox admission, physical simultaneous BLE/LAN, native lifecycle, minimum-OS and security-review acceptance are separate gates.

The [production LAN benchmark](BENCHMARK.md) exercises the native transport/session pipeline with bounded bulk credit. It does not enable File Transfer or background LAN ownership.
