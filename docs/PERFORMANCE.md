# Performance

aniCe throughput is governed by the authenticated record path: every application byte is sealed into an AES-256-GCM record, framed into a TCP or GATT envelope, and accompanied by live native identity and trust validation. This guide records acceptance targets, the current cost model and measurement limits. Wire bounds belong to the linked protocol contracts.

## Budgets and gates

| Bound | Value | Kind | Origin |
| :--- | :--- | :--- | :--- |
| LAN transfer throughput | ≥ 8 MiB/s in each direction | physical acceptance gate | [LAN benchmark](../protocol/lan/BENCHMARK.md) |
| Connected-idle CPU | ≤ 0.5% of one core | objective | Connected-idle objective |
| Control round trip | ≤ 100 ms with 25 ms added latency | physical acceptance gate | [LAN benchmark](../protocol/lan/BENCHMARK.md) |
| Standard record plaintext | 4,000 bytes | protocol | [Session contract](../protocol/session/README.md) |
| Profile-4 record plaintext | 524,416 bytes | protocol | [LAN transfer profile](../protocol/lan/TRANSFER_PROFILE.md) |
| Legacy profile-3 record plaintext | 262,144 bytes | protocol | [LAN transfer profile](../protocol/lan/TRANSFER_PROFILE.md) |
| Records per direction | 2^20, then fresh EDHOC | protocol | [Session contract](../protocol/session/README.md) |
| Session lifetime | 3,600 s; renewal at 3,300 s or 2^20 − 1024 records | protocol | [Session contract](../protocol/session/README.md) |
| Queued envelopes | 8 / 32,768 bytes (standard); 4 / 1,048,700 bytes (profile 3); 4 / 2,097,788 bytes (profile 4) | protocol | [LAN transfer profile](../protocol/lan/TRANSFER_PROFILE.md) |
| Frame assembly deadline | Before readiness/header/handshake: 10 s absolute; secured encrypted records: 10 s without progress, 60 s absolute | protocol | [LAN contract](../protocol/lan/README.md) |
| Socket write deadline | 10 s absolute | protocol | [LAN contract](../protocol/lan/README.md) |
| Session CBOR budget | 4,096 bytes standard; 262,144 bytes profile 3; 524,416 bytes profile 4; 512 items; 8 levels | protocol | [Session contract](../protocol/session/README.md) |
| Transfer chunk and credit | 3,072 bytes / 4 advertised BLE chunks (v1 protocol ceiling: 64); 131,072 bytes / 8 chunks (v2); 262,016 bytes / 8 chunks (v3); 524,288 bytes / 8 chunks (v4) | protocol | [Transfer contract](../protocol/transfer/README.md) |

Wire bounds are contracts, not tuning knobs. Changing a record bound requires a protocol revision that both peers negotiate before EDHOC.

The isolated [raw TCP diagnostic](../protocol/lan/BENCHMARK.md) can compare normal Wi-Fi policy with a temporary performance lock using matched payload sizes. Its rates exclude session validation, transfer credit and file storage; a held lock does not establish effective radio mode or a production throughput improvement.

**Derived per-record wall budget at the 8 MiB/s gate:**

| Record payload | Records per second | Wall budget per record |
| :--- | ---: | ---: |
| 524,288 bytes (profile 4 v4 chunk) | 16.0 | 62.5 ms |
| 262,016 bytes (legacy profile 3 v3 chunk) | 32.0 | 31.3 ms |
| 4,000 bytes (standard) | 2,097 | 477 µs |
| 3,072 bytes (transfer v1 chunk over a standard record) | 2,730 | 366 µs |

At 8 MiB/s, 4,000-byte records require about 2,097 records per second, versus 16 for full profile-4 chunks. Larger records amortize live identity/trust validation; payload copies and storage costs still scale with bytes. Measure both record overhead and end-to-end throughput.

## Bottlenecks and measurement limits

Live native key validation, payload copies, transport backpressure and Android document-provider I/O all contribute to record cost. Larger negotiated records reduce validation frequency per byte; the cost varies by device and must be measured. A per-record budget is not a guarantee that KeyStore, storage or Wi-Fi meets it. See [physical LAN results](../protocol/lan/BENCHMARK.md#verification-results).

Socket reads feed a bounded ordered queue rather than awaiting application storage inline. Transfer chunk decoding runs off the presentation thread; state mutation retains its serial owner. Full queues suspend ingress without dropping accepted records. ACK credit follows successful writes, not queue admission.

## Per-record cost model

### Android, sending one 524,288-byte profile-4 chunk

| Stage | Payload-sized allocations | Payload copies | Anchor |
| :--- | ---: | ---: | :--- |
| Source read into one per-file buffer | 0 | 0 | `TransferSender.kt` send loop |
| Chunk CBOR node from the reused buffer | 1 | 1 | `TransferWire.chunkFrom`, `Cbor.Bytes` |
| Envelope CBOR encode | 1 | 1 | `SessionCbor.Encoder` |
| AES-GCM seal and record assembly | 1 | 0 | `RecordCipher.seal` |
| TCP framing into transport scratch | 0 | 1 | `LanFraming.encodeInto`, `AndroidLanTransport.send` |
| Socket write | 0 | 0 | `AndroidLanTransport.send` |

### Android, receiving one 524,288-byte profile-4 chunk

| Stage | Payload-sized allocations | Payload copies | Anchor |
| :--- | ---: | ---: | :--- |
| Frame assembly | 1 | 1 | `LanFraming.feed` |
| AES-GCM open | 1 | 0 | `RecordCipher.open` |
| Envelope CBOR decode | 1 | 1 | `SessionCbor.decodeSequence` |
| Storage write and SHA-256 | 0 | 0 | `TransferReceiver.kt` receive path |

### macOS, sending one 524,288-byte profile-4 chunk

| Stage | Payload-sized allocations | Payload copies | Anchor |
| :--- | ---: | ---: | :--- |
| Full source read into owned `Data` (short reads append) | 1 | 0 | `TransferSendStorage.readChunk` |
| Transfer envelope CBOR encode | 1 | 1 | `SessionCbor.encodeValues` |
| AES-GCM ciphertext | 1 | 0 | `SessionRecordCodec.seal` / CryptoKit |
| Record assembly | 1 | 1 | `SessionRecordCodec.seal` |
| TCP framing | 1 | 1 | `LanFraming.encode` |
| `NWConnection` submission | 0 | 0 | `LanTcpTransport.submit`; Network.framework ownership is platform-managed |

### Transfer scheduling and record processing

LAN senders negotiating more than 4,096 chunk bytes begin each file/resume with one chunk of at most 4,096 bytes and wait for advancing, correlated acknowledgement. Confirmation within 100 ms enables the full negotiated chunk size and window (up to eight 524,288-byte profile-4 chunks, 4,194,304 file bytes; legacy profile 3 is capped at 2,096,128 bytes). Slower initial confirmation, or a later gap above one second between advancing ACKs, constrains subsequent sends to chunks of at most 65,536 bytes and at most two unacknowledged chunks (128 KiB total), always within peer limits. Window changes apply between source reads; already submitted bytes drain before more data fits a reduced budget.

Five seconds after the last probe, the next advancing ACK starts a fresh probe if the window is fully confirmed, or requests a one-chunk local budget between source reads so outstanding fallback data drains first. Recovery does not require a run of ACK gaps under 100 ms: a 64-KiB chunk acknowledged every 100 ms is only about 640 KiB/s, and using that same interval as the recovery gate can keep a faster link stuck at its fallback rate. Source idle time over 100 ms resets this retry interval when sending resumes. Only a fully confirmed fresh probe within 100 ms restores the negotiated chunk size and window. Drain time is excluded from the fresh probe timing; partial probe confirmation cannot reopen the large window. Every new file/resume starts with a fresh probe.

Probe timing starts once encoded bytes are ready for submission, excluding source IO and encoding. It includes session admission, live validation, transport, receiver storage and scheduling costs, not just network RTT. After a fully drained window, the next submission resets the advancing-ACK gap origin so source idle time cannot trigger slow-path fallback. Outstanding-data stalls still shrink the window. Large-chunk LAN receivers calculate the size-based ACK cadence using the smaller of the last successfully written chunk and the negotiated maximum. With a negotiated maximum above 4,096 bytes, every chunk smaller than that maximum returns credit immediately. Qualification probes and 65,536-byte fallback chunks therefore exclude the intentional coalescing wait; full-size chunks retain the quarter-window ACK cadence. The existing 20-ms receiver ACK timer supplies feedback below the size-based cadence. BLE and standard-sized negotiation retain their existing limits. For larger-chunk LAN negotiation, 4-KiB qualification probes remain separate from sustained fallback. Sustained fallback uses chunks of up to 64 KiB, reducing record and validation frequency per file byte by up to sixteen times compared with continuous 4-KiB chunks. Its 131,072-byte outstanding-data cap replaces the maximum negotiated capability-3 credit of 2,096,128 bytes. This cap bounds bytes ahead of controls, not elapsed control latency on a delayed or lossy path; native validation still runs for each record.

Session-control classification validates full CBOR structure and canonical map order while omitting byte-string value materialization; the feature decoder still owns the payload copy. This removes one payload-sized allocation/copy per incoming transfer record on each platform without suppressing malformed-CBOR checks.

Source reads and transfer-chunk CBOR construction/encoding run in the existing source-storage actor on Mac and in the existing IO dispatch on Android. The Mac source retains a full FileHandle read directly and appends only on a short read; Android retains its per-file reusable read buffer. Both CBOR encoders measure the bounded output before writing; Mac reserves that exact `Data` capacity and Android writes into one exact-size array. Immutable encoded chunks return to the feature owner before epoch checks, credit accounting and session submission. There is at most one unsent prepared chunk, and security validation remains per record.

Transfer payload decoding runs off the main actor in one awaited worker per ordered ingress delivery. Immutable bytes and the negotiated chunk bound cross that boundary; cancellation, transfer epoch and channel generation are checked before applying results. This removes chunk CBOR work from presentation without adding a buffering stage or changing record validation. Debug media timing records input/submission/result/presentation events on Android and receipt/native-result/result-submission events on Mac using local monotonic clocks and existing subscription/command identifiers. TCP submission denotes local acceptance, not a remote acknowledgement. Opt-in record timing separates native validation, transport submission and application delivery using process-local object identifiers, payload sizes and local durations; it never logs keys or payloads. Android enables record timing when `AniCeMediaTiming` is DEBUG at process startup; Mac uses `ANICE_MEDIA_TIMING=1`. Command traces include the selected transport.

`SessionRecordCodec.seal` builds one reserved record buffer instead of chaining `+` concatenations, and `LanFraming.encode` builds one reserved frame buffer for the same reason. CryptoKit still allocates ciphertext before record assembly; `open` copies the header, ciphertext and tag out of the record before handing them to `AES.GCM.SealedBox`.

Record validation, seal/open and submission events include the secure-channel object identifier, local generation, negotiated profile and directional sequence. Monotonic start/end timestamps correlate overlapping send/receive stages within one process; peer clocks are not synchronized. Seal/open timing includes failed calls. Sequence metadata is diagnostic only and never changes nonce ownership. Timing remains opt-in and does not format log messages when disabled.

Opt-in LAN timing also emits `ingress_backpressure` for the awaited bounded-queue push and `ingress_delivery` for the consumer's complete session receive call, including authenticated validation and application delivery. Backpressure measures producer suspension and handoff overhead, not an envelope's residence time in the queue. Delivery durations include failed calls. These events use the existing timing switch, process-local transport identifier and envelope size; they contain no payloads. Compare the full consumer duration with session `validation` and application `delivery` durations on the same local timeline; their nested durations must not be added together.

LAN `socket_read` timing measures each native read; on Mac it includes the callback's transport-actor scheduling delay, separately reported as `socket_callback_wait`. Android separates `socket_writer_wait`, IO `socket_write_dispatch` and blocking `socket_write`; local write completion does not establish peer delivery. Mac incomplete-frame failures include pending-read age, last nonempty callback age and byte count even when opt-in timing is disabled. These distinguish socket wait from callback scheduling and feature delivery without logging endpoints or payloads.

Android receive storage shares one `Dispatchers.IO.limitedParallelism(1)` dispatcher across storage instances. Controller-owned provider setup, receiver cleanup and checkpoint writes use that same dispatcher; each storage instance retains its mutex. All storage methods use the injected dispatcher, including restore, prefix hashing, synchronization and publication. This limits simultaneous blocking provider work; it does not provide a dedicated thread or a FIFO feature-ingress consumer. Source preparation and CPU-bound CBOR decoding retain their existing executors.

Opt-in receive-storage timing emits `storage_create`, `storage_restore`, `storage_write`, `storage_flush`, `storage_fileIdentity`, `storage_prefixDigest`, `storage_finish` and `storage_discard` on both platforms. Android additionally emits matching `storage_wait_*` events from call entry through dispatcher and mutex acquisition. Work durations include failures; Android wait durations exclude the operation itself. Mac work timing starts after entering the storage actor and excludes actor-queue wait. Storage events identify the storage owner; profile/sequence fields are unspecified because storage does not own encrypted records. These durations nest inside authenticated application delivery and must not be added to that total. Disabled timing formats no storage event strings.

On macOS, normal TCP EOF closes the bounded frame hand-off to new input and defers the transport-end callback until its single consumer finishes accepted delivery. A ten-second absolute drain deadline retires the transport with `ETIMEDOUT` if delivery stalls. Explicit close and transport, authentication or delivery failures retire immediately; no later delivery callback starts after retirement. Frame bounds, nonce ordering and write deadlines are unchanged.

### Non-payload cost per record

Android GATT successful fragment callbacks emit no routine log entry; logical-message completion retains its debug trace. Failure and stale-callback logs carry operation context without payload data.

Independent of payload size, each record also pays: one nonce construction, one `Cipher.init`, two `updateAAD` calls, one big-endian header write and read, one budget reserve/release under a lock, and one coroutine dispatch onto `Dispatchers.IO`. On macOS it pays one actor hop and one `Data` concatenation for the AAD. On the LAN receive path on both platforms each record additionally pays one bounded-queue hand-off between the read loop and the delivery consumer; that hand-off is what lets the socket stay read while an earlier record is still being decoded, validated and written.

Android GATT fragmentation caps native values at 512 bytes even at MTU 517; logical message limits and fragment headers are unchanged. Android session control selection, issuance and completion share the receive/maintenance mutex; application DATA submission releases that mutex to preserve full-duplex record processing. Transfer send calls remain cancellable through admission and native validation before nonce reservation. After reservation, SecureSession owns completion: Android runs sealing, submission and post-write validation in `NonCancellable` under the send mutex; Mac runs submission and post-write validation in one owned task after sealing. Producer cancellation is reported after that work finishes; transport or native-validation failure retires the session, and the record is never replayed. Transfer cleanup cancels stream, ACK and upgrade producers; epoch checks fence their later callbacks. BLE submission completion waits on native callbacks rather than 20-ms polling. BLE transfer credit is capped at four chunks, reserving ingress headroom for controls. Recovery checkpoints run on storage workers only when logical progress changes, at most once per five seconds plus forced pauses, file boundaries and publication intent; unchanged progress and idle connections perform no checkpoint writes. File publication waits for its intent checkpoint. Progress rate uses 21 observations at 250-ms spacing (about five seconds) to cover bursty confirmations without retaining a lifetime average. Transfer diagnostics log transport, negotiated chunk size and window once per file start, plus local chunk or credit changes; retirement logs record the failure type. Per-record timing is opt-in; normal transfer diagnostics do not log every chunk. Android publishes throttled progress updates through the existing transfer-service notification; background offers retain their separate silent notice. These operations do not remove native identity/trust validation or change wire bytes.

Session DATA admission retains at most eight waiting callers before sealing. Payloads remain owned by their feature callers. Requests up to 4,000 bytes take priority over larger DATA, with FIFO ordering within each class and one bulk turn after four small-record turns when both classes are waiting. BLE-sized chunks participate in the same FIFO class as other small requests. Cancellation removes an unadmitted waiter without retiring a healthy channel; retirement rejects all waiting admissions. A cancelled operation that already closed its native session still follows normal owner retirement. Session controls still flush before admitted application DATA. Native validation, nonce reservation, transport queue bounds, transfer credit and TCP ordering remain unchanged. The `admission` timing event measures entry through permit acquisition; it does not imply remote receipt.

Authenticated transfer chunks enter one feature-owned FIFO before shared application delivery returns. The pending-byte bound is `min(advertisedReceiveChunkBytes × window + 65,536, 2,097,152)`; the record bound is `min(window × 8, 64)`. Both include the active consumer until storage handling completes. Header classification allocates no payload-sized buffer; full CBOR and transfer validation remains in the worker. Android decoding uses Default while all receiver storage shares the injected single-parallelism IO dispatcher; Mac decoding uses a detached task and storage remains actor-owned. Queued chunks emit no progress, ACK or successful application activity. Full capacity suspends ingress. Receiver resumes drain earlier accepted work within ten seconds, then share the FIFO consumer with chunk writes through prefix validation and channel rebinding; epoch invalidation discards pending work and fences active completion. Normal EOF and authenticated close allow at most ten seconds to drain accepted work. Opt-in `transfer_ingress_admission` and `transfer_ingress_delivery` events separate local queue admission from decode/storage execution; neither event proves peer receipt. Already-submitted TCP bytes remain ordered and cannot be overtaken.

## Native validation

Native identity, key presence and protection, durable journal integrity, and pinned trust checks are re-evaluated for every authenticated operation. The exact contract is stated in the [LAN transfer profile](../protocol/lan/TRANSFER_PROFILE.md): Android validates before sealing and after awaited transport submission, with generation and deadline checks bracketing synchronous encryption; receive authentication is synchronous and is followed by native validation before counter advancement or application delivery.

| Path | Validations per record | Where |
| :--- | ---: | :--- |
| Android `send` | 2 | `SecureSession.kt`, `SecureSession.kt` |
| Android `receive` | 1 | `SecureSession.kt` |
| macOS `send` | 2 | `SecureSession.swift`, `SecureSession.swift` |
| macOS `receive` | 1 | `SecureSession.swift` |

The intermediate validation that previously sat between the capacity await and nonce reservation was removed on both platforms. It was redundant: the reservation transition and the post-submission check already fence generation and deadline, `checkTime` still rejects a closed, expired or retired session before encryption, and no sealing, submission or delivery can occur without a preceding and following validation. On Android the receive-path validation moved behind synchronous tag verification, so an unauthenticated record can no longer trigger KeyStore work; the profile contract already specified that ordering.

Validation must remain live; throughput improvements must preserve it.

## Hot-path inventory

| File | Symbol | Owns |
| :--- | :--- | :--- |
| `apps/android/.../infrastructure/session/SecureSession.kt` | `RecordCipher` | Per-direction provider cipher, key spec, AAD suffix, header buffer |
| `apps/android/.../infrastructure/session/SecureSession.kt` | `RecordCipher.seal` / `.open` | Header write, nonce, AAD updates, record assembly |
| `apps/android/.../infrastructure/session/SecureSession.kt` | `SecureSession.send` / `.receive` | Capacity, nonce burn, validation fencing, state transitions |
| `apps/android/.../infrastructure/session/SessionCbor.kt` | `Encoder` | Measure-then-write deterministic CBOR into one exact buffer |
| `apps/android/.../infrastructure/session/SessionCbor.kt` | `decodeSequence` | Bounded decode with single-copy byte slicing |
| `apps/android/.../infrastructure/lan/LanFraming.kt` | `encodeInto` | Framing into caller-owned scratch |
| `apps/android/.../infrastructure/lan/AndroidLanTransport.kt` | `submit`, `receive` | Socket write, write watchdog, read loop, framing scratch, bounded ordered ingress hand-off |
| `apps/android/.../features/transfer/TransferController.kt` | send loop | Per-file source buffer, chunk framing, credit waits |
| `apps/android/.../infrastructure/identity/IdentityService.kt` | `DEVICE_ID` | Journal validation on every identity read |
| `apps/macos/aniCe/Infrastructure/Session/SecureSession.swift` | `SessionRecordCodec.seal` / `.open` | Record assembly and verification |
| `apps/macos/aniCe/Infrastructure/Session/SecureSession.swift` | `SecureSession.send` / `.receive` | Capacity, nonce burn, validation fencing, state transitions |
| `apps/macos/aniCe/Infrastructure/Session/SessionConnection.swift` | `receive` | Envelope ordering, gate release before application delivery |
| `apps/macos/aniCe/Infrastructure/LAN/LanTcpTransport.swift` | `LanIngressQueue` | Bounded ordered ingress hand-off with producer backpressure |
| `apps/macos/aniCe/Infrastructure/LAN/LanTcpTransport.swift` | `received`, `drain` | Read loop, framing, delivery consumer, write retirement |
| `apps/macos/aniCe/Infrastructure/Session/SessionCbor.swift` | `encodeValues`, `decodeSequence` | Exact-capacity deterministic CBOR output; bounded decode without re-basing copies |
| `apps/macos/aniCe/Infrastructure/LAN/LanFraming.swift` | `encode`, `feed` | Frame construction and assembly |

## Optimization rules for this repository

1. **Reduce work per record, then per byte.** Allocation counts and copy counts per record dominate CPU and GC far more than constant factors inside a stage. Count them before optimizing.
2. **Never trade security validation for throughput.** Identity, protection, journal and trust validation stays live on every authenticated operation.
3. **Keep wire bytes identical.** Optimizations must not change a nonce, an AAD byte, a header layout, a CBOR ordering, or a bound. Independent vectors under `protocol/test-vectors/` are the guardrail.
4. **Reuse scratch only under the owner's serializer.** A shared buffer is safe exactly when every use of it holds the lock that serializes that direction. An assembled envelope leaves its owner's scope when it is handed to the ingress queue, so it is never reused: the framing cannot know when the consumer has finished with it. Both `LanFraming.feed` implementations therefore return an owned value the framer no longer references, and a queue entry must never be routed back to the framer.
5. **Preserve bounds and failure ordering.** Every bound check must still fail with the same typed reason, and a removal that changes which error wins between two failures is a behavior change, not an optimization.
6. **Measure at the tier you claim.** Host JVM unit tests prove wire bytes and arithmetic. They never prove radio throughput, socket behaviour, or KeyStore latency.

## Optimization decisions

- Receive-frame buffers remain owned by their queued envelope. Pooling them without a consumer return path would permit reuse while delivery still reads them.
- Credit waiters detach before resumption. Immediate coroutine resumption can install a successor; draining a live collection would spin on newly queued waiters.
- Session locks are released before application delivery. Single-consumer transport ordering preserves record order without holding cryptographic admission across feature/storage work.
- Frame-bounded reads keep ingress backpressure from consuming the following frame's assembly deadline. Secured records retain bounded progress deadlines.
- Moving per-record watchdogs to transport lifetime changes deadline semantics. No measured benefit currently justifies that change.

## Open candidates

1. **Feature DATA dispatch.** Feature delivery still enters through `Dispatchers.Main.immediate`, where every feature handler publishes Compose state. Moving the whole dispatch off main needs per-feature marshalling; transfer chunks leave shared dispatch after bounded admission, so their decode and storage awaits no longer hold up later handlers. Other handlers still await their own work.
2. **macOS `SessionRecordCodec.open` copies.** The header (14 bytes), ciphertext and tag (16 bytes) are materialized before `AES.GCM.SealedBox` is constructed; only the ciphertext copy scales with chunk size. Passing a ciphertext slice may remove that payload-sized copy but keeps the full record buffer alive longer.

## Measurement procedure

Run repository-relative commands from the repository root.

| Tier | Command | Proves |
| :--- | :--- | :--- |
| Android host | `python3 scripts/verify-suite.py --only android` | JVM tests, lint and instrumentation test compilation |
| macOS host | `python3 scripts/verify-suite.py --only macos` | arm64 Release build, architecture/signature checks and hosted tests |
| Interchange | `python3 scripts/verify-suite.py --only interchange --serial PHONE_SERIAL` | Cross-platform identity, LAN and session agreement with disposable test credentials |
| Structure | `python3 scripts/check-structure.py` | Dependency direction, documentation links, Xcode membership |
| Physical | `python3 scripts/verify-lan-interchange.py --serial PHONE_SERIAL --benchmark-mib 16\|100\|1024 --window 32\|64` | Socket throughput, process CPU, Mac peak RSS and Android allocation/GC counters |

Physical runs are the only tier that may be cited for the 8 MiB/s gate. Debug instrumentation is the only configuration measured so far. Release, battery, minimum-OS and responsiveness acceptance remain separate requirements. Intel is unsupported.

## Active Now Playing observation

Enabling optional Mac Home/companion Now Playing display correlates with approximately 15–20% app CPU during playback and peaks around 35% with concurrent Phone→Mac transfer. These are interactive Debug runtime observations, not a controlled Release profile or battery measurement. Connected-idle results do not describe this workload. A visible/hidden playback comparison and CPU call-tree capture are needed before attributing the cost to rendering, artwork decoding, metadata delivery or record processing. 

## Android capacity notification regression

A physical Debug startup on the SM-A346E previously saturated the main thread at 99–103% of one core: `clearCapacityWaiters` resumed a producer that immediately requeued itself into the same drain loop. It now snapshots existing waiters before completing them. A regression test requires one additional send attempt per capacity event.

On the same phone after the fix, three short idle samples reported 0.0% main-thread CPU and a warm activity launch took 649 ms. Identity/trust journal hashes were unchanged. The startup sample still contained 9/27 janky frames; these observations establish removal of that spin, not general startup or battery acceptance.

Playback thumbnail base64 decoding, resizing, JPEG encoding and hashing run off MainActor; generation and recording checks fence completed work. Prepared Mac display images are reused. Command-triggered position samples use a separate serial queue from catalog observation and command execution. Android keeps only the current recording’s displayed image and releases it on track or subscription replacement; there is no artwork history cache.

Current LAN revision 3 uses [record profile 4](../protocol/lan/TRANSFER_PROFILE.md) and capability 4 for 512-KiB chunks, with eight-chunk maximum credit. Larger chunks increase per-record buffering and control head-of-line delay; sustained fallback retains its existing 128-KiB cap.
