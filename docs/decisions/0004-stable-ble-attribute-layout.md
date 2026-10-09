# ADR 0004 — Stable BLE attribute layout and GATT cache invalidation

Status: accepted for implementation; radio and hardware acceptance pending.

## Context

When an Android central connects to a macOS peripheral across alternating discovery and pairing operations, Android's Bluetooth stack (`BluetoothGatt`) caches remote GATT attribute tables in memory, indexed by Bluetooth address.

In earlier implementations:
1. The macOS peripheral dynamically mutated its attribute table between discovery (exposing only characteristic `303902`) and pairing (exposing `303902`, `303903`, `303904`).
2. The peripheral database was cleared and rebuilt upon each advertising stop and start.
3. Consequently, an Android device that previously performed discovery retained an in-memory attribute table containing only `303902`. Upon connecting for pairing, Android's `discoverServices()` resolved against its local cache in milliseconds without over-the-air queries, reporting zero pairing characteristics and terminating setup.

## Decisions

### 1. Stable Peripheral Attribute Layout
- From initial peripheral manager startup, macOS publishes a single fixed primary GATT service (`414E4953-4843-654A-494C-534149303901`) containing all three characteristics:
  - `303902`: Read (discovery compatibility probe)
  - `303903`: Write with response (pairing/session incoming control pipe)
  - `303904`: Indicate (pairing/session outgoing reply pipe)
- This attribute profile remains registered across discovery, pairing, trusted-session, and idle windows.
- Stopping discovery or pairing stops BLE advertising and clears application session callbacks, while preserving the published GATT database.
- Attribute access is gated at the application layer: reads fail outside an active discovery window, and pairing writes/indications are rejected without an explicit active invitation.

### 2. Android Cache Invalidation & Compatibility Fallback
- **Opportunistic Cache Invalidation:**
  The Android central invokes the hidden `BluetoothGatt.refresh()` method via reflection upon connection setup and whenever service discovery returns an incomplete profile layout. This flushes Android's internal attribute cache and forces fresh over-the-air service enumeration.
- **Handling Non-SDK Interface Restrictions:**
  Per [Android Compatibility Restrictions on Non-SDK Interfaces](https://developer.android.com/guide/app-compatibility/restrictions-non-sdk-interfaces), reflective access to internal framework methods is subject to platform restrictions. The reflective call is defensively caught (`catch (Throwable)`). If reflection fails or is blocked by system policy, the client proceeds with public discovery APIs.
- **Actionable Recovery:**
  If pairing characteristics remain absent after bounded rediscovery (with 300 ms callback backoff), the transport reports a specific failure with a direct shortcut to system Bluetooth Settings (`PairingTransportRecovery.bluetoothSettings`). Toggling Bluetooth cycles the system Bluetooth daemon, resetting the OS-level attribute cache cleanly without requiring device resets or OS-level pairing.

### 3. Diagnostics and Channel Isolation
- Telemetry records discovered profile counts and characteristic presence. Device addresses, hardware identifiers, cryptographic keys, nonces, and payload bytes are never logged.
- Malformed or unauthenticated packets retire only the immediate candidate connection. The parent invitation remains valid until its 120-second deadline or the 5-attempt limit is reached.

## Trusted-session extension

The same write/indicate characteristics carry version-2 session fragments with a nine-byte `u8 version | u32BE messageId | u16BE totalLength | u16BE offset` header. Pairing keeps version 1 and its seven-byte header; operating mode selects the codec and authentication owner. The session envelope discriminator is defined only in [`protocol/session/README.md`](../../protocol/session/README.md).

Candidate admission stops advertising. Established writes/indications depend on the retained candidate and session generation, independently of advertising confirmation or the original admission deadline. The peripheral retires application access on teardown; Core Bluetooth does not expose force-disconnection of a central. A failed candidate may resume admission within the original 120-second window and five-failure cap.

Android shares scan, setup, subscription, submission queue and teardown through `AndroidGattTransport`; pairing uses its v1 API alias. Both native transports enforce one reassembly buffer and logical outbound capacity before session nonce reservation. Reassembly/submission deadlines are ten seconds; session teardown is bounded to two seconds.
