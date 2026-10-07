# aniCe Pairing Protocol (v1)

Provisional pairing and mutual trust establishment protocol for **aniCe**. This protocol establishes persistent device trust; it is not a reusable synchronization session.

- **Peripheral / Server:** macOS (owns pairing invitation and GATT service).
- **Central / Client:** Android (scans, connects, initiates authentication).
- **Bluetooth Bonding:** None. Devices authenticate at the application layer.

---

## 1. GATT Attribute Architecture

The Mac peripheral exposes a fixed three-characteristic GATT service from initial peripheral startup. The service layout remains stable across discovery and pairing windows (see [ADR 0004](../../docs/decisions/0004-stable-ble-attribute-layout.md)).

| Attribute | UUID | Type / Properties | Access Rules |
| :--- | :--- | :--- | :--- |
| **Primary Service** | `414E4953-4853-4149-4A49-4C4365090901` | Service | Publicly advertised |
| **Discovery** | `414E4953-4853-4149-4A49-4C4365090902` | Read | Available only during active discovery |
| **Pairing Write** | `414E4953-4853-4149-4A49-4C4365090903` | Write with response | Requires active invitation; writes rejected otherwise |
| **Pairing Indicate** | `414E4953-4853-4149-4A49-4C4365090904` | Indicate | Requires active invitation; indications sent only to active subscriber |

---

## 2. Wire Encoding & Framing

### Length-Prefixed Fields
Composite payloads use `fields(x1, x2, ...)` formatting:
Each element is preceded by its length as a 4-byte big-endian unsigned integer (`uint32`). Strings are raw UTF-8 without null terminators or Unicode normalization.

### Logical Messages
Each logical message consists of a 1-byte message type (`uint8`) followed by zero or more length-prefixed fields:
$$\text{Message} = \text{type} \,\|\, \text{fields}(\dots)$$
Maximum logical message size: **4,096 bytes**.

#### Outer Protocol Messages

| Type | Name | Direction | Fields | Description |
| :---: | :--- | :--- | :--- | :--- |
| `1` | `query` | Client $\to$ Server | *(none)* | Probe active invitation state |
| `2` | `invitation` | Server $\to$ Client | `method` (1B), `rendezvous` (16B), `serverNonce` (32B) | Broadcast active invitation parameters |
| `3` | `clientHello` | Client $\to$ Server | `method` (1B), `rendezvous` (16B), `clientNonce` (32B), `clientPayload` | Ephemeral public key (QR) or OPAQUE request (PIN) |
| `4` | `serverHello` | Server $\to$ Client | `serverNonce` (32B), `serverPayload`, `serverMac` | Ephemeral public key + MAC (QR) or OPAQUE response (PIN) |
| `5` | `clientFinish` | Client $\to$ Server | `clientPayload` | Client HMAC confirmation (QR) or OPAQUE finalization (PIN) |
| `6` | `serverFinish` | Server $\to$ Client | `confirmation` (32B) | Final channel confirmation MAC |
| `7` | `encrypted` | Bidirectional | `counter` (8B), `ciphertext` | Encrypted envelope containing an inner message |

#### Inner Encrypted Messages (Payload within Type 7)

| Type | Name | Fields | Description |
| :---: | :--- | :--- | :--- |
| `10` | `identity` | `identityJSON` | Public device identity JSON string ($\le 2048$ bytes) |
| `11` | `proof` | `signatureDER` | ASN.1 DER signature proving ownership of private identity key |
| `12` | `approve` | *(none)* | Explicit user consent confirmation |
| `13` | `receipt` | `receiptDER` | ASN.1 DER signature confirming durable local trust storage |
| `14` | `cancel` | *(none)* | Explicit pairing cancellation by either peer |

### Fragmentation
When payload exceeds ATT MTU capacity, messages are fragmented into chunks:

| Offset | Size | Type | Field | Description |
| :---: | :---: | :--- | :--- | :--- |
| `0` | 1 | `uint8` | `version` | Must be `1` |
| `1` | 2 | `uint16` (BE) | `messageId` | Monotonically increasing message identifier (starts at 0) |
| `3` | 2 | `uint16` (BE) | `totalLength` | Total unfragmented message byte count (1..4096) |
| `5` | 2 | `uint16` (BE) | `offset` | Byte offset of this fragment within the total message |
| `7` | $N$ | `bytes` | `chunk` | Fragment payload (up to ATT MTU $- 3 - 7$ bytes) |

**Constraints:**
- Maximum cumulative payload: **32,768 bytes** across both directions per pairing attempt.
- Fragments must arrive in contiguous order without gaps or overlaps.
- ATT value capacity is $\text{MTU} - 3$. The fragmentation header is 7 bytes.

---

## 3. Pairing Methods & Cryptography

### Method 1: QR Code
Used when the Android device can scan the Mac's screen. Requires no PAKE because the QR payload carries 256 bits of cryptographic entropy.

#### QR URI Format
$$\text{URI} = \texttt{anice:pair:1:} + \text{Base64URL\_NoPadding}(0\text{x}01 \,\|\, \text{rendezvous}_{16} \,\|\, \text{secret}_{32} \,\|\, \text{fingerprint}_{32})$$
- Exact decoded payload: **81 bytes**.
- `rendezvous`: 16-byte ephemeral session identifier.
- `secret`: 32-byte cryptographically random pre-shared key (PSK).
- `fingerprint`: 32-byte SHA-256 digest of Mac's uncompressed P-256 public key.
- QR symbol: Error correction **M**, 4-module quiet zone, automatic version.

#### QR Cryptographic Derivation
1. **Public Key Exchange:** Both devices generate ephemeral P-256 keypairs.
2. **Transcript:**
   $$T = \text{fields}(\text{"aniCe pairing v1"}, \text{method}_{1}, \text{rendezvous}, \text{clientNonce}_{32}, \text{serverNonce}_{32}, \text{clientPublic}_{65}, \text{serverPublic}_{65})$$
   $$H = \text{SHA256}(T)$$
3. **Bootstrap Key:**
   $$\text{ECDH} = \text{P256\_ECDH}(\text{private}, \text{peerPublic})$$
   $$K = \text{HKDF-SHA256}(\text{IKM}=\text{ECDH}, \text{salt}=\text{secret}_{\text{QR}}, \text{info}=\text{fields}(\text{"aniCe qr bootstrap v1"}, H), L=32)$$
4. **Key Derivation Function:**
   $$\text{derive}(K, \text{label}, H) = \text{HKDF-SHA256}(\text{IKM}=K, \text{salt}=H, \text{info}=\text{"aniCe pairing v1 "} \,\|\, \text{label}, L=32)$$
5. **Authentication MACs:**
   - Server MAC: $\text{HMAC-SHA256}(\text{derive}(K, \text{"server-auth"}, H), T)$
   - Client MAC: $\text{HMAC-SHA256}(\text{derive}(K, \text{"client-auth"}, H), T)$
   - Channel Confirmation: $\text{HMAC-SHA256}(\text{derive}(K, \text{"channel-confirm"}, H), T)$

---

### Method 2: Six-Digit PIN (PAKE)
Used when camera scanning is unavailable. Prevents offline dictionary attacks against short PINs via the standard **OPAQUE** protocol.

- **PAKE Library / Standard:** IETF OPAQUE draft (`opaque-ke 4.0.1`).
- **Cipher Suite:**
  - OPRF: `Ristretto255`
  - Key Exchange: `TripleDH<Ristretto255, SHA-512>`
  - KSF: `Argon2id` ($m = 65{,}536\text{ KiB}, t = 3, p = 1$)
- **Identifiers:** `client = "android"`, `server = "macos"`. Credential identifier: `rendezvous`.
- **Context:** $\text{fields}(\text{"aniCe pin bootstrap v1"}, \text{method}_{2}, \text{rendezvous}, \text{clientNonce}_{32}, \text{serverNonce}_{32})$.
- **Session Key Derivation:**
  $$K = \text{HKDF-SHA256}(\text{IKM}=\text{sessionKey}_{\text{OPAQUE}}, \text{salt}=H, \text{info}=\text{"aniCe pin bootstrap v1"}, L=32)$$

---

### Directional Encryption (AEAD)
All inner messages (types 10–14) are encrypted using AES-256-GCM under directional keys:
- Client to Server: $K_{\text{c2s}} = \text{derive}(K, \text{"client-to-server"}, H)$
- Server to Client: $K_{\text{s2c}} = \text{derive}(K, \text{"server-to-client"}, H)$
- Nonce (12 bytes): `0x00000000` (4 zero bytes) $\,\|\,$ `counter` (8-byte big-endian uint64). Counter starts at 0 and increments strictly by 1.
- Additional Authenticated Data (AAD):
  $$\text{AAD} = \text{fields}(\text{"aniCe pairing encrypted v1"}, H, \text{direction}_{1}, \text{counter}_{8})$$

---

### Identity Proof & Storage Receipts

1. **Identity Proof:** Proves possession of the long-term P-256 identity key:
   $$\text{ProofBytes} = \text{fields}(\text{"aniCe identity proof v1"}, H, \text{clientIdentityJSON}, \text{serverIdentityJSON}, \text{role}_{1})$$
   Signed with the device's persistent P-256 private key (`SHA256withECDSA`, ASN.1 DER format).
2. **Mutual Consent:** Both users approve the verified peer identity on their physical screens.
3. **Signed Storage Receipt:** Confirms the peer identity was committed to local storage:
   $$\text{ReceiptBytes} = \text{fields}(\text{"aniCe trust stored v1"}, \text{SHA256}(\text{ProofBytes without role}), \text{role}_{1})$$
   Signed with the local P-256 private key and transmitted to the peer.

---

## 4. Lifetimes & Deadlines

| Phase | Time Limit | Action on Expiry |
| :--- | :---: | :--- |
| **Invitation Window** | 120 seconds | Invitation revoked; GATT characteristics close |
| **Android Scan Window** | 15 seconds | Bounded candidate search ends |
| **Authentication Phase** | 30 seconds | Channel aborted; retry attempt consumed |
| **User Approval Phase** | 60 seconds (bounded by invitation) | Prompt dismissed; handshake aborted |
| **Receipt Exchange** | 10 seconds | Abort pending trust commit |
| **GATT Teardown** | $\le 2$ seconds | Channel resources cleaned up |
| **Max Authentication Attempts** | 5 attempts | Invitation permanently invalidates after 5 failures |

---

## 5. Security & Privacy Rules

1. **No BLE Identity Broadcast:** Device names, identity keys, and Bluetooth hardware addresses are never broadcast in unencrypted BLE advertising.
2. **Channel Retirement on Malformed Input:** Malformed unauthenticated packets terminate the immediate candidate connection without revoking the parent invitation.
3. **Constant-Time Verification:** Authentication MACs and hashes are compared using constant-time equality checks.
4. **Memory Hygiene:** PIN inputs, ephemeral keys, and PAKE handles are zeroized upon completion or failure.
