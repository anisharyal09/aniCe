# Find Device

Request a native alert on a connected trusted peer from **Features → Find Device**. LAN is preferred when both channels support the feature; otherwise BLE is used. Find Device does not establish a connection or track location.

## Alerts

- **Android:** Rings for up to sixty seconds using the system alarm tone and current alarm volume. The notification and foreground dialog offer **Stop ringing**.
- **Mac:** Shows a native notification with **Dismiss**, following macOS notification, sound and Focus settings.

The alert identifies the authenticated paired device. Android can ring while the ringer is Silent/Vibrate, but alarm muting, DND, audio routing and audio-focus policy still apply. Neither platform changes system volume or bypasses DND.

Stop, dismissal, disconnection, expiry or audio-focus loss ends the Android alert and releases its service and wake lock. Duplicate requests do not restart a stopped alert or extend its deadline. Android reports busy while ringing; Mac replaces a submitted alert for a fresh request.

## Permissions and background use

Notification permission is granted locally through the feature. Incoming requests never open permission prompts or force a background activity onto the lock screen.

Android uses a `mediaPlayback` foreground service only for an admitted alert. That service grants no connection lease. Background BLE needs existing companion ownership; LAN follows its [background timeout and native work policy](../LAN_CONNECTIONS.md). A stopped app, unavailable connection or refused service start can prevent receipt.

Find Device does not wake a sleeping Mac or launch a stopped app. Mac alert expiry runs while aniCe executes; an abruptly stopped or suspended process can leave a delivered notification until native dismissal or app cleanup.

## Delivery

A successful result confirms native alert submission—not that the alert appeared or was heard. Missing permission reports blocked; audio/service startup errors report failure. No response within ten seconds leaves delivery unconfirmed. Requests are not automatically resent or moved to another transport.

Wire formats, replay bounds and native ownership are defined in [Find Device v1](../../protocol/find-device/README.md).
