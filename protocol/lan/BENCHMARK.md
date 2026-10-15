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

`--profile bulk-probe --window 4|8` selects the isolated [bulk profile](BULK_PROBE.md). Debug instrumentation holds a Wi-Fi high-performance lock only for the benchmark, releasing it on success or failure; Release permissions remain unchanged. Socket buffer hints are set before connection and effective sizes are reported. `socketReadMs` and `recordDeliveryMs` separate cumulative socket waiting from authenticated delivery across both directions. Android bulk reads use one bounded 64-KiB buffer; standard reads remain 4 KiB.

Keep aniCe visible and the phone unlocked during foreground acceptance. On the API-36 test phone, Android maps the high-performance lock to low-latency mode and ignores it for a background UID even when `isHeld` is true. Verify effective lock state separately; process importance at start/end is recorded and does not itself prove radio mode. Background-service acceptance requires its own measurement.

## Verification results

### Synthetic bulk probe (100 MiB foreground)

- **Phone → Mac:** 10.86 MiB/s Android send, 11.04 MiB/s Mac receive.
- **Mac → Phone:** 10.85 MiB/s Mac send, 11.10 MiB/s Android receive.
- **Timing and resources:** Mac socket send time 2.33 s (total submission 7.82 s). Android socket read time 15,733 ms, authenticated delivery 3,267 ms. Android consumed 6,031 ms CPU, 20 GC collections (777 ms); Mac consumed 2.13 s CPU and 67.4 MiB peak RSS (`ru_maxrss` 70,647,808 bytes).
- **Gate status:** `throughputPassed` is true (all rates exceed 8 MiB/s).

### Application file transfer telemetry

Physical application-level file transfer between Mac and Android over Wi-Fi with Bluetooth disconnected measures:
*(for smaller file size ~ 10-15MB, yet to test properly on large files)*
- **5 GHz Mobile Hotspot (near field / clean RF):** 5–7 Mbps (~625–875 KB/s).
- **Near-field Wi-Fi router (5 GHz / high SNR):** Unknown yet.
- **Distant / Attenuated Wi-Fi (2.4 GHz / extended router range):**  ~600 KB/s to ~2 MB/s 
- **UI Responsiveness:** Noticeable UI progress bar lag/stutter or not progressing on Android receiving device (to fix).

### Bottleneck attribution

1. **KeyStore IPC ceiling:** Transfer v1 carries 3,072-byte chunks across standard 4,000-byte session records. Sustaining 8 MiB/s requires 2,730 authenticated records per second, each executing live native KeyStore / Keychain validation. Android hardware KeyStore IPC (binder calls to `keystore2` / SE / TEE) saturates at ~100–200 queries/s, capping physical throughput to 300–600 KB/s. Production transfer requires profile 3 (131,072-byte chunks) to amortize validations to 64/s.
2. **Main-thread event saturation:** Delivery of incoming chunks and progress state mutations currently dispatches to `Dispatchers.Main.immediate` and Compose state snapshots on every chunk, starving Android UI rendering.
3. **Storage Access Framework overhead:** Synchronous provider writes without a background streaming worker add per-chunk binder latency.
4. **Harness distinction:** The 10.8 MiB/s bulk probe result was measured under `--profile bulk-probe` with in-memory validation, 4-MiB / 131-KiB chunks, and no UI or SAF operations. Real application file transfer remains bottlenecked pending profile 3 and off-main storage pipeline rollout.

## Outstanding acceptance

Transfer integration remains gated on the 1-GiB completed-run matrix, concurrent Now Playing latency under saturation, storage/foreground-service acceptance, Intel runtime and minimum-OS checks. Basic transfer capability, storage and UI now exist. Resume journals and coordinated LAN renewal remain unimplemented; the complete acceptance gate has not passed. Native identity revalidation has been restored, invalidating throughput extrapolation from cached-identity measurements.
