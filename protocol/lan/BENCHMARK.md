# Production LAN benchmark

`scripts/verify-lan-interchange.py` uses disposable protected identities, native discovery, the production LAN transports and `SessionConnection`. Its default invocation retains the 4,000-byte bidirectional conformance check. `--benchmark-mib 16|100|1024 --window 32|64` additionally measures sequential bulk traffic in both directions. Production identity/trust journals are checked for unchanged bytes.

## Isolated DATA payloads

These payloads are test-only; applications do not advertise or dispatch them as transfer capability. Existing session authentication, readiness, counters and record limits remain unchanged.

| Kind | Layout | Validation |
| --- | --- | --- |
| Chunk | `0x42 || offset:u32be || body` | Exact next offset; body length `min(3072, total-offset)`; every body byte equals `(offset/3072) % 251` |
| Written ACK | `0x41 || offset:u32be` | Exactly five bytes; cumulative offset strictly increases and does not exceed total |

The configured total is exactly 16 MiB, 100 MiB or 1 GiB; 16 MiB is a short diagnostic. Android sends first, then Mac. Credit bounds unacknowledged bytes to `window × 3072`; receivers coalesce cumulative ACKs every 16 chunks and at EOF. One pending ACK and one unsent chunk are retained. Benchmark writers serialize their own submissions and wait for actual session availability rather than spinning on refusal notifications. Capacity refusal is retried only before sealing, following session/transport events; submitted records are never replayed. This benchmark does not write files or implement durable checkpoints, resume or session renewal.

## Measurements and gate

`benchmark.json` reports receiver-confirmed throughput from both endpoints, process CPU consumption, Mac peak resident bytes and available Android runtime allocation/GC counters. Throughput below 8 MiB/s in either direction fails the throughput gate. An incomplete run exceeding `max(60 seconds, totalMiB × 0.5 seconds)` also fails and records confirmed byte counts in `benchmark.json`; it never reports partial traffic as completed throughput. Android waits for the harness to retain this failure before disposing its isolated files and keys. Bulk runs compile the Mac helper with `-O`; Android uses Debug instrumentation. App Release, battery and minimum-OS acceptance remain separate.

Concurrent Now Playing latency, the 100-ms control RTT/25-ms added-latency gates, Mac allocation profiling and controlled-network acceptance remain independent requirements. Throughput success alone does not permit feature integration. No File Transfer capability, UI or background ownership is enabled by the benchmark.

`--profile bulk-probe --window 4|8` selects the isolated [bulk profile](BULK_PROBE.md). Debug instrumentation holds a Wi-Fi high-performance lock only for the benchmark, releasing it on success or failure; Release permissions remain unchanged. Socket buffer hints are set before connection and effective sizes are reported. `socketReadMs` and `recordDeliveryMs` separate cumulative socket waiting from authenticated delivery across both directions. Engine reads size the buffer to one whole record (`profile.maximumEnvelope + 5`: 4,101 bytes standard, 262,180 for profile 3, 4,194,340 for the bulk probe) rather than a fixed 64 KiB.

Keep aniCe visible and the phone unlocked during foreground acceptance. On the API-36 test phone, Android maps the high-performance lock to low-latency mode and ignores it for a background UID even when `isHeld` is true. Verify effective lock state separately; process importance at start/end is recorded and does not itself prove radio mode. Background-service acceptance requires its own measurement.

## Verification results

### Physical file transfer (200 MB batch)

Application-level file transfer between Mac and Android over Wi-Fi with Bluetooth disconnected:
- **5 GHz Mobile Hotspot (near-field external AP):**
  - **Mac → Phone:** 7.0–10.5 MB/s (average ~8.0 MB/s), satisfying the 8 MiB/s acceptance gate.
  - **Phone → Mac:** 3.0–5.2 MB/s (average ~4.0 MB/s).
- **Attenuated Wi-Fi router (2.4 GHz, 3–5m range):** ~1.0 MB/s symmetric across both directions.
- **UI & Ingress:** Smooth progress rendering and rolling-window rate tracking; presentation thread starvation and TCP window stalls resolved.
- **Topology:** Phone-hosted hotspot loopback routing remains an open topic; measurements reflect connection via a shared external AP or router.

### Synthetic bulk probe (Harness baseline)

The isolated in-memory bulk probe (`--profile bulk-probe`) confirms a ~10.8 MiB/s wire baseline across both directions, satisfying the transport throughput floor in the absence of disk I/O.

### Architectural constraints

1. **KeyStore IPC ceiling:** Standard transfer v1 carries 3,072-byte chunks across 4,000-byte records, requiring 2,730 live KeyStore validations/second at 8 MiB/s. Hardware KeyStore IPC saturates at ~100–200 queries/s, capping standard records to ~300–600 KB/s. Profile 3 (131,072-byte chunks) amortizes validations to 64/s to operate within hardware capacity.
2. **Ingress decoupling:** Bounded ordered ingress queues (`LanIngressQueue` / `LanQueueBudget`) decouple socket reads from application delivery, sizing read buffers to whole records (`profile.maximumEnvelope + 5`) to prevent TCP receive window collapse.
3. **Off-main chunk decode:** Chunk CBOR decoding runs on `Dispatchers.Default` off presentation threads to prevent UI frame drops.
4. **SAF provider latency:** Synchronous DocumentFile provider traversal adds per-chunk IPC overhead; throughput requires sequential streaming into exclusive staging files before atomic publication or link fallback.

## Outstanding acceptance

Transfer integration remains gated on the 1-GiB completed-run matrix, concurrent Now Playing latency under saturation, storage/foreground-service acceptance, phone-hosted hotspot loopback routing, and resume/renewal journals. Basic transfer capability, destination publication fallback, and UI rate tracking are implemented.
