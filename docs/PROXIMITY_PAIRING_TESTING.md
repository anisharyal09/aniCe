<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Separates synthetic preview coverage from user-operated native pairing acceptance. -->
# Nearby pairing physical checks

Use explicitly approved isolated Mac and Android previews from the same source. Keep production identity, trust and permissions separate. Do not reset identities, remove existing pairings or native associations, or install/replace previews unless the user approves those actions. If the previews already have trusted peers, first setup requires an approved clean preview installation or a separate test fixture; do not silently clear trust to make discovery eligible.

Record phone model/OS, Mac OS, build/commit, grant/denial outcomes and any failure text. Mark untested conditions **not checked**, not passed. Method 3 is provisional and not independently audited; physical checks cannot establish cryptographic security or protection from Bluetooth relays.

## First pairing

- [ ] Keep both devices unlocked, Mac awake and Android Home visible.
- [ ] On unpaired Android, grant Nearby Devices only through the native request. Discovery starts without Find nearby; denial retains a clear recovery action and does not repeat the request on every foreground return.
- [ ] With one qualified Mac, one comparison opens after the ambiguity check. With multiple candidates, explicit selection remains required; omit this check if a second test Mac is unavailable.
- [ ] Before both confirmations, labels stay generic and both screens show the same six digits, including leading zeros.
- [ ] Confirm on one device only: the other still requires explicit Confirm. Neither saved trust nor Connected is claimed from one confirmation.
- [ ] Confirm both: trust completes, then fresh secured BLE connects to that Mac, not another discovered device. A transport failure leaves saved trust intact.
- [ ] QR and entered-PIN pairing still work when deliberately selected. Their native post-pair auto-connect setup follows the same authenticated Mac.

## Mac Bluetooth-off recovery

- [ ] Turn off Mac Bluetooth before nearby setup. After discovery cleanup, the inactive row still says **Bluetooth is off on this Mac. Turn it on in System Settings → Bluetooth, then choose Find nearby again.**
- [ ] **Open Settings** from that inactive row opens System Settings → Bluetooth, not Privacy & Security. A retry that is not yet eligible keeps the failure visible instead of reverting to generic discovery guidance.
- [ ] Turn Bluetooth back on and choose **Find nearby**. Eligible availability resumes without creating trust or enabling automatic connection preferences.

## Comparison presentation and cancellation

- [ ] Inactive/closed Mac window uses the floating comparison without stealing typing focus. Clicking the heading/code opens aniCe without approval.
- [ ] Floating Confirm approves that attempt and opens the regular Devices window; Enter and Escape operate only on the visible current attempt.
- [ ] Switch between floating/in-app Mac and Android Home/Add device: attempt and code remain the same; navigation alone never confirms or dismisses.
- [ ] Dismiss from either device: no silent exchange retry; explicit Find nearby / Try again is required. Mac cooldown cannot be cleared by repeated clicks.
- [ ] Lock the phone, background comparison, sleep/lock the Mac or Quit during a pending comparison: the attempt ends. Late Confirm cannot activate it.
- [ ] Let comparison expire; a later retry uses a fresh attempt. Do not infer a fresh attempt solely because six random digits happen to differ.
- [ ] Light/Dark and 80%/120% text remain readable with reachable Confirm/Dismiss. Mac Reduce Transparency stays solid; macOS 14/15 uses native material and macOS 26+ may use native glass. Check older OS fallback only when available.

## Native auto-connect approval

- [ ] After secured BLE, Android offers one single-Mac native approval—not a broad device-management chooser or a second aniCe setup activity.
- [ ] Watch the pre-approval handoff on the phone. The app adds no preparation frame or duplicate progress indicator while Android owns the request. Android may still show **Looking for a device** before Allow; record any visible flicker. That screen and its wording are system-owned, not app-styled.
- [ ] Rotate the phone during approval: it does not create another request.
- [ ] Decline/cancel: pairing stays intact, automation is not enabled and the request does not repeatedly reopen.
- [ ] Approve: subsequent nearby/foreground return resumes valid saved setup quietly, without another native approval.
- [ ] Cancel, lock or expire setup before returning its result: it cannot arm a retired request or replace a newer setup.
- [ ] Auto-connect approval does not grant feature permissions.

## Connection lifecycle

- [ ] With Auto connect off, briefly leave and return within the fifteen-second unlocked manual-BLE grace: the same secured connection remains.
- [ ] Exceed that grace without another eligible owner: manual BLE retires. Phone lock and explicit Disconnect do not receive unlocked grace.
- [ ] Cancel stops a pending connection without disabling the saved automatic preference; a later explicit/event-scoped retry remains possible.
- [ ] Pause closes both transports and resumes only previously enabled choices when its selected deadline expires or the user resumes.
- [ ] Renaming preserves the credential and setup. Trust removal/identity reset retires it; test those destructive actions only on an approved disposable preview.

## Native LAN acceptance

- [ ] Use an explicitly approved test phone on the Mac's reachable local Wi-Fi network and verify Bonjour discovery before authenticated TCP readiness. Keep the normal phone installation untouched unless separately authorized.

The emulator's simulated Wi-Fi is not the Mac's physical LAN. A native Bonjour interchange failure there remains failed evidence, not a pass or grounds to remove local-route filtering. Shared fixtures and a separate session interchange do not replace this real-network check.

The [background guide](BACKGROUND_CONNECTIONS.md), [discovery contract](../protocol/bluetooth/PROXIMITY.md), [SAS contract](../protocol/pairing/SAS.md) and [enrollment contract](../protocol/bluetooth/COMPANION_SETUP.md) own behavior and deadlines. RSSI qualification is a UX filter, not a distance or authentication measurement. Record visible skips and minimum-OS checks separately from real-device passes.
