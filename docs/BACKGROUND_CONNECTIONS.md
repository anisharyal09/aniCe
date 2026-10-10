# Background BLE connections

## Implementation and release gate

One application-scoped Android `SessionController` owns transport, EDHOC/readiness, records and operation generations. Native `StateFlow` publishes connection/control/renewal progress to the background owner independently of Compose snapshot application. Activities contribute presentation tokens; only an OS-bound `CompanionDeviceService` supplies background ownership. Manual connections close when the final presentation stops without a companion lease. No activity starts or binds the companion service itself.

Automatic nearby recovery, negotiated keepalive, fresh-session renewal, and Mac automatic availability are implemented. Android uses one device-level **Connect automatically** switch. First setup uses the native companion chooser; association is a locator/OS lease, never authentication. EDHOC pins the selected active device ID, fingerprint and key under the current local identity. Wrong first-time candidates remove their newly created association. Identity and trust journals are preserved.

Notification-free support remains gated: `companion_probe_supported` is false in main resources and true only in Debug API 31+. Release contains the shared setup/controller code and signature-protected service declaration, but disables service ownership and automatic setup. API 29–30 retain manual connection. Physical address stability, range/process recovery and endurance evidence are required before promoting this resource gate. Foreground-service fallback and phone-reboot recovery are not implemented in this increment; LAN and feature integrations remain deferred.

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

A live service lease serializes attempts. Transient failures retry after 2, 5, 15, 30 and 60 seconds, capped at 60, with ±10% jitter. Presence loss cancels the entire retry chain; radio-off waits for radio recovery. Rejected locators are excluded for 60 seconds in an in-memory set capped at 32. No periodic wake alarms or unowned scan loop is used.

| Event | Policy and session action |
| --- | --- |
| Presence appears / duplicate callback | Acquire the system lease; start or retain one pinned attempt |
| Service disappearance/unbind | Cancel attempts/retries; retire session; wait for presence |
| System rebind of the same service | Restore unknown presence facts and restart only enabled, unpaused, trusted setup |
| Transient disconnect or missed PONG | Retire old operation; bounded retry only while owned and permitted |
| Disconnect | Persist pause before teardown; stop retries/access; retain association and native observation |
| Switch off | Save automatic off and paused atomically; stop observation/access |
| Switch on / explicit Connect after pause | Revalidate remembered trust/association; resume observation |
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

Android BLE/LAN owners use one conflated event lane and a cancellable wait for the earliest absolute deadline. Mac owners use one cancellable task with revision checks around suspended deadline snapshots. Candidate admission, authentication, readiness, control compatibility, PING/PONG, idle expiry, lifetime, renewal and partial-frame assembly each retain their existing bounds. Receive, successful submission, capacity release and policy/state changes recalculate the wait. A pending control with no queue capacity waits for a capacity event or a future expiry; an overdue PING cannot create a zero-delay loop. Retired callbacks cannot arm waits for a newer candidate.

Android deadline enforcement runs independently of its one bounded control worker. Busy signing/native validation cannot block hard session or GATT assembly retirement. While control work is queued or active, snapshots exclude actionable PING/renewal wakes but retain hard readiness, idle, lifetime and outstanding PONG bounds. Completion requests a new snapshot after the worker is inactive; deferred transport events remain coalesced without recursively scheduling crypto.

Deadline calculation and deadline-only maintenance perform no identity, Keystore or Keychain reads. Every encrypted send and receive, including HELLO/PING/PONG, retains full current native identity/protection and active in-memory trust validation; suspended signing, export, queue preflight and submission keep their existing rechecks. No timed identity cache is introduced. Trust stores already keep validated records in memory; explicit revocation/reset/recovery retires both owners through service notifications. Mac trust notifications match the owning journal path, including separate instances of that journal. Android service invalidation synchronously retires published channel access before dispatching presentation cleanup.

Native identity/key/metadata changes outside app mutation paths are detected at the next authenticated operation rather than by idle storage polling. Out-of-process trust-file editing has no watcher; journal recovery and application revocation use explicit invalidation. OS suspension may deliver a wait late; record operations still reject expired access before encryption/decryption. Android uses elapsed realtime for production handshake, session and GATT assembly clocks. Mac sleep retires both transports. Companion leases, nearby retry/backoff and the Android Release gate are unchanged.

Android TCP reads block while no frame is being assembled; a partial frame sets the socket read timeout to its remaining ten-second assembly budget. Descriptor closure unblocks a retired read. Native write watchdogs remain ten seconds. The Mac admission countdown updates only in its visible SwiftUI timeline, separately from security maintenance. Identity services expose process-local load counters for diagnostics; counters contain no key or peer material.

Performance comparisons separate the original build, the Android identity correction and the maintenance correction. Each stage uses three five-minute connected idle intervals after two minutes of warmup, matching build type, charging and display state. Process CPU-time deltas divided by monotonic elapsed time express CPU as a percentage of one core. Record process continuity, transport interruptions, memory and available wakeup evidence. Disconnects invalidate an interval and remain reported failures. Debug/USB measurements establish relative workload changes; battery use and production background performance require separate measurements. Android Release companion ownership remains disabled.

`PhysicalSessionIdleTest` requires `physicalIdle=ble`. It waits up to 180 seconds for a secured physical BLE channel with negotiated controls, warms up for two minutes, then samples three five-minute intervals. Every sample asserts the same connection/channel and unchanged incoming check count. The report in app-private `files/idle-cpu-optimization.json` records process CPU time, identity loads, maintenance runs and directional record counts. Identity/trust journal bytes must remain unchanged. Keep charging, display and Mac surface constant; instrumentation may restart the Android app before connection setup.

The updated Debug/USB physical BLE run passed all three intervals with unchanged secured channel, negotiated controls, manual-check count and identity/trust bytes. CPU intervals were 0.325/0.284/0.322% on Android and 0.030/0.030/0.060% on Mac of one core; medians were 0.322% and 0.030%. Android recorded thirty native identity loads for ten encrypted records in each interval. Workload baseline medians were 3.166% Android and 0.385% Mac; baseline continuous channel/display state was not recorded. These measurements establish connected-idle workload improvement, with foreground spikes, LAN-only/simultaneous transports, Doze, battery, Release and minimum-OS acceptance still separate.

## Reconnect acceptance

1. Establish an automatic connection with the phone locked. Mac Disconnect pauses admission; verify Android leaves Secured after authenticated CLOSE and Mac remains unavailable while paused.
2. Re-enable Mac Connect automatically with the phone untouched. Allow the existing retry backoff, capped at 60 seconds, plus connection/authentication time. Verify fresh EDHOC/readiness without opening the phone app, toggling Bluetooth or sending diagnostic checks.
3. Repeat with the phone removed from Recents. Pause/disable Android automatic setup and verify Mac availability cannot restart a stopped phone policy.

`ProbePresenceTest` covers unbound/stale events and missing-fact recovery. `CompanionBindingTest` injects same-instance framework callbacks on an unconfigured installation; it checks rebind, invalid intents, destroyed-instance retirement and unchanged identity/trust journals/preferences. Callback injection does not establish actual CDM/radio recovery.

`PhysicalSessionNavigationTest.authenticatedMacCloseRetiresControllerAndAllowsFreshRecovery` requires `physicalMacClose=<selected Mac device ID>` and existing automatic setup. It observes authenticated CLOSE, requires controller retirement within two seconds, then requires a distinct secured channel with negotiated controls after Mac automatic availability is re-enabled. Identity/trust bytes must remain unchanged.

References: [Android background BLE](https://developer.android.com/develop/connectivity/bluetooth/ble/background), [CompanionDeviceService](https://developer.android.com/reference/android/companion/CompanionDeviceService), [Secure session profile](../protocol/session/README.md).
