# Local File Transfer

## Using file transfer

### Sending files

Android and Mac can initiate file transfers from Features → Local file transfer or from the Home live-activity card when a trusted peer is secured over the local network.

- **Batch bounds:** Batches contain 1 to 128 files. Senders precompute SHA-256 digests and file sizes before sending offer slices.
- **Filename sanitization:** Filenames must be 1 to 255 UTF-8 bytes. Forward slashes `/`, backslashes `\`, NUL `\0`, directory traversal (`.` and `..`), and leading or trailing whitespace are rejected at the protocol boundary.
- **On-demand connection:** If LAN is not currently secured when tapping **Send files…**, the app initiates an on-demand local-network connection to the preferred trusted peer, queuing file selection until secured.

### Incoming offers and recipient approval

- **Offer partitioning:** Batch inventories are partitioned into slices of up to 8 files, ensuring each offer record remains well within the 4,000-byte authenticated DATA limit.
- **Approval:** The recipient reviews the batch summary (file count, total size, file names) and can accept or decline. Senders show a waiting status with local cancellation.
- **Destination folder:** Mac saves incoming files to the user's `Downloads` directory by default, with an explicit **Choose…** directory picker. Android saves to standard external `Download` storage.

### Streaming and flow control

- **Credit flow control:** Senders stream file content in sequential 3,072-byte chunks with at most 64 unacknowledged chunks in flight simultaneously ($64 \times 3,072 = 196,608$ bytes). When in-flight bytes reach the window limit, the sender pauses until the recipient acknowledges written bytes.
- **Acknowledgement cadence:** Recipients emit cumulative `ack` records every 8 chunks received ($24,576$ bytes), upon expiry of a 20-ms timer with unacknowledged bytes pending, and immediately upon receiving the final chunk of a file.
- **Throughput metrics:** Progress percentage, transferred byte counts, and transfer rates are calculated continuously and published to the UI at 100-ms intervals.

### Staging, verification and atomic commit

- **Staging:** Incoming chunks are written sequentially to a temporary `<filename>.anice-part` staging file while calculating the running SHA-256 digest.
- **Verification:** When the file offset matches the advertised size, the recipient flushes and closes the file descriptor, verifies that the digest matches the sender's SHA-256 hash, and atomically renames `.anice-part` to the destination filename.
- **Collision handling:** If a file with the target name already exists in the destination folder, the recipient appends a numeric suffix: `<base> (1).<ext>`.
- **System indexing:** Android immediately triggers `MediaScannerConnection.scanFile` upon atomic rename so transferred media appears in the system gallery without a reboot.
- **Integrity failure:** If the digest does not match, the recipient immediately deletes the `.anice-part` file and signals failure to the sender.

### System lifecycle, notifications and power assertions

- **Background retention:** Android `LanSessionController` preserves local-network connections across background transitions while transfers are active or initiating, preventing document-picker suspension from dropping the session.
- **Notification shade:** Android presents ongoing transfer progress, percentage, file index, and transfer rate in the system notification shade via `TransferNotification`. A notification **Cancel** action broadcasts through `TransferActionReceiver` to abort the transfer cleanly. Notification Binder IPC calls are rate-limited to 250-ms intervals during streaming.
- **Sleep assertions:** macOS acquires an `IOPMAssertionCreateWithName` power assertion (`kIOPMAssertionTypePreventUserIdleSystemSleep`) when a transfer begins, preventing system idle sleep until the transfer completes, fails, or cancels.

---

## Implementation

### Source organization

- **Android:**
  - `apps/android/app/src/main/java/io/github/anisharyal09/anice/features/transfer/`:
    - `TransferController.kt`: State machine, flow control, offer dispatch, chunk streaming, staging and verification.
    - `TransferView.kt`: Jetpack Compose UI for offer review, folder selection, progress and cancellation.
    - `TransferWire.kt`: Normative CBOR serialization and deserialization for all 11 protocol message types.
    - `TransferNotification.kt`: System notification channel, progress bar and status updates.
    - `TransferActionReceiver.kt`: Broadcast receiver routing notification cancellation actions.
  - Tests: `apps/android/app/src/test/java/io/github/anisharyal09/anice/features/transfer/` (`TransferControllerTests.kt`, `TransferWireTests.kt`).
- **macOS:**
  - `apps/macos/aniCe/Features/Transfer/`:
    - `MacTransferModel.swift`: Main-actor transfer engine, flow-control queues, sleep assertions and staging.
    - `TransferView.swift`: SwiftUI presentation across Features and compact live-activity panels.
    - `TransferWire.swift`: Normative CBOR serialization and deserialization.
  - Tests: `apps/macos/aniCeTests/Transfer/` (`TransferModelTests.swift`, `TransferWireTests.swift`).
- **Protocol:**
  - CDDL Schema: `protocol/transfer/transfer.cddl`
  - Specification: `protocol/transfer/README.md`
  - Independent test vectors: `protocol/test-vectors/transfer/transfer-vectors.json` (52 cases: 19 valid, 33 invalid).

---

## Detailed contracts and decisions

- [Local File Transfer Protocol v1](../../protocol/transfer/README.md) and [CDDL Schema](../../protocol/transfer/transfer.cddl).
- [Independent Local Network Transport](../LAN_CONNECTIONS.md) and [LAN Contract](../../protocol/lan/README.md).
- [Presentation and Semantic Tokens](../design/DESIGN.md).

---

## Known limitations

- **Single active batch:** A peer rejects incoming offers with reason code `3` (Busy) if another transfer is currently active.
- **LAN-only transport:** Local file transfer requires an authenticated local-network (LAN) channel. High-bandwidth file streaming is not supported over Bluetooth Low Energy.
- **Multi-gigabyte renewal:** Transparent TCP session rotation before the 54-minute / $2^{20} - 4{,}096$ record threshold is specified in protocol v1; multi-gigabyte continuous endurance benchmarks remain a physical release gate.
