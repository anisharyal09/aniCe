# Performance

This guide describes the BLE/LAN record path, resource budgets and instrumentation. Wire limits belong to the linked contracts. Performance targets are not guaranteed device throughput.

## Targets and bounds

| Item | Value | Source |
| --- | --- | --- |
| LAN throughput target | 8 MiB/s in each direction | [Benchmark tool](../protocol/lan/BENCHMARK.md) |
| Connected-idle CPU target | 0.5% of one core | Local profiling |
| Control RTT target | 100 ms with 25 ms added latency | Local profiling |
| Standard plaintext | 4,000 bytes | [Session](../protocol/session/README.md) |
| LAN profile 3 / 4 plaintext | 262,144 / 524,416 bytes | [LAN profiles](../protocol/lan/TRANSFER_PROFILE.md) |
| Session lifetime / record bound | 3,600 seconds / `2^20` records per direction | [Session](../protocol/session/README.md) |
| Renewal margin | 3,300 seconds or `2^20 − 1024` records | [LAN renewal](../protocol/lan/RENEWAL.md) |
| Frame assembly | 10 seconds without progress; 60 seconds total for secured encrypted bodies | [LAN](../protocol/lan/README.md) |
| Socket write deadline | 10 seconds | [LAN](../protocol/lan/README.md) |
| CBOR structure | 512 items, 8 levels; profile-specific byte limit | [Session](../protocol/session/README.md) |
| Receive credit | Four 3,072-byte BLE chunks; up to eight negotiated LAN chunks | [Transfer](../protocol/transfer/README.md) |

Larger records amortize per-record validation. At 8 MiB/s:

| Payload | Records/second | Wall budget/record |
| --- | ---: | ---: |
| 524,288 bytes | 16 | 62.5 ms |
| 262,016 bytes | 32 | 31.3 ms |
| 4,000 bytes | 2,097 | 477 µs |
| 3,072 bytes | 2,730 | 366 µs |

Payload copying and storage work still scale with bytes. Measure native key access, record processing, socket delivery and destination I/O separately.

## Record path

### Sending

1. Read one source chunk on the storage/IO worker.
2. Encode bounded deterministic CBOR into an exact-size buffer.
3. Enter the shared DATA admission queue.
4. Validate native identity/trust, reserve a nonce and seal AES-GCM.
5. Submit the framed record and perform post-write native validation.

Android reuses its source read buffer and per-direction provider cipher. Encryption writes directly into the record buffer; TCP framing copies into transport-owned scratch. Mac retains a full source `Data` read, then builds owned encoded, encrypted and framed buffers. CryptoKit owns its ciphertext allocation.

### Receiving

1. Validate frame header/length and assemble one bounded envelope.
2. Authenticate the exact expected record sequence.
3. Revalidate native identity/trust before advancing or delivering.
4. Admit a transfer chunk to the feature's bounded FIFO.
5. Decode and write on the worker; acknowledge successful storage progress.

The socket reader and feature worker have separate bounded queues. A full queue applies backpressure without dropping accepted records. Header/control classification skips byte-string materialization; only the feature decoder owns the payload copy.

## Per-record cost model

Counts are payload-sized allocations and copies for one 524,288-byte profile-4 chunk. The anchor names the owning implementation.

**Android send**

| Stage | Allocations | Copies | Anchor |
| --- | ---: | ---: | --- |
| Source read into one per-file buffer | 0 | 0 | `TransferSender.kt` send loop |
| Chunk CBOR node from the reused buffer | 1 | 1 | `TransferWire.chunkFrom`, `Cbor.Bytes` |
| Envelope CBOR encode | 1 | 1 | `SessionCbor.Encoder` |
| AES-GCM seal and record assembly | 1 | 0 | `RecordCipher.seal` |
| TCP framing into transport scratch | 0 | 1 | `LanFraming.encodeInto`, `AndroidLanTransport.send` |
| Socket write | 0 | 0 | `AndroidLanTransport.send` |

**Android receive**

| Stage | Allocations | Copies | Anchor |
| --- | ---: | ---: | --- |
| Frame assembly | 1 | 1 | `LanFraming.feed` |
| AES-GCM open | 1 | 0 | `RecordCipher.open` |
| Envelope CBOR decode | 1 | 1 | `SessionCbor.decodeSequence` |
| Storage write and SHA-256 | 0 | 0 | `TransferReceiver.kt` receive path |

**Mac send**

| Stage | Allocations | Copies | Anchor |
| --- | ---: | ---: | --- |
| Full source read into owned `Data` (short reads append) | 1 | 0 | `TransferSendStorage.readChunk` |
| Transfer envelope CBOR encode | 1 | 1 | `SessionCbor.encodeValues` |
| AES-GCM ciphertext | 1 | 0 | `SessionRecordCodec.seal` / CryptoKit |
| Record assembly | 1 | 1 | `SessionRecordCodec.seal` |
| TCP framing | 1 | 1 | `LanFraming.encode` |
| `NWConnection` submission | 0 | 0 | `LanTcpTransport.submit`; Network.framework ownership is platform-managed |

Independent of payload size, each record also pays a nonce construction, one cipher init, two AAD updates, one header read/write and one budget reservation and release. Standard-profile 3,072-byte transfer chunks at 8 MiB/s need about 2,730 records and live native validations per second, which is why larger negotiated profiles exist.

## Scheduling and storage

- DATA admission holds at most eight unsealed callers. Standard-sized requests take priority, with one bulk turn after four small turns when both classes wait.
- Each sender retains at most one unsent prepared chunk. Session/transport queues retain sealed records only within their negotiated limits.
- The transfer ingress FIFO counts its active consumer. Its byte bound is `min(chunkBytes × window + 65,536, 2,097,152)` and its record bound is `min(window × 8, 64)`.
- Android receiver storage, provider setup, cleanup and checkpoints share `Dispatchers.IO.limitedParallelism(1)` with per-file mutexes. Source preparation and CPU-bound decoding use their separate workers.
- Mac receive storage remains actor-owned. Immutable encoded/decoded data crosses actor boundaries before owner-generation checks.
- Capacity and credit waiters are detached before resumption so an immediately requeued waiter cannot enter the same drain.
- Checkpoints write on changed progress, at most once per five seconds plus pauses, file boundaries and publication intent. Unchanged idle state performs no checkpoint writes.

## Adaptive LAN window

A sender negotiating chunks above 4,096 bytes starts each file/resume with one acknowledged chunk of at most 4,096 bytes. Confirmation within 100 ms enables the negotiated window, up to eight 512-KiB chunks on profile 4.

A slower initial probe or an advancing-ACK gap above one second constrains subsequent sends to at most two 65,536-byte chunks: 128 KiB outstanding, always inside peer credit. Already-submitted bytes drain before a smaller window applies.

After a five-second cooldown, advancing credit allows a fresh probe once outstanding data drains. Only an acknowledged fresh probe restores the larger window. Source preparation and fully drained idle time are excluded from probe/ACK-gap timing.

On large-chunk LAN links, smaller-than-negotiated chunks return credit immediately. Full-size chunks use the quarter-window byte threshold; a 20-ms timer also flushes written progress. These rules bound bytes ahead of controls, not elapsed latency on a lossy path.

## Validation, cancellation and renewal

Native identity, key protection and active trust remain live for authenticated operations. Sending validates before sealing and after submission; receiving validates after tag authentication and before delivery. Deadline-only waits perform no storage or KeyStore/Keychain reads.

Producer cancellation remains effective before nonce reservation. Once sealed, the session owns submission and post-write validation; failure burns the sequence and retires the channel. No sealed record is replayed.

LAN renewal closes sealing admission and drains nonce-owned submissions before fresh EDHOC. It retains transport/feature queues and the channel descriptor. Cumulative monotonic maintenance snapshots exclude that interval from transfer capacity, resume and file-confirmation waits. Old-epoch deadline results cannot retire the successor. Security, frame/write, offer-assembly and recovery deadlines remain absolute.

Normal TCP EOF permits at most ten seconds for accepted delivery to drain. Explicit close, authentication failure and native transport failure retire immediately.

## Observed costs

Measured on Debug builds, the optional Mac Home/companion Now Playing display used about 15–20% of one app CPU during playback, peaking near 35% with a concurrent phone-to-Mac transfer. Treat these as observations from earlier builds, not targets.

## Instrumentation

Record timing is opt-in. Android enables it when `AniCeMediaTiming` is DEBUG at process startup; Mac uses `ANICE_MEDIA_TIMING=1`. Events include process-local owner/generation, profile, direction, sequence, byte count and monotonic duration—not keys or payloads.

| Events | Scope |
| --- | --- |
| `admission`, `validation`, `seal`, `open`, `submission` | Session processing |
| `socket_read`, `socket_writer_wait`, `socket_write_dispatch`, `socket_write` | Native socket work |
| `socket_callback_wait` | Mac transport-actor scheduling |
| `ingress_backpressure`, `ingress_delivery` | Bounded transport handoff |
| `transfer_ingress_admission`, `transfer_ingress_delivery` | Transfer worker handoff |
| `storage_*`, Android `storage_wait_*` | Storage work and waiting |

Some durations nest; do not add a full delivery duration to its validation/storage components. Peer clocks are not synchronized. Local socket completion is not authenticated remote delivery.

## Development tools

Use the [Android](../apps/android/README.md), [Mac](../apps/macos/README.md) and [contribution](../CONTRIBUTING.md) instructions for tests.

For isolated native profile-4 measurements on a prepared test installation:

```sh
python3 scripts/verify-lan-interchange.py --serial PHONE_SERIAL \
  --profile lan-transfer-512 --benchmark-mib 16 --window 8
```

The [benchmark contract](../protocol/lan/BENCHMARK.md) defines payloads and metrics. Native interchange scripts target the normal Android test package; do not run them against an unrelated installed production app. Raw TCP excludes records, transfer credit and file storage and must not be presented as file-transfer throughput.

## Optimization constraints

- Preserve wire bytes, nonce ownership, live validation and typed failure ordering.
- Reuse scratch only under its owner serializer. A buffer handed to another consumer cannot be reused until ownership returns.
- Keep controls bounded and transport ordered; queued TCP bytes cannot be overtaken.
- Separate hardware/network measurements from source-level cost estimates.
- Keep performance experiments out of identity, trust and feature authorization.
