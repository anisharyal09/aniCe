# Selected-player volume extension v1

[CDDL](player-volume.cddl) defines an optional deterministic CBOR array `["aniCe player volume", 1, kind, fields]`, carried in authenticated DATA of at most 4,000 bytes. Media v1 envelopes, capabilities, action masks and fixtures remain byte-for-byte unchanged. No session readiness/control or cryptographic changes occur.

| Kind | Direction | Fields |
| --- | --- | --- |
| 1 | Both | `[1]` capability advertisement |
| 2 | Mac → Android | `[subscription, source, playbackRevision, supported, level]` |
| 3 | Android → Mac | `[subscription, commandId, source, playbackRevision, level]` |
| 4 | Mac → Android | `[subscription, commandId, result]` |

The Mac advertises the extension separately. Android answers its capability once per channel. Samples and commands require reciprocal capability, an acknowledged media subscription and the same secured channel. Unsupported/unknown versions and malformed fields are discarded; peers without the extension retain media v1 and connection usability.

Subscription/source/revision are 36-byte UUIDs. A sample's source/revision are both present or both empty. Supported samples require present source/revision and an integer level 0–100; unsupported samples carry `-1`. Commands require present source/revision and integer level 0–100. Results use media v1's applied/stale/unsupported/permission-needed/denied/unavailable/busy/failed values 0–7.

Command IDs share the media subscription's 1–2^32−1 namespace and bounded deduplication/high-water mark. Reused IDs never execute twice, including across extension kinds. Commands are never retried automatically. Samples preserve playback revision; support changes invalidate it. Retirement drops pending volume state and unsent work. Volume cannot use a second channel or reactivate LAN.

Support is restricted to Music/Spotify integer application `sound volume` properties after packaged PID-directed read/write/read verification. Each read/write revalidates bundle/PID/launch identity. Permission checks never prompt on remote paths; an explicit Mac permission action can initiate verification. A proof is kept in memory for its process/launch/property identity. Transient reads withdraw current support while retaining proof; subsequent native events or explicit refresh may recover through reads alone. Uncertain writes are never retried. Pending previews require an authoritative matching sample, with a fixed six-second deadline; no history, disk cache or system-output fallback exists. Browsers and wrappers do not advertise player volume. Explicit player-volume sliders use this extension. Phone hardware/system media volume uses the independently advertised [Mac output extension](OUTPUT_VOLUME.md), with no implicit fallback between scopes.

[Independent fixtures](../test-vectors/media/volume-vectors.json) contain 9 positive and 23 negative vectors. The adjacent [generator](../test-vectors/media/generate.py) uses its standalone RFC 8949 encoder. Tests assert positive/negative inventories, exact bytes, integer bounds, truncation, unsupported versions and noncanonical encodings.
