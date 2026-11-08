<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Documents selected Android notification mirroring to the Mac. -->
# Notification mirroring and call relay

Notification mirroring sends alerts from apps chosen on Android to the connected trusted Mac. It uses aniCe's existing authenticated BLE or LAN DATA session and adds no notification history or offline queue.

## Set up

1. On Android, open **Settings → Notification sync** in aniCe.
2. Choose **Enable notification access** and enable aniCe in Android's system notification-access settings. The button disappears when you return after granting access.
3. Return to aniCe and review **Mirror incoming calls**. It defaults to on; an existing explicit off choice is preserved. To detect live SIM calls and enable phone Answer/Decline, tap **Allow phone access** and grant Android's Phone state and Answer phone calls permissions. Notification Access is also required.
4. In the same **Notification sync** section, open **Select apps** and turn on only the apps whose notifications should appear on the Mac. Search by app name or package name. App icons help identify entries; the list starts with no apps selected and keeps selected apps at the top.
5. Allow notifications for aniCe in macOS System Settings. Set **Alert style** to **Banners** if alerts should pop over other work; check Focus and Scheduled Summary if alerts only appear in Notification Center. Reconnect snapshots are intentionally quiet.

Android's system notification-access page grants aniCe permission to read posted notifications and lists aniCe with other listener apps. The in-app **Select apps** list is a separate source filter. aniCe and Android's current default SMS app are excluded from that list. SMS continues through the existing Messages relay, avoiding a second alert for the same text.

## What is mirrored

The Mac shows the title and text that Android exposes, along with the source app name. Tapping the alert invokes the source notification's normal tap action. Available notification actions are shown by macOS; a free-form text reply becomes a native text-input action. Android notifications without usable actions remain informational. A Mac dismissal asks Android to dismiss the matching active notification. Android removals, including a dismissal in the source app, clear the Mac alert.

When Android can provide the app launcher icon, aniCe attaches it as an image alongside the native Mac alert. To keep Bluetooth traffic small, source icons are sent only over LAN. A notification received first over Bluetooth is enriched quietly if a LAN connection becomes available; a BLE-only connection uses aniCe's own sender icon. macOS keeps aniCe's app icon in the sender position; the source icon is notification content and does not replace it.

When **Mirror incoming calls** is enabled, standard incoming CallStyle notifications and supported ongoing system call notifications are mirrored even when the source is a system component or the app is not selected in the app list. For SIM calls, aniCe also listens for Android's telephony ringing state and creates a live alert when the dialer does not publish an actionable notification. Source CallStyle actions use their Android PendingIntents; synthetic SIM call actions use Telecom to answer or reject only while the call is still ringing. Both actions leave call audio on the phone. The fallback alert uses a generic caller label because Android does not reliably expose caller identity to companion apps. Dismissing that alert hides its Mac copy without rejecting the call. Other notifications from those apps still require app selection.

Source-app content may be redacted by Android, including protected content on newer Android releases. aniCe mirrors only the fields Android provides. The app truncates unusually long text to fit the bounded secure record.

## Connection and privacy

Notifications are sent only after both connected peers advertise Notification Mirroring support. On a new secure connection, Android sends a silent snapshot of notifications that are still active. Live updates use active notification delivery; whether macOS shows a banner still follows the user's aniCe alert style, Focus and Scheduled Summary settings. Updates and removals carry a revision so delayed records and stale actions cannot replace or invoke a newer notification. Switching between BLE and LAN does not create a second alert for the same source notification.

aniCe stores no notification content, reply text, or action token on disk and creates no history. Current source notifications and action handles stay in process memory. The Mac notification center displays the alert and may retain its rendered content according to macOS behavior. aniCe clears mirrored alerts and their in-memory action targets when the final connection to that phone ends, and programmatic cleanup does not dismiss anything on Android.

Turning off an app stops new mirroring and clears its current mirrored alerts. Revoking Android Notification Access also clears current mirrored alerts. Removing a phone's trust or quitting aniCe clears Mac-side mirrored alerts. Each distinct Mac action can be submitted once per notification revision; duplicate callbacks for that action are ignored. Android opts in to background activity launches for these authenticated user actions on supported OS versions, but the source app and Android still control execution. Source app action delivery reports that Android accepted the action dispatch; aniCe does not retry an action whose outcome is uncertain.

Device testing confirmed live SIM call alerts with Answer/Decline and the user reported call control working after granting phone access. WhatsApp notification mirroring and source icons were also reported working. These checks do not establish compatibility for every device, calling app or action.

## Limits

- Only the current default SMS app is excluded. SMS content should continue to use the Messages relay.
- Up to eight available source actions are relayed. macOS decides how many fit in a banner; additional actions may appear when the notification is expanded.
- Live SIM call detection and remote Answer/Decline require both **READ_PHONE_STATE** and **ANSWER_PHONE_CALLS**; aniCe asks for them only through **Allow phone access** in Notification sync settings. If either permission is denied, the listener-based app notifications can still work but SIM fallback calls will not appear.
- Android can hide sensitive content, and some source-app actions cannot be invoked outside Android.
- Notifications that arrive while the phone and Mac are disconnected are not replayed unless they remain active when they reconnect.
- Android listener behavior, redaction and source-app action compatibility vary by device and app and require real-device verification. Discord call joining and SIM missed-call Call back remain dependent on the source app and have not been confirmed across devices.

See the [Notification Mirroring v1 contract](../../protocol/notifications/README.md) for message bounds and lifecycle details.
