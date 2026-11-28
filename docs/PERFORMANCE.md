# Performance

This guide describes the BLE/LAN record path, resource budgets and instrumentation. Wire limits belong to the linked contracts.

## Performance targets

The LAN benchmark targets **8 MiB/s in each direction**. It transfers data in
memory; real file transfers also depend on the network, devices and storage.
The connected-idle CPU goal is **0.5% of one core**; the control round-trip
goal is **100 ms with 25 ms of added latency**. Neither is a current
measurement. See the [LAN benchmark](../protocol/lan/BENCHMARK.md) for
measurement scope and earlier throughput samples.

## Protocol bounds

| Item | Value | Source |
| --- | --- | --- |
| Standard plaintext | 4,000 bytes | [Session](../protocol/session/README.md) |
| LAN profile 3 / 4 plaintext | 262,144 / 524,416 bytes | [LAN profiles](../protocol/lan/TRANSFER_PROFILE.md) |
| Session lifetime / record bound | 3,600 seconds / `2^20` records per direction | [Session](../protocol/session/README.md) |
| Renewal margin | 3,300 seconds or `2^20 − 1024` records | [LAN renewal](../protocol/lan/RENEWAL.md) |
| Frame assembly | 10 seconds without progress; 60 seconds total for secured encrypted bodies | [LAN](../protocol/lan/README.md) |
| Socket write deadline | 10 seconds | [LAN](../protocol/lan/README.md) |
| CBOR structure | 512 items, 8 levels; profile-specific byte limit | [Session](../protocol/session/README.md) |
| Receive credit | Four 3,072-byte BLE chunks; up to eight negotiated LAN chunks | [Transfer](../protocol/transfer/README.md) |
| Audio Sharing (Mac → Android) | 50 packets/second; 960 stereo frames / 3,840 PCM bytes; at most 3,927 Audio CBOR bytes | [Mac-to-Android audio contract](../protocol/audio-sharing/README.md) |

Both audio directions use 48 kHz stereo PCM16: **192 kB/s (1.536 Mb/s)** of
audio payload, or about **691 MB per hour** of uninterrupted streaming over LAN.
Packet encoding, encryption and network headers add overhead.

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

While Audio Sharing sends Mac audio to the phone, the app initially caps future LAN file chunks at 65,536 bytes and outstanding unacknowledged file data at 131,072 bytes. Fresh advancing audio health may recover credit in 128-KiB steps every four healthy seconds, up to 1 MiB, with future chunks up to 128 KiB. The negotiated chunk-count window and delayed-path qualification still cap actual credit. New underruns, buffering or stale health reset pacing to its initial bound. A policy change fences prepared plaintext before submission; source reads are not rewound or valid transfer bytes discarded. Existing submitted bytes drain normally, and normal transfer policy returns after the listening lease ends.

On large-chunk LAN links, smaller-than-negotiated chunks return credit immediately. Full-size chunks use the quarter-window byte threshold; a 20-ms timer also flushes written progress. These rules bound bytes ahead of controls, not elapsed latency on a lossy path.

## Validation, cancellation and renewal

Listening startup's transfer-drain preflight counts only a currently owned
outgoing file. Terminal/dismissed jobs retain diagnostic counters but no live
file backlog; those counters cannot prolong a later Start. An active sending
file still must drain to the existing 128-KiB bound.

Native identity, key protection and active trust remain live for authenticated operations. Sending validates before sealing and after submission; receiving validates after tag authentication and before delivery. Deadline-only waits perform no storage or KeyStore/Keychain reads.

Producer cancellation remains effective before nonce reservation. Once sealed, the session owns submission and post-write validation; failure burns the sequence and retires the channel. No sealed record is replayed.

LAN renewal closes sealing admission and drains nonce-owned submissions before fresh EDHOC. It retains transport/feature queues and the channel descriptor. Cumulative monotonic maintenance snapshots exclude that interval from transfer capacity, resume and file-confirmation waits. Old-epoch deadline results cannot retire the successor. Security, frame/write, offer-assembly and recovery deadlines remain absolute.

Normal TCP EOF permits at most ten seconds for accepted delivery to drain. Explicit close, authentication failure and native transport failure retire immediately.

## Mac-to-Android audio capture and playback

The Mac tap callback copies Float32 frames into a source-rate 200-ms SPSC ring. It allocates, locks and seals no records; incoming overflow advances the source timeline without overwriting consumer-owned frames. The worker inspects the tap format, converts to 48-kHz stereo and clips to fixed 960-frame PCM16 packets. Packet boundaries expose skipped source intervals instead of padding them.

Android owns a bounded newest-audio queue and native AudioTrack write backlog, including one reserved resampler output. Silent priming closes the audible write gate until actual output-route verification. Worker-side cubic interpolation keeps one stereo phase and a smoothly slewed input/output ratio in 0.997–1.003; it does not use native pitch-preserving timestretching. Balanced starts at a combined 120-ms backlog and adapts within 60–240 ms; the local opt-in Lower delay mode starts at 40 ms and adapts within 20–160 ms. Both retain the 800-ms hard ceiling. An underrun raises a stream-local learned minimum, avoiding repeated low-buffer hunting. Downstream Bluetooth buffering is not included. Native low-latency mode is requested, not assumed.

The native worker requests an effective AudioTrack size and startup floor at three quarters of the Balanced target or half of the Lower delay target, with a 20-ms floor, subject to platform rounding. API 31+ startup-threshold controls reduce unnecessary priming where available; API 29/30 honor the effective buffer's startup requirement. Silent priming verifies the route and drains before the audible gate opens, so silence does not add a second startup backlog. The writer paces pending native frames rather than filling the entire allocated capacity. Receiver trimming subtracts existing native frames from the same combined target. Ordinary gaps/obsolete software audio reset cubic history and use a 5-ms boundary ramp without dropping the current packet or re-priming; excessive native backlog still flushes obsolete writes. Mac consumer trimming keeps the newest 60 ms after a source-worker stall and the model retains three unsent packets plus at most one in submission; callback capacity and sealed-record ownership do not change.

Android opts into bounded worker-side Audio admission after shared record authentication, using an immutable channel route and stream-bound admission fence. Other lifecycle/control DATA stays on the existing ordered Main delivery path; file-chunk admission uses its existing bounded FIFO. Focus, maintenance, retired streams and trust/channel invalidation fence the worker before output writes; presentation receives coalesced receipt notifications and one-second health snapshots. The native player uses a service-owned, audio-priority single-thread scheduler rather than competing with UI/file work on the shared Default pool. Actual output routes remain checked before audible writes and on native routing callbacks. These changes do not bypass native identity/trust validation or increase sealed-record budgets.

The Android panel shows local backlog, buffer target, skipped packets and
underruns. These values do not measure end-to-end latency.

File chunks can enter the existing ingress FIFO on that same worker hook while capacity is available. A full FIFO falls back to existing suspending admission, never drops accepted file data and keeps resume/barrier ordering. Transport capacity events coalesce before presentation so frequent writes cannot accumulate per-record UI tasks. Mac capture reuses prepared conversion buffers off-callback, holds a stream-scoped latency activity and restores unmuted tap output before teardown. Focus and LAN maintenance still close audible writes until fresh route verification.

An elevated learned audio floor may decrease by one 960-frame packet after two
continuous healthy minutes; interruption, rebuffering or a new underrun resets
the interval. Lower targets immediately trim only obsolete software PCM. Native
head observations are bounded by this track epoch's submitted frames so a delayed
post-flush head cannot falsely drain silent priming or become a spurious wrap.
Route-driven startup-threshold increases receive only the missing pending silent
reservation, not a deficit calculated from already-drained lifetime writes.
The top-up retains the original deadline and route/write gate.

Mac transfer-health admission accepts streaming backlog through the valid
Balanced upper target plus two packet-sized accounting reserves (13,440 frames),
rather than treating every healthy buffer above an arbitrary 200 ms as unhealthy.
Fresh advancing health, underrun/staleness contraction, negotiated file limits
and existing delayed-path qualification remain authoritative.

## Phone Audio sender and receiver

Android reads PCM16 in 20-ms packets on a dedicated `THREAD_PRIORITY_AUDIO`
worker. Android's playback-capture path can ignore the requested AudioRecord
buffer size; use the effective frame count for device comparisons. The sender
keeps the newest three unsent packets with a resumed activity or six without
one, plus one in-flight send. Packet construction and encoding
run on the serialized sender outside the capture queue lock. Shared LAN owns
record sealing and submission. The foreground service requests a 90-second
partial wake lock and refreshes it every 20 seconds off the UI thread until
capture ends or the service releases it. A partial wake lock does not control
CPU scheduling, and Android may ignore it in Doze.

The Mac player starts after three packets or an 80-ms fallback. If the render
queue drains for less than 40 ms, it can continue without another prefill.
Longer drains rebuffer; startup, sequence gaps and rebuffering use a 5-ms
fade-in. The eight-packet (160-ms) cap counts buffers still waiting to render,
excluding downstream output-device latency. The player uses the 48-kHz wire
rate; the Mac's mixer or output device can still resample. Neither path
persists PCM.

The preview's opt-in counters separate capture read time, capture interval,
sender wake-up wait (the legacy `presentation_wait` field), queue age at dequeue, encoding and submission on
Android, and arrival interval, receiver admission, sequence gaps and native
output backlog/resync/completion on the Mac. All values are local elapsed
intervals; phone and Mac clocks are not synchronized, submission completion is
not measured delivery, and Mac empty-queue transitions are not measured audible
gaps. Correlating them with manual phase notes can show which stage stalls, not
why, and the instrumentation itself can perturb scheduling.

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
