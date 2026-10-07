# aniCe BLE discovery, version 1

This public protocol identifies compatibility, not identity or trust. Mac is the peripheral; Android is the central. Neither app requests bonding.

| Assignment | Fixed UUID |
| --- | --- |
| Primary service | `414E4953-4853-4149-4A49-4C4365090901` |
| Read-only discovery characteristic | `414E4953-4853-4149-4A49-4C4365090902` |

The app advertisement supplies only the service UUID and generic name `aniCe`. Name presence is not required. No manufacturer/service data, identity, fingerprint, device name, hardware address, or nonce is supplied.

## Payload

Exactly 20 bytes, with no framing, JSON, terminator, or padding:

| Offset | Bytes | Value |
| --- | --- | --- |
| 0 | 2 | Unsigned big-endian protocol version `1` |
| 2 | 2 | Unsigned big-endian optional capability flags; sender uses `0` in Phase 3 |
| 4 | 16 | Cryptographically random discovery nonce |

Reject any length other than 20 and versions other than 1. All flag bits are optional: preserve the received numeric flags but ignore unknown bits and never enable unknown behavior. Mandatory incompatible semantics require a new version. Any 16-byte nonce decodes, including all zeros in fixtures; production uses a system CSPRNG. Receivers cannot infer authenticity or freshness from nonce bytes.

The Mac creates a fresh nonce per start, rotates every 30 seconds during its 120-second active window, and erases it on stop. The dynamic characteristic permits unencrypted reads only, no writes or notifications. Reads validate the active deadline and characteristic; offsets 0–20 are valid (20 returns empty), larger offsets fail. Serving a read takes one immutable payload snapshot.

Android scans for 15 seconds using the service filter, selects a temporary candidate, stops scanning, connects, discovers the assigned readable characteristic, reads and validates, then disconnects/closes. The connection/read deadline is 15 seconds with up to 2 additional seconds for cleanup. Successful validation proves only that the connected endpoint returned this format.

No trust/identity storage is accessed. Android scan addresses remain only in an active deduplication map and never reach UI, persistence, or logs. Phase 4 QR will carry ephemeral rendezvous plus public identity, not a BLE address.

## Shared fixtures

[`../test-vectors/discovery-vectors.json`](../test-vectors/discovery-vectors.json) has `fixtureVersion: 1`, `valid` entries with `name`, `payloadHex`, `version`, `flags`, `nonceHex`, and `invalid` entries with `name`, `payloadHex`, `reason`. Hex is exact bytes, not production wire text. Both native suites consume this same resource.
