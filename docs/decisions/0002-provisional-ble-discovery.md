# 2. Provisional BLE discovery

Date: 2026-10-07

Status: **Provisional**

## Decision

Phase 3 uses the Mac as a Core Bluetooth peripheral and Android as a BLE central. One fixed public 128-bit aniCe service UUID identifies the protocol, not a secret or identity. The advertisement supplies only that service UUID and generic local name `aniCe`. Names are best effort and never a validation requirement. The rotating token is read from GATT, not advertised.

The [version 1 contract](../../protocol/bluetooth/README.md) is a 20-byte read-only unauthenticated compatibility payload: version, optional flags, and a 16-byte cryptographically random nonce. The Mac generates it on each start, rotates every 30 seconds, and erases it on stop. A nonce does not authenticate a peer or prove freshness to Android. Phase 4 adds separate pairing characteristics; ADR 0004 keeps their public layout stable and gates access by an explicit invitation. The discovery payload is unchanged; incompatible mandatory semantics require a new version.

Discovery is explicit and bounded: Mac advertises for 120 seconds; Android scans for 15 seconds and allows 15 seconds for connection/service discovery/read, followed by at most 2 seconds for disconnect cleanup. Mac startup has a 10-second watchdog after authorization resolves. Android foreground exit cancels; configuration recreation does not. Mac window closure leaves the companion's bounded operation running; sleep and Quit stop it. No background scan, automatic retry, restoration, bonding request, identity exchange, or trust writes are implemented.

Android uses a scan address solely in the active scan's internal deduplication map, clearing it and all rows when the scan ends. UI receives opaque scan-local row IDs. Only the selected connection handle survives until client cleanup. Retry always scans again. No BLE identifiers, payloads, or nonces are persisted or logged. OS radio addressing is outside app-controlled advertisement fields.

Use native framework permissions only on discovery action. Mac requires the sandbox Bluetooth entitlement and usage description. API 31+ Android requests scan/connect; API 29–30 requests fine location with legacy Bluetooth declarations and location-services recovery. No Google Play Services or background location is required.

## Consequences

Discovery establishes compatibility only. Multiple generic candidates cannot be authenticated or reliably associated with the intended Mac until Phase 4. Phase 4 refines QR to an ephemeral rendezvous token, high-entropy secret and identity fingerprint commitment; the public identity record follows authentication. QR contains no BLE address or system peer UUID as permanent cross-platform identity.

Real hardware is required for acceptance, including API 29 and macOS 14. OS termination cleans system handles; restart is idle and does not resume discovery. Do not claim that stopping Mac advertising forcibly disconnects a central.

## References

- [Apple advertising](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/startadvertising(_:))
- [Bluetooth sandbox entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.bluetooth)
- [Bluetooth usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription)
- [Android permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions)
