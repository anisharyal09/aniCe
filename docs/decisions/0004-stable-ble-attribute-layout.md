# ADR 0004 — Stable BLE attribute layout and GATT cache invalidation

Status: accepted for implementation; user manual/radio acceptance pending.

## Context

When an Android central connects to a macOS peripheral across alternating discovery and pairing operations, Android's Bluetooth stack (`BluetoothGatt`) caches remote GATT attribute tables in memory, indexed by Bluetooth address.

In earlier implementations:
1. The macOS peripheral dynamically mutated its attribute table between discovery (exposing only characteristic `0902`) and pairing (exposing `0902`, `0903`, `0904`).
2. The peripheral database was cleared and rebuilt upon each advertising stop and start.
3. Consequently, an Android device that previously performed discovery retained an in-memory attribute table containing only `0902`. Upon connecting for pairing, Android's `discoverServices()` resolved against its local cache in milliseconds without over-the-air queries, reporting zero pairing characteristics and terminating setup.

## Decisions

### 1. Stable Peripheral Attribute Layout
- From initial peripheral manager startup, macOS publishes a single fixed primary GATT service (`414E4953-4853-4149-4A49-4C4365090901`) containing all three characteristics:
  - `0902`: Read (discovery compatibility probe)
  - `0903`: Write with response (pairing incoming control pipe)
  - `0904`: Indicate (pairing outgoing reply pipe)
- This attribute profile remains registered across discovery, pairing, and idle windows.
- Stopping discovery or pairing stops BLE advertising and clears application session callbacks, while preserving the published GATT database.
- Attribute access is gated at the application layer: reads fail outside an active discovery window, and pairing writes/indications are rejected without an explicit active invitation.

### 2. Android Cache Invalidation & Compatibility Fallback
- **Opportunistic Cache Invalidation:**
  The Android central invokes the hidden `BluetoothGatt.refresh()` method via reflection upon connection setup and whenever service discovery returns an incomplete profile layout. This flushes Android's internal attribute cache and forces fresh over-the-air service enumeration.
- **Handling Non-SDK Interface Restrictions:**
  Per [Android Compatibility Restrictions on Non-SDK Interfaces](https://developer.android.com/guide/app-compatibility/restrictions-non-sdk-interfaces), reflective access to internal framework methods is subject to platform restrictions. The reflective call is defensively caught (`catch (Throwable)`). If reflection fails or is blocked by system policy, the client proceeds with public discovery APIs.
- **User-Actionable Recovery:**
  If pairing characteristics remain absent after bounded rediscovery (with 300 ms callback backoff), the transport reports a specific failure with a direct shortcut to system Bluetooth Settings (`PairingTransportRecovery.bluetoothSettings`). Toggling Bluetooth cycles the system Bluetooth daemon, resetting the OS-level attribute cache cleanly without requiring device resets or OS-level pairing.

### 3. Diagnostics and Channel Isolation
- Telemetry records discovered profile counts and characteristic presence. Device addresses, hardware identifiers, cryptographic keys, nonces, and payload bytes are never logged.
- Malformed or unauthenticated packets retire only the immediate candidate connection. The parent invitation remains valid until its 120-second deadline or the 5-attempt limit is reached.
