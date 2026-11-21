<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Device Names v1

Device-owned names travel only over an existing ready authenticated DATA channel. This handler never opens or extends a connection lease. Names are display metadata, not credentials; pairing proofs, receipts, fingerprints and session descriptors remain immutable. Private nicknames are never transmitted.

Deterministic CBOR: `["aniCe device names", 1, kind, fields]`, maximum 512 bytes.

| kind | fields | meaning |
| --- | --- | --- |
| 1 | `[1]` | capability, once per channel |
| 2 | `[revision, name]` | current publisher-owned name |

Revision is 0..INT64_MAX; names are trimmed nonblank UTF-8 strings of 1..64 Unicode code points (maximum 256 UTF-8 bytes). Unknown tags are unrecognized; malformed recognized messages are discarded. Report requires peer capability on that same channel. Channel instance and full pinned credential bind the sender; there is no sender-supplied identity or key. Equal revision/name is idempotent, lower revisions and conflicting equal revisions are discarded across both BLE and LAN.

Each installation persists its current local fingerprint, last published name and increasing revision atomically before publication. Successful local edits refresh this record and send the latest value over capable existing channels. Offline edits publish on next connection; no offline message queue is retained. Reconnection publishes a current snapshot. Older peers ignore the capability and do not receive reports. No retry polling or identity-store polling is introduced.

Receivers retain latest names and revision floors in separate no-backup display storage, scoped to local identity and the peer's full credential. Nickname plus Use nickname are local overrides (default off); turning it off restores the latest synced name, falling back to the pairing-time name if unavailable. Security details expose that device name and the fingerprint, never nickname as identity. Forget prunes display metadata; identity reset clears local display bindings. Failed persistence preserves earlier values; no success is shown before storage. Changing a label must not recreate a channel, resend commands or refresh trust.
