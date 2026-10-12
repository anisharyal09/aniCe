# Production LAN benchmark

`scripts/verify-lan-interchange.py` uses disposable protected identities, native discovery, the production LAN transports and `SessionConnection`. Its default invocation retains the 4,000-byte bidirectional conformance check. `--benchmark-mib 100|1024 --window 32|64` additionally measures sequential bulk traffic in both directions. Production identity/trust journals are checked for unchanged bytes.

## Isolated DATA payloads

These payloads are test-only; applications do not advertise or dispatch them as transfer capability. Existing session authentication, readiness, counters and record limits remain unchanged.

| Kind | Layout | Validation |
| --- | --- | --- |
| Chunk | `0x42 || offset:u32be || body` | Exact next offset; body length `min(3072, total-offset)`; every body byte equals `(offset/3072) % 251` |
| Written ACK | `0x41 || offset:u32be` | Exactly five bytes; cumulative offset strictly increases and does not exceed total |

The configured total is exactly 100 MiB or 1 GiB. Android sends first, then Mac. Credit bounds unacknowledged bytes to `window × 3072`; receivers coalesce cumulative ACKs every 16 chunks and at EOF. One pending ACK and one unsent chunk are retained. Benchmark writers serialize their own submissions and wait for actual session availability rather than spinning on refusal notifications. Capacity refusal is retried only before sealing, following session/transport events; submitted records are never replayed. This benchmark does not write files or implement durable checkpoints, resume or session renewal.

## Measurements and gate

`benchmark.json` reports receiver-confirmed throughput from both endpoints, process CPU consumption, Mac peak resident bytes and available Android runtime allocation/GC counters. Throughput below 8 MiB/s in either direction fails the throughput gate. An incomplete run exceeding `max(60 seconds, totalMiB × 0.5 seconds)` also fails and records confirmed byte counts in `benchmark.json`; it never reports partial traffic as completed throughput. Android waits for the harness to retain this failure before disposing its isolated files and keys. Bulk runs compile the Mac helper with `-O`; Android uses Debug instrumentation. App Release, battery and minimum-OS acceptance remain separate.

Concurrent Now Playing latency, the 100-ms control RTT/25-ms added-latency gates, Mac allocation profiling and controlled-network acceptance remain independent requirements. Throughput success alone does not permit feature integration. No File Transfer capability, UI or background ownership is enabled by the benchmark.

`--profile bulk-probe --window 4|8` selects the isolated [bulk profile](BULK_PROBE.md). Debug instrumentation holds a Wi-Fi high-performance lock only for the benchmark, releasing it on success or failure; Release permissions remain unchanged. Socket buffer hints are set before connection and effective sizes are reported. `socketReadMs` and `recordDeliveryMs` separate cumulative socket waiting from authenticated delivery across both directions. Android bulk reads use one bounded 64-KiB buffer; standard reads remain 4 KiB.

Keep aniCe visible and the phone unlocked during foreground acceptance. On the API-36 test phone, Android maps the high-performance lock to low-latency mode and ignores it for a background UID even when `isHeld` is true. Verify effective lock state separately; process importance at start/end is recorded and does not itself prove radio mode. Background-service acceptance requires its own measurement.

## Bulk-channel proposal

If bounded credit and supported TCP adjustments cannot meet the gate, retain the existing channel for connection checks, media and small DATA messages. Evaluate a separately negotiated bulk record profile with larger bounded payloads and independent buffering. Fresh authentication must pin the same trusted peer; existing identity protection, revocation, nonce ownership and control-channel record bytes remain intact. Record-size, memory and responsiveness limits require a new shared Connections/Session decision and production-path measurements before transfer integration.

## Current gate

The physical 100-MiB attempt with a 64-chunk window, TCP no-delay and an optimized Mac helper acknowledged 2,162,688 bytes in approximately 60 seconds. It reached the completion deadline before reverse traffic began. This is an incomplete run, not a completed-file throughput result. The optimized 32-chunk attempt acknowledged 491,520 bytes in approximately 60 seconds and also failed before reverse traffic. Debug attempts with 32/64 chunks also missed the deadline. A Mac stack sample repeatedly observed protected identity validation in `SecKeyCopyPublicKey` / Keychain ACL IPC; this identifies a profiling lead, not a complete attribution of end-to-end cost.

The isolated 4-MiB probe completed 100 MiB in both directions, reaching 10.3 MiB/s Android send and 3.9 MiB/s Android receive. Socket-buffer hints and reduced ciphertext copies did not pass the reverse-direction gate. A 64-KiB receive-buffer run measured 8.5/2.6 MiB/s, with 44,992 ms cumulative socket reads and 5,556 ms authenticated delivery. These are physical Debug measurements on the current Wi-Fi connection, not controlled-network acceptance; larger receive buffers alone did not resolve the bottleneck.

A corrected foreground run confirmed process importance 100 at both ends and an effective foreground Wi-Fi lock. It measured 8.5 MiB/s Android send and 3.3 MiB/s Android receive. Foreground ownership alone did not pass the gate. A repeat with Mac submission/socket timing stalled after 41,942,990 acknowledged bytes before reverse traffic; performance is not stable enough for acceptance.

A completed foreground sender-timing run measured 11.2/3.1 MiB/s. Mac socket submission consumed 27.3 of 32.4 seconds inside encrypted DATA submission, locating most reverse elapsed time at socket completion rather than native validation. Pre-connect allocation of an 8-MiB Android receive buffer enabled full TCP window scaling (16,777,216 effective bytes) and primitive byte-verification eliminated inner loop call overhead.

The subsequent physical 100-MiB bulk probe run passed throughput acceptance in both directions under foreground conditions:
- **Phone → Mac:** 10.86 MiB/s Android send, 11.01 MiB/s Mac receive.
- **Mac → Phone:** 10.85 MiB/s Mac send, 11.10 MiB/s Android receive.
- **Timing and resources:** Mac socket send time dropped to 2.33 seconds (total submission 7.82 seconds). Android socket read time was 15,733 ms and authenticated delivery was 3,267 ms. Android consumed 6,031 ms CPU, 20 GC collections (777 ms); Mac consumed 2.13 seconds CPU and 67.4 MiB peak RSS (`ru_maxrss` 70,647,808 bytes).
- **Gate status:** `throughputPassed` is true (all rates exceed 8 MiB/s).

Transfer integration remains gated on the 1-GiB completed-run matrix, concurrent Now Playing latency under saturation, storage/foreground-service acceptance, Intel runtime and minimum-OS checks. No transfer capability, renewal extension, storage engine or transfer UI is implemented.
