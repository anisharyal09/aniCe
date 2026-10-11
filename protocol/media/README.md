# Media v1

[media.cddl](media.cddl) is the authoritative message shape. Messages are deterministic RFC 8949 CBOR arrays inside existing authenticated DATA records, at most 4,000 plaintext bytes. Session readiness, HELLO/ACK control negotiation, connection checks, EDHOC, exporter labels, AES-GCM framing and nonce ownership are unchanged. Unknown media versions/kinds are discarded; absent media capability leaves legacy connections usable.

## Messages

Every envelope is `["aniCe media", 1, kind, fields]`. Text bounds count UTF-8 bytes; NUL is forbidden. UUIDs have canonical 36-character hyphenated syntax, case insensitive. Issued opaque IDs must be echoed byte for byte. Empty text represents an absent source/revision/selection; `-1` represents an unknown position or duration. No CBOR null, floating-point, indefinite-length or non-minimal encodings are permitted.

| Kind | Direction | Fields |
| --- | --- | --- |
| 1 | Mac → Android | `[1, artwork]`; sent once after secured readiness on each channel; artwork true only for LAN |
| 2 | Android → Mac | `[subscription UUID]` |
| 3 | Mac → Android | `[subscription UUID]`; precedes the first snapshot |
| 4 | Android → Mac | `[subscription UUID]` |
| 5 | Mac → Android | `[subscription, source, revision, title, artist, player, state, positionMs, durationMs, rateMilli, actions, selection, catalogue, sources, artworkHash]` |
| 6 | Android → Mac | `[subscription, commandId, source, revision, action, argumentMs]` |
| 7 | Mac → Android | `[subscription, commandId, result]` |
| 8 | Mac → Android, LAN only | `[subscription, source, revision, SHA256, totalBytes, offset, chunk]` |

Snapshot title ≤512 bytes, artist ≤256, player/source name ≤96. Inventory contains at most 16 unique `[sourceUUID, name, state]` rows. Source/revision are both present or both absent. Present source and manual selection must occur in the inventory. Empty source has zero actions and empty artwork hash. Catalogue UUID changes when the inventory changes. `selection = ""` means Auto.

State: `0 unknown`, `1 playing`, `2 paused`, `3 stopped`. Position and duration range `-1…604800000` milliseconds. Rate is `0…16000` thousandths of normal speed. Position/rate are one monotonic sample, extrapolated locally while playing and visible. Position-only changes preserve playback revision. Track/source replacement and supported-action changes replace revision.

Actions bitmask: `1 play/pause`, `2 previous`, `4 next`, `8 seek`, `16 permission needed`. Seek requires positive known duration; unknown duration removes the seek action/control. Permission-needed may accompany supported controls; remote execution returns a permission result without prompting.

Command IDs increase from 1 through `2^32−1` within a subscription. Actions: `1 play/pause`, `2 previous`, `3 next`, `4 seek`, `5 select`, `6 Auto`. Only seek has a nonzero argument; the Mac additionally requires its value ≤current duration. Auto has empty source; every other action has a source UUID. Playback targets a playback revision; select/Auto targets catalogue revision. Source IDs bind to process/player identity and process launch time on the Mac. Native execution revalidates the recording and running process; there is no global command fallback.

Results: `0 applied`, `1 stale`, `2 unsupported`, `3 permission-needed`, `4 denied`, `5 unavailable`, `6 busy`, `7 failed`. Applied acknowledges native submission/Apple Event completion, not proof of audible playback. A pending duplicate is ignored until its original completes. Last 32 completed results are retained; older IDs below the high-water mark return stale without executing. One playback operation runs at a time. Native request UUIDs isolate late adapter acknowledgements. Phone commands time out after six seconds and are never automatically retried; uncertain outcomes remain uncertain.

## Subscription and scheduling

Android owns media while at least one activity is foregrounded. Navigation does not change ownership. Configuration replacement gets a one-second grace; final background stop unsubscribes and clears remote state. Android selects compatible already-secured LAN first, otherwise compatible already-secured BLE. No connection is initiated by media. Mac owns one subscription across both transports. Switching retires the previous subscription, queued logical commands, pending results, artwork and displayed state, then requires a fresh subscription, acknowledgement and snapshot. Uncertain/sealed commands never migrate or replay. Session loss, trust invalidation, identity reset and replacement clear media endpoints.

BLE carries snapshots, selection, commands and results. LAN additionally carries artwork. Mac observation runs only for a visible Home/Features surface, visible companion or active remote subscription; stopping observation clears manual selection and native target state.

Existing liveness work precedes media submission. High-priority media responses/capability/acknowledgement queues have 16 entries; new commands are rejected busy before exhausting result headroom. The Mac keeps one coalesced unsent logical snapshot per endpoint, then one thumbnail cursor. Capacity events resume submissions. Once sealed, records remain in transport order; capacity preflight and nonce ownership stay in the session layer.

## Artwork

Thumbnails are JPEG or PNG, longest edge ≤256 pixels, encoded bytes `1…65536`. Hash is SHA-256 of the complete encoded thumbnail. Binary chunks are `1…2048` bytes; no base64 on the wire. `offset + chunkLength ≤totalBytes`; offsets must exactly equal bytes assembled so far, beginning at zero. Subscription, source, revision, hash and total must match the latest snapshot/assembly. Snapshot hash is empty on BLE or absent artwork.

Android permits one in-memory assembly, with a fixed ten-second monotonic deadline starting at its first chunk. Later chunks do not extend it. Repeated first chunks, gaps, changed lengths/hash, wrong revisions, truncation, expiry or hash mismatch discard the assembly. Decoded MIME type and both dimensions are validated before retaining the bitmap. Superseded source/revision/channel clears assembly and displayed artwork. A discarded hash cannot restart until a fresh snapshot target resets assembly. The Mac restarts thumbnail transmission on revision changes. No disk cache or remote URL fetching exists.

## Independent fixtures

[media-vectors.json](../test-vectors/media/media-vectors.json) contains 12 positive and 28 negative independently encoded fixtures. `scripts/generate-media-vectors.py` uses a standalone Python RFC 8949 encoder; it imports neither native codec. Both platform suites assert inventory floors, byte-for-byte encoding, bounds and rejection. Lifecycle, channel routing, scrub replacement, saturation and assembly deadlines have separate behavioral tests.
