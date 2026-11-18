# Background Bluetooth connections

aniCe uses one Android Bluetooth owner and one Mac availability policy. Pairing establishes trust; automatic connection uses that trust together with native ownership and the saved connection preferences.

## Set up

Enable **Connect automatically** for the trusted device on both platforms. Android's first setup uses the system companion-device chooser. The association supplies a Bluetooth locator and OS ownership, not authentication: each connection still checks the pinned device ID, fingerprint and public key.

Android companion ownership requires API 31 or newer. API 29–30 use manual foreground connections. Approved transfers have a separate connected-device foreground service; they do not require automatic Bluetooth setup.

Only one Mac owns Android's saved automatic setup. Enabling another Mac explicitly replaces that setup; opening another device's settings does not. **Reset connection setup** removes its association and observation without resetting identity or pairing.

## Android policy

- Started activities contribute independent foreground tokens. Closing one activity does not release another that remains started.
- Idle manual Bluetooth closes after the final presentation stops or the screen locks, unless eligible companion, picker or approved-transfer ownership remains.
- Only Android's OS-bound companion service supplies companion ownership. The app does not start or bind that service itself.
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

## Disconnect, disable and timed pause

| Action | Effect |
| --- | --- |
| Device Connect | Starts BLE and LAN together for the selected trusted peer; already-ready channels remain connected. |
| Cancel | Ends the current attempt and any pending Connect-to-Resume lookup without disabling the saved automatic choice; another connection event or explicit Connect can retry. |
| Disconnect | Closes the selected transport and pauses its automatic work. |
| Resume / explicit Connect | Revalidates remembered setup and resumes eligible work. |
| Switch automatic connection off | Stops observation and retries; a secured foreground or approved-work channel can remain manual. |
| Reset setup | Removes that native association; identity and peer trust remain. |
| Remove trust / reset identity | Retires both transports and invalidates the associated setup. |

A timed **Pause** closes BLE and LAN and stores a wall-clock resume deadline, or an indefinite pause. It does not keep an active transfer connected. Expiry restores only previously enabled choices; it never enables a disabled preference. App return, wake, network/presence events and clock changes reevaluate the deadline. A newer pause or disabled choice supersedes the old deadline.

Pause stops unfinished admission immediately; only already-secured channels remain briefly available for the best-effort peer notice. Duplicate native presence callbacks do not undo Cancel. Android foreground return can restart a retained companion owner's recovery without requiring another presence callback.

**Resume** acts immediately; only **Pause** opens the duration menu. The Auto connect checkbox shows currently armed work, so it is unchecked during a local pause. A current secured peer can receive a [pause notice](../protocol/connection-pause/README.md) before teardown and show **Paused on &lt;device&gt;**. This does not alter that peer's saved automatic choice; fresh secured connection, expiry or local Resume/Connect clears the notice.

## Liveness and renewal

After encrypted readiness, peers negotiate keepalive controls. Android sends PING after 60 seconds without authenticated activity; its matching PONG is due within 20 seconds. A received close retires the operation and its transport; enabled native ownership can start fresh recovery.

Automatic BLE renewal starts before the one-hour lifetime or record limit. The old transport and cryptographic session retire before fresh EDHOC/readiness. Keys and counters are never resumed. Manual BLE retains explicit reconnection.

LAN negotiates [retained-socket renewal](../protocol/lan/RENEWAL.md) separately. Its cryptographic session changes without replacing the TCP socket, feature channel or eligible work leases. [LAN connections](LAN_CONNECTIONS.md) describes its independent background timeout and automatic eligibility.

## Ownership and security

Approved transfer work can retain BLE and own bounded recovery independently of companion setup. Explicit Disconnect, disabled recovery, identity/trust invalidation and unusable transport still take priority.

Maintenance waits on monotonic deadlines and transport events rather than recurring storage polling. Quiet waits do not read KeyStore/Keychain or trust journals. Authenticated operations retain live native identity, protection and trust checks. Android elapsed realtime includes deep sleep; suspension can therefore leave a deadline expired when execution resumes.

Native teardown and callbacks are generation-scoped. Stale writes, chooser results, capacity events or presence callbacks cannot re-enable a retired operation. Uncertain or already-sealed submissions are never replayed.

See [architecture](../ARCHITECTURE.md), the [session contract](../protocol/session/README.md), [Android development](../apps/android/README.md) and [Mac development](../apps/macos/README.md) for implementation and test commands.
