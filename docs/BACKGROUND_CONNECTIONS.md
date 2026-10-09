# Background connection feasibility

## Implementation boundary

Android includes a debug-only companion device feasibility probe and an application-scoped session controller (`SessionController`). The user interface delegates connection lifecycle management to this controller. Manual connections terminate on app backgrounding and screen lock unless the system-bound companion device service acquires session ownership.

Production automatic connection, foreground-service fallback, reboot recovery, persistent Mac peripheral availability, application-control synchronization, keepalive heartbeats, and session renewal are not implemented. Full background operation remains gated by physical radio and OS daemon validation.

The feasibility probe reuses existing platform primitives: identity service, active trust storage, RFC 9528 EDHOC (method 0, cipher suite 5), encrypted readiness confirmation, and the directional AES-GCM record channel. The Android companion association acts strictly as an operating system lifecycle lease and transport locator, never an authentication credential. Candidates that fail cryptographic credential pinning are rejected, and their associated test state is cleared. Debug preferences operate independently of trust storage and contain no private keys, session nonces, or record counters.

## Native API paths

| Android Version | Native Platform Behavior |
| --- | --- |
| API 29–30 | Companion service disabled via manifest resource qualifiers; manual connection lifecycle retained. |
| API 31–32 | Address-based presence observation (`startObservingDevicePresence(String)`). |
| API 33–35 | Address-based observation registration; system presence callbacks matched by association ID. |
| API 36 | Association-ID presence observation requests (`ObservingDevicePresenceRequest`) with separate BLE advertisement and Bluetooth connection lifecycle events. |

The companion service (`CompanionProbeService`) is declared exclusively in the debug source set with signature permission `android.permission.BIND_COMPANION_DEVICE_SERVICE`. The probe activity is not exported. Release builds omit both components and companion permissions entirely. Only system binding confers background session ownership; the activity does not launch or bind the service.

On API 36, BLE advertisement loss and Bluetooth transport disconnection are evaluated independently. An advertisement disappearance does not terminate an active session while a Bluetooth connection event confirms active presence. Session operations maintain generation counters to reject stale asynchronous results. User interface ViewModel destruction does not release a companion-held session lease.

Association MAC addresses are normalized to uppercase prior to persistence and `BluetoothAdapter` lookup to comply with native framework validation. Diagnostics log discrete failure stages and exception class names; peer MAC addresses, exception messages, and sensitive payloads are excluded from event records.

## Ownership and lifecycle

`SessionController` manages the application coroutine scope, a single GATT transport instance, and the active session operation. State mutations and transport dispatches execute on the main thread; cryptographic handshakes and record processing dispatch to IO.

Each active activity registers a presentation token. Navigating between Home and the debug probe screen preserves an active manual connection as long as at least one activity remains started. Removing the final presentation token triggers a clean disconnect for manual sessions. Configuration changes update tokens without severing connections. When the companion service acquires a session lease, the session remains active across UI backgrounding and device lock until the service releases ownership or a fatal transport/crypto failure occurs.

Stale state protection is enforced at three boundaries:
1. **Activity chooser generation:** Rejects obsolete device chooser callbacks.
2. **Probe setup token:** Invalidates pending setup jobs if the test is cancelled or stopped.
3. **Session operation generation:** Discards asynchronous cryptographic and transport callbacks from prior attempts.

Companion session leases use object-identity equality, preventing stale or unbound service instances from terminating a newly acquired lease.

| Event | Session Action | Association Action |
| --- | --- | --- |
| System presence appears | Resolve active trust, acquire session lease, initiate EDHOC handshake | Maintain active observation |
| Duplicate presence callback | Retain existing connection attempt | None |
| Presence disappears or service unbinds | Release companion lease and terminate session | Maintain observation for future discovery |
| Handshake failure or authenticated peer close | Terminate session and cancel probe | Stop observation and remove OS association |
| Explicit stop test | Invalidate setup, release companion lease, and disconnect probe | Stop observation and remove OS association |
| UI ViewModel cleared | Release UI callbacks; preserve session if presentation or companion lease remains | None |

Observation registration and peer authentication are distinct states. The `armed` flag reflects saved probe configuration. Successful observation registration indicates the system framework accepted the request; verified connectivity requires successful EDHOC exchange and encrypted readiness confirmation. Probe cancellation initiates OS disassociation even if persistent preference updates fail. Failures do not trigger automatic retry loops.

Debug preferences record `peer`, `fingerprint`, `local`, `address`, `association`, `armed`, and `events`. Keys, record counters, and live transport references exist only in transient memory.

## Verification procedure

1. Install the Debug APK, complete standard pairing, and establish a manual connection.
2. Navigate to **More → Background connection test**. Navigating into and out of this screen maintains the existing manual connection.
3. Tap **Start setup** to terminate the manual connection and prepare for companion pairing.
4. On the Mac, open **Allow connections**.
5. Tap **Associate Mac** on Android and select the Mac in the system companion chooser.
6. Open **Show test events** and confirm the transition to **EDHOC and readiness verified**.
7. Test bidirectional communication using connection checks. Lock the Android device or switch to recent apps, send a check from the Mac, and confirm receipt in the diagnostic event log.
8. Validate range and reconnect behavior by toggling Bluetooth or moving out of range while the Mac advertises.
9. Tap **Stop test** upon completion. This terminates the session, unregisters presence observation, and removes the OS association.

Session hard limits apply: ten-second readiness timeout, 120-second idle limit, one-hour lifetime bound, and a `2^20` directional record limit. Automatic keepalive and re-keying are not implemented in this probe.

The diagnostic log maintains a bounded circular buffer of up to 64 monotonic-time entries. Logs capture state transitions and check counters; payloads, cryptographic keys, and device addresses are omitted.

## Acceptance matrix

| Verification Target | Methodology | Status |
| --- | --- | --- |
| Duplicate presence events, advertising loss handling, rebind isolation | Unit test (`ProbePresenceTest`) | Pass |
| UI clearing, stale-owner release, setup cancellation | Native instrumentation (`SessionOwnershipTest`, `CompanionSetupTest`) | Pass |
| MAC address normalization and malformed address rejection | Native instrumentation (`CompanionSetupTest`) | Pass |
| BLE authentication retention across activity transitions | Native physical test (`PhysicalSessionNavigationTest`) | Pass |
| Native handshake and record provider conformance | Native instrumentation (`SessionNativeTest`) | Pass |
| Probe isolation from production binaries | Release manifest and build inspection | Pass |
| System association chooser discovery | Physical device verification | Pass |
| Background companion service binding and presence handling | Physical device verification | Pass |
| Locked-screen and background bidirectional traffic | Physical device verification | Pass |
| Out-of-range return and process recovery | Physical device verification | Pending |
| Long-duration session endurance and battery impact | Physical device verification | Pending |
| Minimum OS (API 29–30) fallback | Physical device verification | Pending |

References: [Android background BLE](https://developer.android.com/develop/connectivity/bluetooth/ble/background), [CompanionDeviceService](https://developer.android.com/reference/android/companion/CompanionDeviceService), [Secure session profile](../protocol/session/README.md).
