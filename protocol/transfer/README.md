# Local File Transfer Protocol v1

The [LAN transfer profile](../lan/TRANSFER_PROFILE.md) defines production LAN revision 2, record profile 3 and transfer capability 2. Standard profile 1/BLE limits and fixture bytes remain unchanged.


[transfer.cddl](transfer.cddl) defines the authoritative message structure. Messages are deterministic RFC 8949 CBOR arrays transported inside authenticated DATA records bounded to 4,000 plaintext bytes. Existing session authentication, readiness, connection checks, EDHOC, exporter labels, AES-256-GCM framing and nonce ownership remain unchanged.

## Transport selection

Both native apps advertise capability v1 on each secured LAN/BLE channel to the same pinned device ID and fingerprint. Capability and chunk/window limits are channel-generation scoped. A secured LAN channel has priority over BLE regardless of arrival order; an incompatible LAN peer does not authorize silent BLE routing while LAN remains secured. Only decoded transfer envelopes participate in this selection; unrelated feature DATA remains available to other handlers.

Idle routing chooses LAN, otherwise BLE. An offer assembly and its subsequent batch, including preparation and approval, remain bound to one channel generation. LAN arrival during a BLE batch changes the next batch's route after cleanup. Retiring a standby channel cannot terminate the active batch; stale retirement/capability events cannot replace a live generation. Retiring the active channel invalidates preparation, continuations, offer assembly and partial storage before selecting the remaining secured channel. Messages from the retired generation are discarded. Scheduled ACK/accept work captures its job epoch before suspension; late failures cannot mutate a successor job. Terminal rejects/cancels remain bound to the original live channel even after preference changes. Capability received during an incoming offer remains available after job cleanup.

Transport fallback changes availability for a new batch. It does not replay sealed records or continue a partially transferred file across independent session keys. Interrupted files require a new offer and explicit recipient approval; kinds 10/11 remain unavailable for resumption. No CDDL, capability-version, cryptographic or fixture-byte change is required.

## Envelopes and Messages

Every transfer message uses the four-element envelope `["aniCe transfer", 1, kind, fields]`. Text fields are UTF-8; NUL and control characters are strictly forbidden. UUIDs require canonical 36-character hyphenated syntax. Binary chunks use raw CBOR byte strings (`bstr`). No CBOR null, floating-point, indefinite-length or non-minimal encodings are permitted.

| Kind | Name | Direction | Fields | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| 1 | `capability` | Bidirectional | `[version, maxChunkBytes, maxWindow]` | Advertises transfer capability and limits once after session is secured |
| 2 | `offer` | Sender → Receiver | `[batchId, sliceIndex, totalSlices, totalFiles, totalBytes, files]` | Proposes a batch of files; slices partition inventories of up to 128 files |
| 3 | `accept` | Receiver → Sender | `[batchId, acceptedFiles]` | Receiver explicitly accepts the batch; empty list indicates all offered files accepted |
| 4 | `reject` | Receiver → Sender | `[batchId, reason]` | Receiver rejects the batch with typed rationale |
| 5 | `chunk` | Sender → Receiver | `[batchId, fileId, offset, data]` | Carries up to 3,072 bytes of sequential file content |
| 6 | `ack` | Receiver → Sender | `[batchId, fileId, written]` | Cumulative acknowledgement of written bytes for flow control |
| 7 | `file-result` | Bidirectional | `[batchId, fileId, result, hash]` | Final confirmation of file completion or error with verified SHA-256 digest |
| 8 | `batch-result`| Bidirectional | `[batchId, result]` | Signals termination of the entire batch |
| 9 | `cancel` | Bidirectional | `[batchId, fileId, reason]` | Aborts an individual file or entire batch |
| 10 | `resume` | Bidirectional | `[batchId, fileId, offset, prefixHash]` | Proposes resumption from a verified durable prefix |
| 11 | `status` | Bidirectional | `[batchId, fileId, bytesTransferred, state]` | Reports or queries transfer checkpoint status |

### Offer and File Inventory

- `totalFiles`: 1 to 128 files across a batch.
- Slices: Each offer slice contains 1 to 8 files, ensuring the message fits comfortably within the 4,000-byte DATA limit. `sliceIndex` ranges `0..totalSlices-1` (max 16 slices).
- Each file entry is `[fileUUID, name, size, sha256]`:
  - `name`: 1 to 255 UTF-8 bytes. Forward slashes `/`, backslashes `\`, NUL `\0`, directory traversal components (`.` or `..`), and leading/trailing whitespace are prohibited.
  - `size`: 0 to $2^{63}-1$ bytes.
  - `sha256`: exactly 32 raw bytes of SHA-256 digest over the entire file content.
- `totalBytes`: sum of all file sizes in the batch.

### Rejection and Result Codes

**Reject reasons (Kind 4):**
- `0`: User declined
- `1`: Unsupported destination
- `2`: Insufficient storage
- `3`: Busy (another transfer active)
- `4`: Invalid offer or malformed parameters

**File results (Kind 7):**
- `0`: Success (length and SHA-256 verified)
- `1`: Hash mismatch
- `2`: I/O error / write failure
- `3`: Cancelled

**Batch results (Kind 8):**
- `0`: Success (all accepted files transferred and verified)
- `1`: Partial failure (one or more files failed or skipped)
- `2`: Cancelled
- `3`: Terminal error

**Cancel reasons (Kind 9):**
- `0`: User cancelled
- `1`: Connection lost
- `2`: Storage error / disk full
- `3`: Transfer timeout
- `4`: Policy violation

## Flow Control and Credit

- **Cumulative Window**: At most 64 unacknowledged chunks may be in flight simultaneously ($64 \times 3,072 = 196,608$ bytes).
- **Acknowledgement Cadence**: The receiver emits an `ack` record every 8 chunks received ($24,576$ bytes), after a 20-ms timer expires with unacknowledged bytes pending, and immediately upon receiving the final chunk of a file.
- **Credit Enforcement**: The sender tracks `inFlight = sentBytes - acknowledgedBytes`. When `inFlight >= maxWindow * maxChunkBytes`, the sender pauses and buffers at most one unsent chunk, resuming immediately upon receiving an `ack`.
- **Integrity Calculation**: Receivers compute SHA-256 incrementally as chunks arrive. Final verification requires exact length match and hash equality before renaming to the final destination.

## Application-state validation

Each assembled offer must contain exactly its declared file count and byte sum, with unique file IDs across slices and consistent slice metadata. Receivers bound assembly to one batch and a fixed ten-second deadline. Unsupported or inconsistent assemblies cannot reach approval.

Chunks must target the current batch/file, match the next written offset and fit within its remaining length. ACKs must target the current sending file, advance monotonically and never exceed admitted bytes. Successful file results require the current batch/file, complete admitted length and expected SHA-256. A batch result cannot substitute for verified per-file results. Channel retirement invalidates pending work.

## Recovery and renewal status

Kinds 10 and 11 reserve resume/status vocabulary. Current apps do not implement resume journals or checkpoint recovery; a resume request receives status 4 (unavailable). Capability v1 advertises basic chunk/window support and does not prove recovery or coordinated LAN renewal.

Transparent renewal requires a separately negotiated Connections/Session extension with endpoint exchange, quiescing, durable checkpoints, old keys/socket retirement and a fresh TCP/EDHOC exchange before restarting work. No overlapping old/successor sessions or in-band rekey is permitted. That extension is not implemented. Multi-gigabyte renewal and crash-after-rename reconciliation remain development gates.
