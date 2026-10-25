# Performance

aniCe throughput is governed by the authenticated record path: every application byte is sealed into an AES-256-GCM record, framed into a TCP or GATT envelope, and accompanied by live native identity and trust validation. This guide records the measurable budgets, the per-record cost model, the code that owns each hot stage, the optimization rules, physical measurement results, and open candidates.

## 1. Budgets and gates

| Bound | Value | Kind | Origin |
| :--- | :--- | :--- | :--- |
| LAN transfer throughput | ≥ 8 MiB/s in each direction | physical acceptance gate | [LAN benchmark](../protocol/lan/BENCHMARK.md) |
| Connected-idle CPU | ≤ 0.5% of one core | objective | [Roadmap](ROADMAP.md) milestone 4 |
| Control round trip | ≤ 100 ms with 25 ms added latency | physical acceptance gate | [LAN benchmark](../protocol/lan/BENCHMARK.md) |
| Standard record plaintext | 4,000 bytes | protocol | [Session contract](../protocol/session/README.md) |
| Profile-3 record plaintext | 262,144 bytes | protocol | [LAN transfer profile](../protocol/lan/TRANSFER_PROFILE.md) |
| Records per direction | 2^20, then fresh EDHOC | protocol | [Session contract](../protocol/session/README.md) |
| Session lifetime | 3,600 s; renewal at 3,300 s or 2^20 − 1024 records | protocol | [Session contract](../protocol/session/README.md) |
| Queued envelopes | 8 / 32,768 bytes (standard); 4 / 1,048,700 bytes (profile 3) | protocol | [LAN transfer profile](../protocol/lan/TRANSFER_PROFILE.md) |
| Frame assembly deadline | Before readiness/header/handshake: 10 s absolute; secured encrypted records: 10 s without progress, 60 s absolute | protocol | [LAN contract](../protocol/lan/README.md) |
| Socket write deadline | 10 s absolute | protocol | [LAN contract](../protocol/lan/README.md) |
| Session CBOR budget | 4,096 bytes standard; 262,144 bytes profile 3; 512 items; 8 levels | protocol | [Session contract](../protocol/session/README.md) |
| Transfer chunk and credit | 3,072 bytes / 64 chunks (v1); 131,072 bytes / 8 chunks (v2); 262,016 bytes / 8 chunks (v3) | protocol | [Transfer contract](../protocol/transfer/README.md) |

Wire bounds are contracts, not tuning knobs. Changing a record bound requires a protocol revision that both peers negotiate before EDHOC.

**Derived per-record wall budget at the 8 MiB/s gate:**

| Record payload | Records per second | Wall budget per record |
| :--- | ---: | ---: |
| 262,016 bytes (profile 3 v3 chunk) | 32.0 | 31.3 ms |
| 4,000 bytes (standard) | 2,097 | 477 µs |
| 3,072 bytes (transfer v1 chunk over a standard record) | 2,730 | 366 µs |

The gate is a record-rate gate, not a byte-rate gate. Native identity and trust validation runs on every authenticated operation and is the only stage that may not be removed, so it sets the floor on record rate. Reaching 8 MiB/s with 4,000-byte records requires 2,097 records per second; 262,016-byte records reduce this to 32. That is why profile 3 exists, and why optimizations are expressed as work removed per record rather than per byte.

## 2. Verified bottlenecks and hardware boundaries

Physical measurement and hardware constraints establish four throughput and latency boundaries on the authenticated record path. Specific test-run transfer telemetry is tracked in [LAN Benchmark Telemetry](../protocol/lan/BENCHMARK.md#verification-results).

1. **Hardware KeyStore IPC ceiling:** Standard transfer v1 carries 3,072-byte chunks across 4,000-byte records. At 8 MiB/s, this requires 2,730 live KeyStore/Keychain validations per second. On physical Android devices, hardware KeyStore IPC (binder transaction to `keystore2` / Secure Element / TEE) caps out at roughly 100–200 queries per second. This hardware boundary caps standard-record physical throughput to ~300–600 KB/s regardless of link bandwidth. Profile 3 v3 (262,016-byte chunks / 262,144-byte records) halves profile-3 record and validation frequency compared with capability 2; Android still performs two live validations per sent record and one per received record.
2. **Ingress serialization:** Serializing socket reads with inline frame delivery forces the socket to sit unread during CBOR decoding, native identity verification, and application storage hops, collapsing TCP receive windows. Bounded ordered ingress queues (`LanIngressQueue` / `LanQueueBudget`) decouple transport socket reads from downstream consumption while preserving sequential delivery order.
3. **Presentation thread saturation:** Incoming chunk CBOR decoding on presentation threads starves UI frame rendering pipelines, causing frame drops and input lag. Multi-kilobyte chunk decode must run off-main (e.g. `Dispatchers.Default`), restricting main-thread dispatch strictly to throttled state snapshots.
4. **Storage Access Framework (SAF) binder latency:** Writing small chunks through Android's `DocumentFile` tree provider introduces synchronous IPC and file descriptor sync overhead per chunk. Throughput requires sequential streaming into exclusive staging files without per-chunk provider traversal, followed by verified atomic publication or link fallback.

## 3. Per-record cost model

### Android, sending one 262,016-byte profile-3 chunk

| Stage | Payload-sized allocations | Payload copies | Anchor |
| :--- | ---: | ---: | :--- |
| Source read into one per-file buffer | 0 | 0 | `TransferController.kt:500` |
| Chunk CBOR node from the reused buffer | 1 | 1 | `TransferWire.kt:146`, `SessionCbor.kt:33` |
| Envelope CBOR encode | 1 | 0 | `SessionCbor.kt:71` |
| AES-GCM seal | 2 | 2 | `SecureSession.kt:118` |
| TCP framing into transport scratch | 0 | 1 | `LanFraming.kt:85`, `AndroidLanTransport.kt:18` |
| Socket write | 0 | 0 | `AndroidLanTransport.kt:65` |

### Android, receiving one 262,016-byte profile-3 chunk

| Stage | Payload-sized allocations | Payload copies | Anchor |
| :--- | ---: | ---: | :--- |
| Frame assembly | 1 | 1 | `LanFraming.kt:53` |
| AES-GCM open | 1 | 0 | `SecureSession.kt:140` |
| Envelope CBOR decode | 1 | 1 | `SessionCbor.kt:237` |
| Storage write and SHA-256 | 0 | 0 | `TransferController.kt` receive path |

### macOS

LAN senders negotiating more than 4,096 chunk bytes begin each file/resume with one chunk of at most 4,096 bytes and wait for advancing, correlated acknowledgement. Confirmation within 100 ms enables the full negotiated chunk size and window (up to eight 262,016-byte chunks, 2,096,128 file bytes). Slower initial confirmation, or a later gap above one second between advancing ACKs, constrains subsequent sends to 4,096-byte chunks and at most two unacknowledged chunks, always within peer limits. Window changes apply between source reads; already submitted bytes drain before more data fits a reduced budget. After at least five seconds since its last probe, a constrained sender can requalify with one new small chunk only after all submitted bytes are acknowledged. Partial probe confirmation cannot open the large window or reset probe timing. Every new file/resume starts with a fresh probe. ACK timing includes source, network, receiver storage and scheduling costs, not just network RTT. The existing 20-ms receiver ACK timer supplies feedback below the size-based cadence. BLE and standard-sized negotiation retain their existing limits. Smaller records trade throughput for a bounded bulk backlog on delayed paths; native validation still runs for each record.

Session-control classification validates full CBOR structure and canonical map order while omitting byte-string value materialization; the feature decoder still owns the payload copy. This removes one payload-sized allocation/copy per incoming transfer record on each platform without suppressing malformed-CBOR checks.

Transfer payload decoding runs off the main actor in one awaited worker per ordered ingress delivery. Immutable bytes and the negotiated chunk bound cross that boundary; cancellation, transfer epoch and channel generation are checked before applying results. This removes chunk CBOR work from presentation without adding a buffering stage or changing record validation. Debug media timing records input/submission/result/presentation events on Android and receipt/native-result/result-submission events on Mac using local monotonic clocks and existing subscription/command identifiers. TCP submission denotes local acceptance, not a remote acknowledgement. Opt-in record timing separates native validation, transport submission and application delivery using process-local object identifiers, payload sizes and local durations; it never logs keys or payloads. Android enables record timing when `AniCeMediaTiming` is DEBUG at process startup; Mac uses `ANICE_MEDIA_TIMING=1`. Command traces include the selected transport.

`SessionRecordCodec.seal` builds one reserved record buffer instead of chaining `+` concatenations, and `LanFraming.encode` builds one reserved frame buffer for the same reason. The seal path still pays CryptoKit's own ciphertext and tag allocations, and `open` copies the header, ciphertext and tag out of the record before handing them to `AES.GCM.SealedBox`. Encoding uses `Data` append growth rather than a measured two-pass write.

Record validation, seal/open and submission events include the secure-channel object identifier, local generation, negotiated profile and directional sequence. Monotonic start/end timestamps correlate overlapping send/receive stages within one process; peer clocks are not synchronized. Seal/open timing includes failed calls. Sequence metadata is diagnostic only and never changes nonce ownership. Timing remains opt-in and does not format log messages when disabled.

Opt-in LAN timing also emits `ingress_backpressure` for the awaited bounded-queue push and `ingress_delivery` for the consumer's complete session receive call, including authenticated validation and application delivery. Backpressure measures producer suspension and handoff overhead, not an envelope's residence time in the queue. Delivery durations include failed calls. These events use the existing timing switch, process-local transport identifier and envelope size; they contain no payloads. Compare the full consumer duration with session `validation` and application `delivery` durations on the same local timeline; their nested durations must not be added together.

LAN `socket_read` timing measures each native read; on Mac it includes the callback's transport-actor scheduling delay, separately reported as `socket_callback_wait`. Android separates `socket_writer_wait`, IO `socket_write_dispatch` and blocking `socket_write`; local write completion does not establish peer delivery. Mac incomplete-frame failures include pending-read age, last nonempty callback age and byte count even when opt-in timing is disabled. These distinguish socket wait from callback scheduling and feature delivery without logging endpoints or payloads.

Android receive storage shares one `Dispatchers.IO.limitedParallelism(1)` dispatcher across storage instances. Controller-owned provider setup, receiver cleanup and checkpoint writes use that same dispatcher; each storage instance retains its mutex. All storage methods use the injected dispatcher, including restore, prefix hashing, synchronization and publication. This limits simultaneous blocking provider work; it does not provide a dedicated thread or a FIFO feature-ingress consumer. Source preparation and CPU-bound CBOR decoding retain their existing executors.

Opt-in receive-storage timing emits `storage_create`, `storage_restore`, `storage_write`, `storage_flush`, `storage_fileIdentity`, `storage_prefixDigest`, `storage_finish` and `storage_discard` on both platforms. Android additionally emits matching `storage_wait_*` events from call entry through dispatcher and mutex acquisition. Work durations include failures; Android wait durations exclude the operation itself. Mac work timing starts after entering the storage actor and excludes actor-queue wait. Storage events identify the storage owner; profile/sequence fields are unspecified because storage does not own encrypted records. These durations nest inside authenticated application delivery and must not be added to that total. Disabled timing formats no storage event strings.

On macOS, normal TCP EOF closes the bounded frame hand-off to new input and defers the transport-end callback until its single consumer finishes accepted delivery. A ten-second absolute drain deadline retires the transport with `ETIMEDOUT` if delivery stalls. Explicit close and transport, authentication or delivery failures retire immediately; no later delivery callback starts after retirement. Frame bounds, nonce ordering and write deadlines are unchanged.

### Non-payload cost per record

Independent of payload size, each record also pays: one nonce construction, one `Cipher.init`, two `updateAAD` calls, one big-endian header write and read, one budget reserve/release under a lock, and one coroutine dispatch onto `Dispatchers.IO`. On macOS it pays one actor hop and one `Data` concatenation for the AAD. On the LAN receive path on both platforms each record additionally pays one bounded-queue hand-off between the read loop and the delivery consumer; that hand-off is what lets the socket stay read while an earlier record is still being decoded, validated and written.

Android GATT fragmentation caps native values at 512 bytes even at MTU 517; logical message limits and fragment headers are unchanged. Android session control selection, issuance and completion share the receive/maintenance mutex; application DATA submission releases that mutex to preserve full-duplex record processing. Transfer send calls remain cancellable through admission and native validation before nonce reservation. After reservation, SecureSession owns completion: Android runs sealing, submission and post-write validation in `NonCancellable` under the send mutex; Mac runs submission and post-write validation in one owned task after sealing. Producer cancellation is reported after that work finishes; transport or native-validation failure retires the session, and the record is never replayed. Transfer cleanup cancels stream, ACK and upgrade producers; epoch checks fence their later callbacks. BLE submission completion waits on native callbacks rather than 20-ms polling. BLE transfer credit is capped at four chunks, reserving ingress headroom for controls. Recovery checkpoints run on storage workers only when logical progress changes, at most once per five seconds plus forced pauses, file boundaries and publication intent; unchanged progress and idle connections perform no checkpoint writes. File publication waits for its intent checkpoint. Progress rate uses 21 observations at 250-ms spacing (about five seconds) to cover bursty confirmations without retaining a lifetime average. Transfer diagnostics log transport, negotiated chunk size and window once per file start; retirement logs record the failure type. Per-record timing is opt-in; normal transfer diagnostics do not log every chunk. Transfer progress no longer submits Android notification updates; only the required service notice and one silent background offer notice remain. These operations do not remove native identity/trust validation or change wire bytes.

Session DATA admission retains at most eight waiting callers before sealing. Payloads remain owned by their feature callers. Requests up to 4,000 bytes take priority over larger DATA, with FIFO ordering within each class and one bulk turn after four small-record turns when both classes are waiting. BLE-sized chunks participate in the same FIFO class as other small requests. Cancellation removes an unadmitted waiter without retiring a healthy channel; retirement rejects all waiting admissions. A cancelled operation that already closed its native session still follows normal owner retirement. Session controls still flush before admitted application DATA. Native validation, nonce reservation, transport queue bounds, transfer credit and TCP ordering remain unchanged. The `admission` timing event measures entry through permit acquisition; it does not imply remote receipt.

Authenticated transfer chunks enter one feature-owned FIFO before shared application delivery returns. The pending-byte bound is `min(advertisedReceiveChunkBytes × window + 65,536, 2,097,152)`; the record bound is `min(window × 8, 64)`. Both include the active consumer until storage handling completes. Header classification allocates no payload-sized buffer; full CBOR and transfer validation remains in the worker. Android decoding uses Default while all receiver storage shares the injected single-parallelism IO dispatcher; Mac decoding uses a detached task and storage remains actor-owned. Queued chunks emit no progress, ACK or successful application activity. Full capacity suspends ingress. Resume drains earlier writes; epoch invalidation discards pending work and fences active completion. Normal EOF and authenticated close allow at most ten seconds to drain accepted work. Opt-in `transfer_ingress_admission` and `transfer_ingress_delivery` events separate local queue admission from decode/storage execution; neither event proves peer receipt. Already-submitted TCP bytes remain ordered and cannot be overtaken.

## 4. Native validation

Native identity, key presence and protection, durable journal integrity, and pinned trust checks are re-evaluated for every authenticated operation. The exact contract is stated in the [LAN transfer profile](../protocol/lan/TRANSFER_PROFILE.md): Android validates before sealing and after awaited transport submission, with generation and deadline checks bracketing synchronous encryption; receive authentication is synchronous and is followed by native validation before counter advancement or application delivery.

| Path | Validations per record | Where |
| :--- | ---: | :--- |
| Android `send` | 2 | `SecureSession.kt:314`, `SecureSession.kt:343` |
| Android `receive` | 1 | `SecureSession.kt:374` |
| macOS `send` | 2 | `SecureSession.swift:205`, `SecureSession.swift:231` |
| macOS `receive` | 1 | `SecureSession.swift:255` |

The intermediate validation that previously sat between the capacity await and nonce reservation was removed on both platforms. It was redundant: the reservation transition and the post-submission check already fence generation and deadline, `checkTime` still rejects a closed, expired or retired session before encryption, and no sealing, submission or delivery can occur without a preceding and following validation. On Android the receive-path validation moved behind synchronous tag verification, so an unauthenticated record can no longer trigger KeyStore work; the profile contract already specified that ordering.

Caching this validation is prohibited. See rule 2 in section 6.

## 5. Hot-path inventory

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
| `apps/macos/aniCe/Infrastructure/Session/SessionCbor.swift` | `decodeSequence` | Bounded decode without re-basing copies |
| `apps/macos/aniCe/Infrastructure/LAN/LanFraming.swift` | `encode`, `feed` | Frame construction and assembly |

## 6. Optimization rules for this repository

1. **Reduce work per record, then per byte.** Allocation counts and copy counts per record dominate CPU and GC far more than constant factors inside a stage. Count them before optimizing.
2. **Never trade security validation for throughput.** Identity, protection, journal and trust validation stays live on every authenticated operation.
3. **Keep wire bytes identical.** Optimizations must not change a nonce, an AAD byte, a header layout, a CBOR ordering, or a bound. Independent vectors under `protocol/test-vectors/` are the guardrail.
4. **Reuse scratch only under the owner's serializer.** A shared buffer is safe exactly when every use of it holds the lock that serializes that direction. An assembled envelope leaves its owner's scope when it is handed to the ingress queue, so it is never reused: the framing cannot know when the consumer has finished with it. Both `LanFraming.feed` implementations therefore return an owned value the framer no longer references, and a queue entry must never be routed back to the framer.
5. **Preserve bounds and failure ordering.** Every bound check must still fail with the same typed reason, and a removal that changes which error wins between two failures is a behavior change, not an optimization.
6. **Measure at the tier you claim.** Host JVM unit tests prove wire bytes and arithmetic. They never prove radio throughput, socket behaviour, or KeyStore latency.

## 7. Changes made, and changes measured as negligible or rejected as unsafe

- **Per-record write watchdog.** `AndroidLanTransport.submit` launches one coroutine and one 10-second timer per record (`AndroidLanTransport.kt:55`). Moving the watchdog to transport lifetime would save roughly 1–2 µs per record against a 15.6 ms budget, and would change the deadline from per-record to earliest-in-flight. Rejected.
- **Credit-wait fast path.** The `CompletableDeferred` handling in the transfer send loop samples the revision, appends the waiter, then re-checks credit. That ordering is what prevents a missed wakeup. A fast path would save one deferred allocation per stall, which is not on the byte path at all. Rejected.
- **Output-offset `Cipher.doFinal`.** Writing ciphertext and tag directly into the record buffer would remove one 262,016-byte allocation and one copy per record on Android. It requires the output-offset overload, for which this repository has no precedent, and the host JVM unit suite cannot exercise Android's provider path. Deferred; see section 8.
- **Pooling the receive assembly buffer.** Rejected, not deferred. `LanFraming.feed` allocates one `ByteArray(size)` per assembled envelope (`LanFraming.kt:53`) and the ingress consumer runs concurrently with the read loop, so the framing cannot know when that array is free. Reuse would need a per-record return round-trip and would put a use-after-hand-off hazard on the record path for a single 262,016-byte allocation. The ownership contract is stated at `LanFraming.kt:35`.
- **Frame-bounded reads.** Android retains a `profile.maximumEnvelope + 5` scratch buffer. Both transports limit each native read to the remaining five-byte header or current frame body. A complete frame is handed to the bounded ingress queue before reading the next header, so local queue suspension cannot age a later frame already coalesced into the same read buffer. This requires separate header/body reads, with additional reads for fragmented delivery; allocation bounds and ordered delivery are unchanged. Secured encrypted-record frames use the bounded progress deadline defined in the LAN contract.
- **Ingress serialized with delivery.** The read loop delivered every frame inline before issuing the next read, so the socket sat unread for the whole decode, native validation and delivery hop of each record. TCP backpressure then amplified every stall, which is why the same build swung by an order of magnitude between links. Both platforms now hand envelopes to a bounded single-consumer queue and return to reading immediately. Ordering is unchanged because one consumer drains sequentially, and the bound restates the existing admission limit rather than adding one. A full queue suspends the producer rather than dropping: every `AsyncStream` buffering policy discards an element instead, which would fail a valid transfer on a fast link. Normal EOF closes the hand-off without emptying it, so accepted envelopes finish delivery before the end is reported, subject to the bounded drain deadline: the peer's FIN commonly follows its last record, and a close that discarded the queue would drop the record carrying its CLOSE, which inline delivery always delivered.
- **Direct main-thread chunk delivery.** The 262,016-byte `TransferMessage.decode` for a profile-3 chunk runs on `Dispatchers.Default`; the transfer FIFO consumer resumes on its UI owner and awaits storage on the injected single-parallelism IO dispatcher. Transfer state mutation remains on the main dispatcher, with progress publication rate-limited to the existing 100 ms interval. Feature DATA delivery itself still enters through `Dispatchers.Main.immediate`: every feature handler publishes Compose state, so moving the whole dispatch off main would require per-feature marshalling and is not done.
- **Session lock or gate held across application delivery.** Android held `operation` and macOS held `processing` while awaiting the application handler, so a slow handler delayed control flush, deadline maintenance and the next record's authentication. Both release before delivery; ordering survives because every caller awaits one `receive` before starting the next and both transports deliver through a single sequential consumer.

## 8. Open candidates

1. **Feature DATA dispatch.** Feature delivery still enters through `Dispatchers.Main.immediate`, where every feature handler publishes Compose state. Moving the whole dispatch off main needs per-feature marshalling; transfer chunks now leave shared dispatch after bounded admission, so their decode and storage awaits no longer hold up later handlers. Other handlers still await their own work.
2. **Larger authenticated records.** Capability 3 now fills the existing profile-3 DATA budget with up to 262,016-byte chunks. It reduces per-byte encryption and native trust-validation work; physical acceptance still requires measurement on target hardware.
3. **Android encrypt-side allocation.** `RecordCipher.seal` allocates the ciphertext, then a record buffer and copies into it. Removing the intermediate allocation is the largest single remaining win on the send path.
4. **macOS `SessionRecordCodec.open` copies.** The header, ciphertext and tag are each copied before `AES.GCM.SealedBox` is constructed. Slicing the record instead would remove three copies per record but extends the lifetime of the full record buffer.
5. **macOS CBOR encoding growth.** `encodeValues` appends into a growing `Data`; Android measures and writes once. The macOS encoder is not yet symmetric.
6. **Android CBOR decode of transfer payloads.** `Cbor.Bytes` slicing copies once, and the `Cbor.bytes()` extension copies again at each call site that uses it.

## 9. Measurement procedure

| Tier | Command | Proves |
| :--- | :--- | :--- |
| Android unit | `./gradlew :app:testDebugUnitTest --offline` from `apps/android/` | Wire bytes, bounds, typed failures, allocation ownership |
| macOS hosted | `xcodebuild test` for `aniCeTests` | Same contracts on the CryptoKit and Security paths |
| Interchange | `scripts/test_identity_interchange.py`, `scripts/test_lan_interchange.py`, `scripts/test_session_interchange.py`, `scripts/test_structure.py` | Cross-platform byte agreement |
| Structure | `scripts/check-structure.py` | Dependency direction, documentation links, Xcode membership |
| Physical | `scripts/verify-lan-interchange.py --benchmark-mib 16\|100\|1024 --window 32\|64` | Socket and radio throughput, process CPU, RSS, allocation counters |

Physical runs are the only tier that may be cited for the 8 MiB/s gate. Debug instrumentation is the only configuration measured so far. Release, battery, minimum-OS, Intel-runtime, and responsiveness acceptance remain separate requirements.

## Active Now Playing observation

Enabling optional Mac Home/companion Now Playing display correlates with approximately 15–20% app CPU during playback and peaks around 35% with concurrent Phone→Mac transfer. These are interactive Debug runtime observations, not a controlled Release profile or battery measurement. Connected-idle results do not describe this workload. A visible/hidden playback comparison and CPU call-tree capture are needed before attributing the cost to rendering, artwork decoding, metadata delivery or record processing. 



## Android capacity notification reentrancy

Physical startup sampling on the SM-A346E shows the main thread at 99–103% of one core while the rendering and IO workers are mostly idle. Two debugger snapshots identify `TransferController.clearCapacityWaiters` synchronously resuming `sendWithBackpressure`, which requeues a waiter after `SessionBackpressure`. Polling and completing in the same loop consumes those newly queued waiters indefinitely, starving UI and connection progress during capability exchange even without a user transfer.

Capacity notification now drains existing waiters into a bounded-by-current-waiters snapshot before completing any continuation. Requeued waiters wait for a subsequent real notification; no retry polling or timer is introduced. Wire bytes, security validation and admission bounds are unchanged. The adversarial synchronous-resumption regression fails against the old loop (eight capped attempts for one event) and requires exactly one additional send attempt per capacity event.

A full data-preserving Debug APK update removes the observed spin on the same phone: the main thread reports 0.0% CPU in three short idle samples, and `dumpsys gfxinfo` returns rather than timing out. A warm activity launch completes in 649 ms. Identity and trust journal SHA-256 hashes remain unchanged across installation. Initial Debug rendering still records slow frames (9/27 janky frames in the startup sample); this verifies removal of the indefinite main-thread spin, not full cold-start or sustained-frame acceptance. Android JVM tests (227), offline lint and Debug build pass.
