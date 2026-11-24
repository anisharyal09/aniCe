# Find Device

Request a native alert on a connected trusted peer. On Android, open **Features → Mac Desk Deck → Find Mac** for the selected trusted Mac; the standalone Find Device launcher has been removed. On Mac, use **Features → Find Device** to ring the phone. LAN is preferred when both channels support the feature; otherwise BLE is used. Find Device does not establish a connection or track location.

Find Mac readiness is separate from Desk Deck readings: it needs its own advertised capability on an already-secured connection, not a telemetry subscription or fresh sample. Old Android Find Device routes and saved shortcuts redirect to Desk Deck and deduplicate at the first saved position. Refreshing Desk Deck readings does not repeat a Find request.

## Alerts

- **Android:** Rings for up to sixty seconds using the system alarm tone and current alarm volume. The notification and foreground dialog offer **Stop ringing**.
- **Mac:** Shows a native notification with **Dismiss**, following macOS notification, sound and Focus settings.

The alert identifies the authenticated paired device. Android can ring while the ringer is Silent/Vibrate, but alarm muting, DND, audio routing and audio-focus policy still apply. Neither platform changes system volume or bypasses DND.

Stop, dismissal, disconnection, expiry or audio-focus loss ends the Android alert and releases its service and wake lock. Duplicate requests do not restart a stopped alert or extend its deadline. Android reports busy while ringing; Mac replaces a submitted alert for a fresh request.

## Permissions and background use

On Android, grant incoming alert access in **Settings → Permissions → Find Phone notifications**. The row checks runtime, app and existing Find Device channel access; missing access offers a native permission request or notification settings. Granted details remain in Permissions only. The ringing receiver and service remain active independently of the visible feature panel.

Mac notification permission is granted locally through Find Device or **Settings → Permissions → Notifications**. A blocked Find Mac result points to that Mac setting; Android notification permission does not block outbound Find Mac. Incoming requests never open permission prompts or force a background activity onto the lock screen.

Android uses a `mediaPlayback` foreground service only for an admitted alert. That service grants no connection lease. Background BLE needs existing companion ownership; LAN follows its [background timeout and native work policy](../LAN_CONNECTIONS.md). A stopped app, unavailable connection or refused service start can prevent receipt.

Find Device does not wake a sleeping Mac or launch a stopped app. Mac alert expiry runs while aniCe executes; an abruptly stopped or suspended process can leave a delivered notification until native dismissal or app cleanup.

## Delivery

A successful result confirms native alert submission—not that the alert appeared or was heard. Missing permission reports blocked; audio/service startup errors report failure. No response within ten seconds leaves delivery unconfirmed. Requests are not automatically resent or moved to another transport.

Wire formats, replay bounds and native ownership are defined in [Find Device v1](../../protocol/find-device/README.md).
