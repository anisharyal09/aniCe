# Native LAN benchmark

`scripts/verify-lan-interchange.py` uses disposable identities, native discovery, LAN transports and `SessionConnection`. The default exchanges 4,000-byte conformance records in both directions.

| Mode | Arguments | Bodies |
| --- | --- | --- |
| Standard | `--benchmark-mib 4\|16\|100\|1024 --window 32\|64` | 3,072 bytes |
| Current LAN profile 4 | `--profile lan-transfer-512 --benchmark-mib 16\|100\|1024 --window 4\|8` | 524,288 bytes |
| Legacy LAN profile 3 | `--profile lan-transfer --benchmark-mib 16\|100\|1024 --window 4\|8` | 131,072 bytes |
| Experimental bulk | `--profile bulk-probe --window 4\|8` | Profile maximum minus five bytes |

Profile 4 uses Bonjour TXT `v=3`; profile 3 uses `v=2`. The [experimental profile](BULK_PROBE.md) is separate from production feature negotiation.

## Test-only DATA

| Kind | Layout | Rule |
| --- | --- | --- |
| Chunk | `0x42 || offset:u32be || body` | Exact next offset; remaining-bound body; every byte equals `(offset/chunkBytes) % 251` |
| Written ACK | `0x41 || offset:u32be` | Exactly five bytes; advancing cumulative offset within total |

Android sends first, then Mac. Credit bounds outstanding bytes to `window × chunkBytes`; receivers coalesce ACKs inside that window and at EOF. One pending ACK and one unsent chunk are retained. Capacity refusal retries before sealing through transport events; submitted records never replay.

These payloads are not file-transfer capabilities. The benchmark does not write destination files, checkpoint jobs, resume transfers or renew sessions.

## Metrics and execution

`benchmark.json` contains receiver-confirmed throughput, process CPU, Mac peak resident bytes and available Android allocation/GC counters. The tool's throughput target is 8 MiB/s in each direction. An incomplete run exceeding `max(60 seconds, totalMiB × 0.5 seconds)` fails and records confirmed bytes, never partial traffic as completed throughput.

The Mac helper is optimized with `-O`; Android runs Debug instrumentation. Keep the app visible and phone unlocked for foreground measurements. A benchmark-only Wi-Fi lock is released on completion/failure; its held flag does not prove effective radio mode. Socket buffer hints and effective sizes are reported. `socketReadMs` and `recordDeliveryMs` separate socket waiting from authenticated delivery.

Record buffers are `profile.maximumEnvelope + 5` bytes. Session authentication, native validation, counters, framing and write deadlines retain production behavior.

## Raw TCP comparison

`LanNativeTest#rawSocketBaseline` accepts a UUID in `aniceRawRun`, `aniceRawMiB=4|16|100` and `aniceRawWifiLock=true|false`. It uses matched bidirectional byte counts and SHA-256 checks, without encrypted records, transfer credit or destination storage.

Reads allow ten seconds without progress; the final receiver-confirmation ACK allows sixty seconds for TCP backlog drainage. Cleanup releases the lock, closes the server and removes only the run-owned directory.

Native interchange scripts target the normal Android test package. Use a prepared test installation, not an unrelated production app. See [performance](../../docs/PERFORMANCE.md) for record costs and instrumentation.
