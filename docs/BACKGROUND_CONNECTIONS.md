# Background Bluetooth connections

aniCe uses one Android Bluetooth owner and one Mac availability policy. Pairing establishes trust; automatic connection uses that trust together with native ownership and the saved connection preferences.

## Set up

Enable **Auto connect** for the trusted device on Android and **Connect automatically** on the Mac. Android requires one native approval for background reconnection. This cannot be silently granted or restyled by aniCe. The association supplies a Bluetooth locator and OS ownership, not authentication: every connection still checks the pinned device ID, fingerprint and public key.

Unpaired Android Home requests native Nearby Devices access once on first foreground launch. Granting starts discovery automatically; denial retains a clear permission/settings action and does not trigger repeated startup prompts.

For nearby and QR/PIN pairing, **Reconnect automatically** starts on in the pairing sheet. After mutual confirmation and fresh secured BLE readiness, Android opens a single-device native approval for the currently verified Mac without a separate connection-settings detour. It filters the process-local authenticated locator; the Mac briefly advertises its existing generic service without reopening its occupied application slot. Cancellation preserves trust and returns to Home. See the [bounded setup contract](../protocol/bluetooth/COMPANION_SETUP.md).

All pairing methods and the Devices Auto connect preference use the same flow: connect with fresh pinned EDHOC first, then prepare native single-Mac approval. There is no intermediate Connection settings page or broad "device to manage" chooser. aniCe's inline notice reads **Reconnect when nearby, even in the background.** and notes that allowing this phone and Mac connection does not grant feature permissions: files, clipboard and control keep their own. Android owns the system consent title and its generic “sync info” description; aniCe cannot restyle or replace that platform copy. Android may briefly show its own **Looking for a device** scan screen before Allow. Both surfaces are system-owned; aniCe does not bypass native discovery or approve the result. The app does not intentionally wait an extra render frame before launching a ready native approval, and its own progress indicator is hidden while Android owns the visible scan/approval.

One retained setup owner survives activity recreation without reopening approval. Cancellation and expiry fence late results; a new process requires explicit retry instead of automatically repeating an interrupted chooser.

Automatic reconnection is event-driven, not continuous app polling. Android's native presence/foreground events start eligible connection work; failures have bounded retry spacing. Pause stops automatic work until resumed (or its selected deadline expires); it does not make a background polling loop run for that duration.

Android companion ownership requires API 31 or newer. API 29–30 use manual foreground connections. Approved transfers have a separate connected-device foreground service; they do not require automatic Bluetooth setup.

Only one Mac owns Android's saved automatic setup. Enabling another Mac explicitly replaces it only after connection verification. **Reset auto connect** in device diagnostics removes association and observation without resetting identity or pairing. Saved valid setup resumes without another native prompt. Older peers lacking the enrollment capability retain manual connections; no broad chooser bypass is used.

The UI's saved-setup indicator compares device ID and fingerprint metadata; it does not authorize enrollment or authenticate a connection. Valid identities bind the SHA-256 fingerprint to their canonical public key, so a changed key with the old fingerprint is invalid, not a supported rotation. Enrollment, quiet resume and fresh EDHOC revalidate active trust and the full credential. Name changes are presentation metadata and do not change that credential.

## Android policy

- Started activities contribute independent foreground tokens. Closing one activity does not release another that remains started.
- Already-secured manual Bluetooth has a fifteen-second return-to-app grace after the final presentation stops. Home/Recents and brief activity overlays within that window retain the same channel, even with Auto connect off. Duplicate stop events do not extend it; expiry is checked with elapsed realtime on return. Screen lock, radio loss, trust invalidation and explicit Disconnect still retire access immediately. Pending connections have no grace. This creates no reconnect, service or indefinite background ownership.
- Only Android's OS-bound companion service supplies companion ownership. The app does not start or bind that service itself.
- Explicit foreground enrollment may retain its already-secured BLE channel for at most sixty seconds while the native chooser is visible. This temporary lease grants no automatic recovery; screen lock still cancels unowned access.
- Releasing the final picker/approved-work lease after screen-off retires unowned BLE immediately, even before Activity stop; it cannot start an unlocked foreground-handoff grace while the phone is locked.
- Service loss/unbind releases ownership and stops its connection work. Native rebind and presence events can restore eligible work.
- API 36 distinguishes BLE-advertisement presence from Bluetooth-connection presence. Advertisement loss alone does not retire a transport while Bluetooth presence remains active.
- Foreground return reevaluates saved enabled setup even without a new presence callback.

Transient failures use one owned retry chain with 2, 5, 15, 30, 60 and 90-second delays, capped at 90 seconds with jitter. Presence loss cancels retries; radio-off waits for radio recovery. Repeated failures can use bounded service-filtered rediscovery, but a new locator must authenticate as the saved peer and cannot silently replace the association.

Fifteen uninterrupted seconds of authenticated readiness reset retry history. Brief connections and foreground/service handoffs do not reset it. Permission, association or trust failures show corrective feedback instead of retrying indefinitely.

Force-stop and reboot do not provide automatic recovery. Returning to the app can resume an enabled, valid setup.

## Mac policy

The main window and menu-bar companion share **Connect automatically** and allowed-phone selection. A connection attempt freezes its target against active trust. One candidate/session owns admission; other centrals cannot join it.

Manual **Allow connections** lasts 120 seconds. Automatic availability reopens empty 120-second windows while enabled and owned. Five failed candidates in a window trigger a 120-second cooldown. Established interruptions use the same bounded 2/5/15/30/60/90-second reopen policy, reset after fifteen seconds of stable readiness.

Closing the window retains the companion. Sleep retires connections; wake reevaluates enabled choices. Quit stops all work. Automatic login launch is not provided.

Pairing and active discovery temporarily suspend Bluetooth admission. Cleanup resumes eligible work only after the exclusive operation has ended. Radio-off retains native state observation; reset/unsupported/permission states stop application access.

If nearby setup encounters disabled Mac Bluetooth, its inactive setup row keeps **Bluetooth is off on this Mac** and directs the user to System Settings → Bluetooth, then **Find nearby** again. Cleanup must not replace that explanation with generic discovery copy or hide its settings action.

## Disconnect, disable and timed pause

| Action | Effect |
| --- | --- |
| Device Connect | Starts BLE and LAN together for the selected trusted peer; already-ready channels remain connected. |
| Cancel | Ends the current attempt and any pending Connect-to-Resume lookup without disabling the saved automatic choice; another connection event or explicit Connect can retry. |
| Disconnect | Closes the selected transport and pauses its automatic work; a new local file selection/send can request LAN again when automatic LAN is enabled. |
| Resume / explicit Connect | Revalidates remembered setup and resumes eligible work. |
| Switch automatic connection off | Stops observation and retries; a secured foreground or approved-work channel can remain manual. |
| Reset setup | Removes that native association; identity and peer trust remain. |
| Remove trust / reset identity | Retires both transports and invalidates the associated setup. |

A timed **Pause** closes BLE and LAN and stores a wall-clock resume deadline, or an indefinite pause. It does not keep an active transfer connected. Expiry restores only previously enabled choices; it never enables a disabled preference. App return, wake, network/presence events and clock changes reevaluate the deadline. A newer pause or disabled choice supersedes the old deadline.

Pause stops unfinished admission immediately; only already-secured channels remain briefly available for the best-effort peer notice. Duplicate native presence callbacks do not undo Cancel. Android foreground return can restart a retained companion owner's recovery without requiring another presence callback.

**Resume** acts immediately; only **Pause** opens the duration menu. The Auto connect switch shows currently armed work, so it is off during a local pause. A current secured peer can receive a [pause notice](../protocol/connection-pause/README.md) before teardown and show **Paused on &lt;device&gt;**. This does not alter that peer's saved automatic choice; fresh secured connection, expiry or local Resume/Connect clears the notice.

A new file action from either updated peer can resume a transport-level LAN Disconnect, but never a timed/indefinite **Pause**, disabled automatic LAN or invalid trust. Passive feature traffic and automatic transfer recovery retain the Disconnect pause.

First-time [nearby pairing](../protocol/bluetooth/PROXIMITY.md) has a separate known-empty-trust lifetime: anonymous Mac availability while awake/unlocked and foreground/unlocked Android discovery. It uses the same exclusive BLE radio owner but never grants companion background ownership before trust exists. One unambiguous candidate automatically starts [SAS verification](../protocol/pairing/SAS.md); multiple qualified candidates require selection. Dismissal or verification failure never starts a second exchange without Find nearby/Try again. After mutual confirmation and durable trust receipts, the foreground channel starts with fresh EDHOC. The default-on background setup choice is offered after that first secured connection; native companion approval is still required. Closing the Mac window retains nearby availability; lock/sleep/Quit retires pending comparison. Android background/screen lock cancels comparison even if an unrelated older companion association exists. A fresh attempt uses new keys and comparison material, never a resumed pairing channel.

The phone presents visible search progress and the shared comparison content both globally and inside Add device. Mac Confirm emits comparison approval and keeps waiting for phone approval; floating-card navigation opens normal Devices without an extra cancellable pairing sheet. An admitted pairing owns the BLE slot with advertising stopped. After retirement, the Mac resumes anonymous availability only at its existing global admission deadline, showing cooldown while waiting rather than offering a rejected first write.

The first connection uses a short-lived process-local locator captured from the completed comparison channel and pinned to that peer's full credential. It never rescans to select a different anonymous candidate. Before authentication, at most twelve 500-ms same-characteristic reads may wait for the Mac to release pairing availability or an unavailable (`14`) profile. Failed reads are not accepted as compatibility and sealed writes are never retried. Persistent GATT failures leave trust intact and require explicit Connect; native setup is offered only after fresh secured readiness.

Foreground return with one trusted Mac can make up to three fresh connection attempts, separated by two and five seconds. No new background lease is granted. Cancel, Disconnect, Pause, screen lock, foreground loss and authentication/trust failure stop this bounded work. First-pair transport failure before authentication can retry discovery twice, at least ten seconds apart; comparison dismissal and verification failure never auto-retry. Foreground discovery uses a fifteen-second low-latency scan burst before returning to low-power scanning.

## Liveness and renewal

After encrypted readiness, peers negotiate keepalive controls. Android sends PING after 60 seconds without authenticated activity; its matching PONG is due within 20 seconds. A received close retires the operation and its transport; enabled native ownership can start fresh recovery.

Automatic BLE renewal starts before the one-hour lifetime or record limit. The old transport and cryptographic session retire before fresh EDHOC/readiness. Keys and counters are never resumed. Manual BLE retains explicit reconnection.

LAN negotiates [retained-socket renewal](../protocol/lan/RENEWAL.md) separately. Its cryptographic session changes without replacing the TCP socket, feature channel or eligible work leases. [LAN connections](LAN_CONNECTIONS.md) describes its independent background timeout and automatic eligibility.

## Ownership and security

Approved transfer work can retain BLE and own bounded recovery independently of companion setup. Explicit Disconnect, disabled recovery, identity/trust invalidation and unusable transport still take priority.

Maintenance waits on monotonic deadlines and transport events rather than recurring storage polling. Quiet waits do not read KeyStore/Keychain or trust journals. Authenticated operations retain live native identity, protection and trust checks. Android elapsed realtime includes deep sleep; suspension can therefore leave a deadline expired when execution resumes.

Native teardown and callbacks are generation-scoped. Stale writes, chooser results, capacity events or presence callbacks cannot re-enable a retired operation. Uncertain or already-sealed submissions are never replayed.

## Verification boundaries

Synthetic comparison and companion-approval surfaces run only in the isolated Android UI preview on an emulator. They do not approve pairing, create native associations or substitute for phone consent. JUnit assumptions run before dispatch to the main thread; documented skips remain visible in the verifier, do not count toward its passing-test floor, and are rejected with `--strict-skips`.

Host tests exercise credential matching, one-shot locator handoff, packet limits and cancellation without hardware. The [physical pairing checklist](PROXIMITY_PAIRING_TESTING.md) covers actual Bluetooth discovery, native approval, foreground/background handoffs, Mac focus and sleep/lock behavior. Neither a skipped fixture nor instrumentation compilation constitutes a physical pass.

See [architecture](../ARCHITECTURE.md), the [session contract](../protocol/session/README.md), [Android development](../apps/android/README.md) and [Mac development](../apps/macos/README.md) for implementation and test commands.
