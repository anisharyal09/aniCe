<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Documents selected Android notification mirroring to the Mac. -->
# Notification mirroring

Notification mirroring sends alerts from apps chosen on Android to the connected trusted Mac. It uses aniCe's existing authenticated BLE or LAN DATA session and adds no notification history or offline queue.

## Set up

1. On Android, open **Settings → Notifications** in aniCe.
2. Choose **Allow Notification Access** and enable aniCe in Android's system settings.
3. Return to aniCe and turn on only the apps whose notifications should appear on the Mac. The list starts with no apps selected.
4. Allow notifications for aniCe in macOS System Settings if macOS notification access is disabled.

aniCe and Android's current default SMS app are excluded from the app list. SMS continues through the existing Messages relay, avoiding a second alert for the same text.

## What is mirrored

The Mac shows the title and text that Android exposes, along with the source app name. Tapping the alert invokes the source notification's normal tap action. Available notification actions are shown by macOS; a free-form text reply becomes a native text-input action. Android notifications without usable actions remain informational. A Mac dismissal asks Android to dismiss the matching active notification. Android removals, including a dismissal in the source app, clear the Mac alert.

The selected phone app may be redacted by Android, including protected content on newer Android releases. aniCe mirrors only the fields Android provides. The app truncates unusually long text to fit the bounded secure record.

## Connection and privacy

Notifications are sent only after both connected peers advertise Notification Mirroring support. On a new secure connection, Android sends a silent snapshot of notifications that are still active. Updates and removals carry a revision so delayed records and stale actions cannot replace or invoke a newer notification. Switching between BLE and LAN does not create a second alert for the same source notification.

aniCe stores no notification content, reply text, or action token on disk and creates no history. Current source notifications and action handles stay in process memory. The Mac notification center displays the alert and may retain its rendered content according to macOS behavior. aniCe clears mirrored alerts and their in-memory action targets when the final connection to that phone ends, and programmatic cleanup does not dismiss anything on Android.

Turning off an app stops new mirroring and clears its current mirrored alerts. Revoking Android Notification Access also clears current mirrored alerts. Removing a phone's trust or quitting aniCe clears Mac-side mirrored alerts. Source app action delivery reports that Android accepted the action dispatch; aniCe does not retry an action whose outcome is uncertain.

## Limits

- Only the current default SMS app is excluded. SMS content should continue to use the Messages relay.
- Up to eight available source actions are relayed. macOS decides how many fit in a banner; additional actions may appear when the notification is expanded.
- Android can hide sensitive content, and some source-app actions cannot be invoked outside Android.
- Notifications that arrive while the phone and Mac are disconnected are not replayed unless they remain active when they reconnect.
- Android listener behavior, redaction and source-app action compatibility vary by device and app and require real-device verification.

See the [Notification Mirroring v1 contract](../../protocol/notifications/README.md) for message bounds and lifecycle details.
