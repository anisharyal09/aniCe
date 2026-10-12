# Local File Transfer Protocol v1

[transfer.cddl](transfer.cddl) defines the authoritative message structure. Messages are deterministic RFC 8949 CBOR arrays transported inside authenticated DATA records bounded to 4,000 plaintext bytes. Existing session authentication, readiness, connection checks, EDHOC, exporter labels, AES-256-GCM framing and nonce ownership remain unchanged.

## Envelopes and Messages

Every transfer message uses the four-element envelope `["aniCe transfer", 1, kind, fields]`. Text fields are UTF-8; NUL and control characters are strictly forbidden. UUIDs require canonical 36-character hyphenated syntax. Binary chunks use raw CBOR byte strings (`bstr`). No CBOR null, floating-point, indefinite-length or non-minimal encodings are permitted.

| Kind | Name | Direction | Fields | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| 1 | `capability` | Bidirectional | `[version, maxChunkBytes, maxWindow]` | Advertises transfer capability and limits once after session is secured |
| 2 | `offer` | Sender → Receiver | `[batchId, sliceIndex, totalSlices, totalFiles, totalBytes, files]` | Proposes a batch of files; slices partition inventories of up to 128 files |
| 3 | `accept` | Receiver → Sender | `[batchId, acceptedFiles]` | Receiver explicitly accepts the batch; empty list indicates all offered files accepted |
| 4 | `reject` | Receiver → Sender | `[batchId, reason]` | Receiver rejects the batch with typed rationale |
| 5 | `chunk` | Sender → Receiver | `[batchId, fileId, offset, data]` | Carries up to 3,072 bytes of sequential file content |
| 6 | `ack` | Receiver → Sender | `[batchId, fileId, written]` | Cumulative acknowledgement of durably written bytes |
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

## Coordinated LAN Renewal

For multi-gigabyte transfers that approach directional record limits ($2^{20} - 4,096$ records) or session age limits (54 minutes), peers coordinate a transparent TCP connection rotation:

```
ACTIVE → QUIESCING → CHECKPOINTED → RETIRED → NEW_TCP_AUTHENTICATING → READY → ACTIVE
```

1. **Trigger**: Initiated when record counter reaches $2^{20} - 4,096$ or elapsed session duration reaches 54 minutes.
2. **Quiescing**: Transfer engine pauses new chunk emissions, drains in-flight TCP data, and flushes durable file offsets to disk.
3. **Endpoint Validation**: The successor listener port and address are validated against the established peer identity.
4. **Fresh Handshake**: A fresh TCP connection and fresh EDHOC handshake are completed while preserving open file descriptors and streaming hash contexts.
5. **Session Transition**: The previous session keys are retired immediately upon successful authentication of the successor, and chunk transmission resumes without re-transferring acknowledged bytes.
