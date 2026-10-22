# Local File Transfer Protocol v1

The [LAN transfer profile](../lan/TRANSFER_PROFILE.md) defines production LAN revision 2 and record profile 3. Transfer capability 2 retains 128-KiB chunks for compatibility; capability 3 enables chunks up to 262,016 bytes within the same authenticated record budget. Standard profile 1/BLE limits remain unchanged.


[transfer.cddl](transfer.cddl) defines the authoritative message structure. Messages are deterministic RFC 8949 CBOR arrays transported inside authenticated DATA records bounded to 4,000 plaintext bytes. Existing session authentication, readiness, connection checks, EDHOC, exporter labels, AES-256-GCM framing and nonce ownership remain unchanged.

## Transport selection

Both native apps advertise capability v1 on each secured LAN/BLE channel to the same pinned device ID and fingerprint. Capability and chunk/window limits are channel-generation scoped. A secured LAN channel has priority over BLE regardless of arrival order; an incompatible LAN peer does not authorize silent BLE routing while LAN remains secured. Only decoded transfer envelopes participate in this selection; unrelated feature DATA remains available to other handlers.

Idle routing chooses LAN, otherwise BLE. Offer assembly is channel-generation scoped. A completed manifest and its approval remain peer-credential scoped while channel replacement uses the recovery handshake; unfinished offer slices do not migrate. A LAN channel that becomes capable while a BLE batch is streaming triggers an in-place upgrade through the resume handshake below; otherwise LAN arrival changes the next batch's route after cleanup. Retiring a standby channel cannot terminate the active batch; stale retirement/capability events cannot replace a live generation. Retiring the active channel while a batch is streaming retains its verified prefix and pauses the batch instead of failing it; old-generation work is invalidated and messages from it are discarded. Unfinished incoming offer assembly remains channel scoped; source preparation settles independently of the initiating channel. Completed offers and approval are retained for recovery; admitted finalization settles local publication before reporting its outcome. Scheduled ACK/accept work captures its job epoch before suspension; late failures cannot mutate a successor job. Terminal rejects/cancels remain bound to the original live channel even after preference changes. Capability received during an incoming offer remains available after job cleanup.

Transport fallback changes availability for a new batch; resumption after a channel change uses kinds 10/11. A live LAN that becomes capable during a BLE stream runs the same handshake and upgrades the stream in place; there is no replay of sealed records across independent session keys and no overlapping streams after the switch. A paused batch is retained for 15 minutes: either side may initiate the handshake, and the receiving side hashes exactly the prefix it retains while the sender validates its source prefix. Updated peers restore private checkpoints after process death; older peers may report recovery unavailable. No CDDL, capability-version, cryptographic or fixture-byte change is required.

## Envelopes and Messages

Every transfer message uses the four-element envelope `["aniCe transfer", 1, kind, fields]`. Text fields are UTF-8; NUL and control characters are strictly forbidden. UUIDs require canonical 36-character hyphenated syntax. Binary chunks use raw CBOR byte strings (`bstr`). No CBOR null, floating-point, indefinite-length or non-minimal encodings are permitted.

| Kind | Name | Direction | Fields | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| 1 | `capability` | Bidirectional | `[version, maxChunkBytes, maxWindow]` | Advertises transfer capability and limits once after session is secured |
| 2 | `offer` | Sender → Receiver | `[batchId, sliceIndex, totalSlices, totalFiles, totalBytes, files]` | Proposes a batch of files; slices partition inventories of up to 128 files |
| 3 | `accept` | Receiver → Sender | `[batchId, acceptedFiles]` | Receiver explicitly accepts the batch; empty list indicates all offered files accepted |
| 4 | `reject` | Receiver → Sender | `[batchId, reason]` | Receiver rejects the batch with typed rationale |
| 5 | `chunk` | Sender → Receiver | `[batchId, fileId, offset, data]` | Carries up to 3,072 bytes on standard/BLE, 131,072 bytes with LAN capability 2, or 262,016 bytes with LAN capability 3 |
| 6 | `ack` | Receiver → Sender | `[batchId, fileId, written]` | Cumulative acknowledgement of written bytes for flow control |
| 7 | `file-result` | Bidirectional | `[batchId, fileId, result, hash]` | Final confirmation of file completion or error with verified SHA-256 digest |
| 8 | `batch-result`| Bidirectional | `[batchId, result]` | Signals termination of the entire batch |
| 9 | `cancel` | Bidirectional | `[batchId, fileId, reason]` | Aborts an individual file or entire batch |
| 10 | `resume` | Bidirectional | `[batchId, fileId, offset, prefixHash]` | Proposes resumption from a verified retained prefix |
| 11 | `status` | Bidirectional | `[batchId, fileId, bytesTransferred, state]` | Answers a resume request with the retained length and state |

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

- **Cumulative Window**: Standard/BLE allows up to 64 unacknowledged 3,072-byte chunks. LAN capabilities 2 and 3 allow up to 8 unacknowledged chunks (up to 1 MiB and 2 MiB respectively).
- **Acknowledgement Cadence**: The receiver emits an `ack` record every 8 chunks received ($24,576$ bytes), after a 20-ms timer expires with unacknowledged bytes pending, and immediately upon receiving the final chunk of a file.
- **Credit Enforcement**: The sender tracks `inFlight = sentBytes - acknowledgedBytes`. When `inFlight >= maxWindow * maxChunkBytes`, the sender pauses and buffers at most one unsent chunk, resuming immediately upon receiving an `ack`.
- **Integrity Calculation**: Receivers compute SHA-256 incrementally as chunks arrive. Final verification requires exact length match and hash equality before renaming to the final destination.

## Resume and status

Pausing retains the receiver's verified partial, the sender's acknowledged offset, the batch identity and both peers' progress. The retained state is checkpointed privately for up to 15 minutes after interruption. Explicit cancel or expiry cleans up only the job-owned partial; a temporary resume failure keeps the job pending. Either side can initiate a resume with kind 10: the sender proposes its acknowledged offset and source prefix, or the receiver proposes the prefix it already holds when the user explicitly continues over Bluetooth. The receiving side always validates and answers with kind 11.

| Status state | Meaning |
| :--- | :--- |
| 0 | Accepted; `bytesTransferred` is the receiver's retained length |
| 1 | Requested offset exceeds the retained length; `bytesTransferred` is the retained length |
| 2 | Prefix hash mismatch; the retained bytes were discarded and the file restarts at offset 0 |
| 3 | Busy, finalizing, or no resumable state for this file |
| 4 | Unavailable: unknown batch/file or no retained storage |

Sender flow:

1. Select a secured channel to the same authenticated peer and send kind 10 with the last acknowledged offset and a SHA-256 digest of exactly that many source bytes.
2. State 0 continues at `bytesTransferred`, which may exceed the proposed offset.
3. State 1 recomputes the digest at the reported length and retries once; a second state 1 fails the batch.
4. State 2 restarts the current file from zero after the receiver recreates its partial.
5. State 3/4 or a status timeout fails the batch with a readable reason.
6. A live LAN that becomes capable during a BLE stream runs the same handshake over LAN while BLE keeps streaming. On state 0/2 the sender fences the BLE stream and continues on LAN at the reported offset; state 1/3/4 keeps BLE, and a timeout pauses the batch so the normal preferred-channel policy resumes it.

Receiver flow accepts a resume for the retained batch while paused or, after an asymmetrical disconnect, while the receiver still considers the batch transferring. It rebinds to the channel that carried the resume, flushes the partial, checks the requested offset and then the prefix digest, and answers with kind 11. A resume at the full file length after the last chunk was acknowledged but its result was not seen replays the retained verified file result instead of failing.

Receiver-initiated flow applies when the user explicitly continues over Bluetooth. The receiver hashes exactly the bytes it still holds and sends kind 10 over BLE; LAN continuation is sender initiated. The sender accepts only for its current file and compares the digest with its source prefix. In-process requests cannot exceed the admitted sent length; a restored source may validate any prefix within the file manifest because its last admitted counter is not durable. An excessive offset returns 1, a digest mismatch returns 2, and a source read failure returns 4. On state 0 it fences its old stream and restarts from the validated offset. A BLE request is refused with state 3 while a freshly resumed LAN stream is still producing acknowledgements, so a returning LAN wins over a stale opt-in.

Local network pauses resume automatically when a new LAN channel to the same peer becomes capable, and a live LAN upgrades a BLE continuation the same way. After a LAN pause, continuing over BLE requires an explicit action by whichever device wants to continue; the receiving device sends the resume request and the sending device validates it. A BLE pause auto-resumes over BLE and upgrades automatically when LAN becomes capable. A paused batch keeps its transport ownership: Android retains the foreground transfer service, LAN eligibility and a bounded BLE recovery lease, and Mac retains its sleep assertion. Manual pause while a channel is healthy is not offered; pause is a consequence of transport loss.

## Application-state validation

Each assembled offer must contain exactly its declared file count and byte sum, with unique file IDs across slices and consistent slice metadata. Receivers bound assembly to one batch and a fixed ten-second deadline. Unsupported or inconsistent assemblies cannot reach approval.

Chunks must target the current batch/file, match the next written offset and fit within its remaining length. ACKs must target the current sending file, advance monotonically and never exceed admitted bytes. Successful file results require the current batch/file, complete admitted length and expected SHA-256. A batch result cannot substitute for verified per-file results. Channel retirement invalidates unfinished incoming assembly; completed offers and approved batches remain pending, and streaming batches retain their verified prefix.

## Recovery and renewal status

BLE implementations advertise a four-chunk window within the existing capability-1 range. The eight-message GATT ingress budget and 32-KiB logical bound remain unchanged.

Kinds 10 and 11 resume retained jobs after channel changes and app restarts. Private bounded journals retain prepared manifests, approval state, peer/local identity bindings, flushed prefix offsets, publication intent and verified receipts. Recovery reopens only job-owned partials and rebuilds their digest; submitted records, session keys and counters are never persisted. Unapproved offers are reoffered under the same batch ID and do not inherit approval. Reoffering an already-approved identical manifest permits a fresh resume handshake. Temporary resume timeouts or busy status retain the job until its original expiry. Capability v1 advertises basic chunk/window support and does not prove durable recovery or coordinated LAN renewal.

Transparent renewal requires a separately negotiated Connections/Session extension with endpoint exchange, quiescing, durable checkpoints, old keys/socket retirement and a fresh TCP/EDHOC exchange before restarting work. No overlapping old/successor sessions or in-band rekey is permitted. That extension is not implemented. Multi-gigabyte session renewal remains a development gate. Private publication recovery proves the original file identity, length and digest; ambiguous provider/copy outcomes require user review instead of publishing a duplicate.
