# Background BLE connections

## Implementation and release gate

One application-scoped Android `SessionController` owns transport, EDHOC/readiness, records and operation generations. Native `StateFlow` publishes connection/control/renewal progress to the background owner independently of Compose snapshot application. Activities contribute presentation tokens; only an OS-bound `CompanionDeviceService` supplies background ownership. Manual connections close when the final presentation stops without a companion lease. No activity starts or binds the companion service itself.

Automatic nearby recovery, negotiated keepalive, fresh-session renewal, and Mac automatic availability are implemented. Android uses one device-level **Connect automatically** switch. First setup uses the native companion chooser; association is a locator/OS lease, never authentication. EDHOC pins the selected active device ID, fingerprint and key under the current local identity. Wrong first-time candidates remove their newly created association. Identity and trust journals are preserved.

Notification-free companion support is enabled in main resources for Android API 31+ (`res/values-v31/bools.xml`), providing background ownership across both Debug and Release builds on supported platforms. Legacy API 29–30 targets retain manual connections via base resources (`res/values/bools.xml`). Foreground-service fallback and phone-reboot recovery are not implemented; Background LAN leases and feature-specific integrations remain deferred.

## Native API paths

| Android API | Presence ownership |
| --- | --- |
| 29–30 | Service disabled; manual connections |
| 31–32 | Address observation and address callbacks |
| 33–35 | Address observation; callbacks matched by association ID |
| 36 | Association-ID requests; separate BLE advertisement and Bluetooth-connection events |

The nonexported setup activity and service live in main sources. The service requires `android.permission.BIND_COMPANION_DEVICE_SERVICE`; the build gate controls its enabled state. Native service creation and same-instance `onRebind` restore ownership even when CDM omits cached presence callbacks. `onUnbind` requests rebind notification and clears the lease; callbacks delivered while unbound cannot restore it. Destruction permanently retires that instance. Duplicate events reacquire a resumed lease. Every attempt revalidates the native association and pinned trust. On API 36, advertisement loss alone does not retire a transport while Bluetooth presence remains active. Association addresses are normalized to uppercase for `BluetoothAdapter`; temporary addresses are never trust credentials.

## Android policy

Saved preferences bind one selected peer ID/fingerprint to the local fingerprint, native association ID/address, automatic/paused flags and an authenticated-association marker. The existing bounded diagnostic log is retained. Private keys, session material, record counters, transports and generations remain in memory. Observation is registered only after active trust validation; a registered observation is not successful authentication.

Connection settings match the displayed device ID and fingerprint before showing enabled state, diagnostics or Reset setup. Actions recheck that binding. Enabling a different Mac explicitly retires the prior association before opening the chooser; merely opening another Mac's settings does not change the selected setup.

A live service lease serializes attempts. Transient failures use 2, 5, 15, 30, 60 and 90-second base delays with ±10% jitter and a 90-second cap applied after jitter. Presence loss cancels the entire retry chain; radio-off waits for radio recovery. Rejected locators are excluded for 60 seconds in an in-memory set capped at 32. No periodic wake alarms or unowned scan loop is used.

| Event | Policy and session action |
| --- | --- |
| Presence appears / duplicate callback | Acquire the system lease; start or retain one pinned attempt |
| Service disappearance/unbind | Cancel attempts/retries; retire session; wait for presence |
| System rebind of the same service | Restore unknown presence facts and restart only enabled, unpaused, trusted setup |
| Transient disconnect or missed PONG | Retire old operation; bounded retry only while owned and permitted |
| Disconnect | Persist pause before teardown; stop retries/access; retain association and native observation |
| Switch off | Save automatic off/paused; stop observation/retries and release the service lease. Retain a secured foreground channel as manual work unless renewal is pending; background channels close |
| Checkbox on / explicit Connect after pause | Revalidate remembered trust/association; resume observation |
| Pairing/discovery | Suspend automatic attempts; restore policy after the exclusive operation |
| Revocation / identity reset | Retire session and selected setup; require explicit correction |
| Permission/association loss / legacy peer | Pause with an actionable explanation; manual connection remains available |
| Reset connection setup | Invalidate chooser jobs, release keys/access, remove only its association |

Stop invalidates chooser/setup/session generations before disk or suspended crypto work. Resume reserves its generation before association/trust validation; retired results and failures become cancellation, so callers cannot re-enable or pause a newer setup. A failed preference write cannot retain live application access. Pause retains observation but runs no connection/retry work; disabling stops observation. Restored system bindings treat an omitted presence source as unknown until its callback or native unbind, rather than inventing an absence. Restored configuration requires the original local identity and an active matching peer. OS rebinding can recover a process; force-stop has no automatic-recovery promise. Reboot recovery is not enabled.

An authenticated Mac CLOSE retires Android's operation generation, releases its channel and GATT transport, and publishes disconnected state with terminal feedback. Nearby retry remains eligible only with enabled, unpaused policy and native ownership. Coroutine cleanup explicitly targets `SessionController`; cancelling its worker alone leaves stale presentation and transport ownership.

## Mac policy

The window and menu companion share one opt-in **Connect automatically** policy and allowed-phone selection. A target is frozen per attempt and resolved against active trust. Empty trust cannot enable automatic admission. The slot holds one candidate/session; other centrals cannot join it. Automatic availability advertises only while the slot is empty, stops advertising on admission, and renews empty 120-second periods. Five failed candidates in a period trigger a 120-second cooldown. Unknown candidates consume admission failures without disabling valid trust.

Manual Allow connections retains its 120-second window. Disconnect pauses automatic availability before cleanup. Switch off disables it; enabling again clears pause. Closing the window retains the menu companion; sleep retires the channel and wake restores enabled availability. Quit stops all operations. Automatic login launch is not implemented. Pairing/discovery temporarily suspend admission. Core Bluetooth application access is retired when physical central disconnection is unavailable.

Pairing cleanup restores automatic availability only if pairing and discovery are both idle at callback delivery. A newer exclusive operation retains the radio; stopping discovery can restore the saved automatic policy afterward.

## Liveness and renewal

[Authoritative control CDDL](../protocol/session/control.cddl) defines controls inside existing DATA kind 3/envelope 6. HELLO/ACK compatibility completes within ten seconds of readiness; Android PING follows 60 seconds without authenticated activity, with one matching PONG due within 20 seconds. Unsupported peers retain manual operation; automatic policy pauses. Controls consume ordinary record sequences and never increment diagnostic check counters.

Automatic renewal starts at 55 minutes or `2^20 − 1024` records in either direction. Mac sends one request; Android coalesces requests, blocks application submissions, retires the old session within two seconds, then performs fresh EDHOC/readiness if policy/ownership still permit it. Stop outranks renewal. Queue preflight precedes nonce reservation; encryption/post-seal submission failures burn the sequence and retire the session.

Hard bounds remain: ten-second readiness, 120-second idle, one-hour age, `2^20` records/direction, 4,000-byte plaintext, 4,096-byte logical messages and eight queued messages/32 KiB. All deadlines are monotonic; Android elapsed realtime includes sleep. OS suspension may miss a deadline and disconnect. Owned mutable secrets are overwritten and key objects released; JVM/Swift zeroization is best effort.

## Idle maintenance

### Architecture and event-driven scheduling

Prior builds ran periodic maintenance loops (1-second intervals while secured, 200 ms during handshake and readiness) that queried KeyStore/Keychain and flash storage on every tick. This periodic polling established an initial workload baseline with median CPU utilization of ~3.166% on Android and ~0.385% on macOS across three 5-minute sampling intervals.

The updated architecture replaces recurring polling loops with cancellable waits for the earliest absolute monotonic deadline. Candidate admission, authentication, readiness, control compatibility, PING/PONG liveness, idle expiry (120 s), hard session lifetime (60 min), renewal (55 min), and partial-frame assembly each retain their existing bounds. The wait is recalculated upon state transitions, authenticated packet reception, successful transmission, or capacity release. Pending controls with no immediate queue capacity await capacity events rather than busy-waiting; an overdue PING cannot arm a zero-delay wake loop.

Android deadline enforcement operates independently of its bounded control worker. Active signing or native validation cannot block hard session or GATT assembly retirement. While control work is queued, snapshots defer actionable PING or renewal triggers while preserving hard readiness, idle, lifetime, and outstanding PONG bounds. Completion requests a new snapshot once the worker becomes idle, coalescing transport events without recursive crypto dispatch.

### Security validation boundaries

Quiet deadline calculation and deadline-only waits perform zero identity, KeyStore, Keychain, or flash reads. Every encrypted transmission and reception (including keepalive HELLO, PING, and PONG controls) retains full current native identity, hardware protection, and active in-memory trust validation. Signing, key export, queue preflight, and submission retain their rechecks after suspended work. No timed identity cache is introduced.

Trust stores maintain validated records in memory; explicit revocation, identity reset, or journal recovery immediately retires both BLE and LAN transport owners through service invalidation callbacks. Changes occurring outside application mutation paths are caught upon the next authenticated operation rather than through background storage polling. Android production clocks use elapsed realtime so deep sleep counts toward deadlines. Mac sleep retires both transports.

Android TCP reads block while no frame is being assembled; a partial frame sets the socket read timeout to its remaining ten-second assembly budget. Descriptor closure unblocks a retired read. Native write watchdogs remain ten seconds. The Mac admission countdown updates only in its visible SwiftUI timeline, separately from security maintenance. Identity services expose process-local load counters for diagnostics; counters contain no key or peer material.

### Verification harness and measured workload

The physical test harness (`PhysicalSessionIdleTest`, invoked with `physicalIdle=ble`) asserts connected-idle stability:
1. Waits up to 180 seconds for a secured physical BLE channel with negotiated keepalive controls.
2. Warms up for two minutes without generating synthetic traffic.
3. Samples three consecutive five-minute intervals, asserting unchanged connection continuity, static manual check counts, and exact identity/trust journal byte matches.

Under matched Debug/USB test conditions, the updated event-driven architecture reduced median single-core CPU utilization from 3.166% to 0.322% on Android (0.325%, 0.284%, 0.322% across intervals) and from 0.385% to 0.030% on macOS (0.030%, 0.030%, 0.060%). Android recorded exactly thirty native identity loads for the ten authenticated keepalive records in each interval, confirming zero storage access during quiet idle periods.

These measurements verify relative software workload reduction on test hardware. Long-term unplugged battery consumption (in mAh/hr), deep OS Doze endurance, foreground UI spikes, and release companion ownership remain separate physical release gates.

## Reconnect acceptance

1. Establish an automatic connection with the phone locked. Mac Disconnect pauses admission; verify Android leaves Secured after authenticated CLOSE and Mac remains unavailable while paused.
2. Re-enable Mac Connect automatically with the phone untouched. Allow the existing retry backoff, capped at 90 seconds, plus connection/authentication time. Verify fresh EDHOC/readiness without opening the phone app, toggling Bluetooth or sending diagnostic checks.
3. Repeat with the phone removed from Recents. Pause/disable Android automatic setup and verify Mac availability cannot restart a stopped phone policy.

`ProbePresenceTest` covers unbound/stale events and missing-fact recovery. `CompanionBindingTest` injects same-instance framework callbacks on an unconfigured installation; it checks rebind, invalid intents, destroyed-instance retirement and unchanged identity/trust journals/preferences. Callback injection does not establish actual CDM/radio recovery.

`PhysicalSessionNavigationTest.authenticatedMacCloseRetiresControllerAndAllowsFreshRecovery` requires `physicalMacClose=<selected Mac device ID>` and existing automatic setup. It observes authenticated CLOSE, requires controller retirement within two seconds, then requires a distinct secured channel with negotiated controls after Mac automatic availability is re-enabled. Identity/trust bytes must remain unchanged.

References: [Android background BLE](https://developer.android.com/develop/connectivity/bluetooth/ble/background), [CompanionDeviceService](https://developer.android.com/reference/android/companion/CompanionDeviceService), [Secure session profile](../protocol/session/README.md).

Opening Android discovery leaves BLE/LAN owners untouched. Scan suspends automatic Bluetooth ownership before discovery starts; its busy-state callbacks restore eligible work after success, failure or cancellation. LAN remains independent. Android Devices resumes saved matching association setup directly through the existing policy owner; no settings activity is opened. First association and repair remain in native setup. Explicit disable removes renewal eligibility from retained foreground work; hard session limits and final-presentation/screen-lock cleanup still apply. Pause, trust revocation and native lease loss retain their teardown behaviour.
