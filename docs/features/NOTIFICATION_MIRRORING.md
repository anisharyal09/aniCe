<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Documents selected Android notification mirroring to the Mac. -->
# Notification mirroring and call relay

Notification mirroring sends alerts from apps chosen on Android to the connected trusted Mac. It uses aniCe's existing authenticated BLE or LAN DATA session and adds no notification history or offline queue.

## Set up

1. On Android, open **Settings → Notification sync** in aniCe.
2. Choose **Enable notification access** and enable aniCe in Android's system notification-access settings. Once the listener connects, the setup button disappears. If Android grants access but hasn’t connected the listener, aniCe shows a recovery button instead.
3. Return to aniCe and review **Mirror incoming calls**. It defaults to on and includes supported incoming calls from apps outside **Select apps**. For SIM-call controls, choose **Allow phone access** and grant Phone state and Answer phone calls. Apps like WhatsApp handle their own notification actions.
4. Open **Select apps** for ordinary app alerts. Search by app name or package name. The list starts with no apps selected and keeps selected apps at the top. Turning off **Mirror incoming calls** leaves alerts from selected apps eligible.
5. Allow notifications for aniCe in macOS System Settings. Set **Alert style** to **Banners** if alerts should pop over other work; check Focus and Scheduled Summary if alerts only appear in Notification Center. Reconnect snapshots and later revisions of an existing alert are intentionally quiet; only a notification's first live revision can sound or show a new banner.

Android's system notification-access page grants aniCe permission to read posted notifications and lists aniCe with other listener apps. The in-app **Select apps** list is a separate source filter. aniCe and Android's current default SMS app are excluded from that list. SMS continues through the existing Messages relay, avoiding a second alert for the same text.

Settings → Permissions lists Notification Access, SIM selection (Phone state access), Answer phone calls, Call log and Contacts independently, with their current grants and purposes. All shows only missing-access actions; Notification sync removes permission prompts after their grants succeed. Runtime requests contain only missing permissions. Granting access does not change the selected-app filter or enable mirroring preferences.

## What is mirrored

The Mac shows the title and text that Android exposes, along with the source app and authenticated phone names. Native grouping stays separate for each phone/source-app pair. Tapping the alert invokes the source notification's normal tap action. Available notification actions are shown by macOS; a free-form text reply becomes a native text-input action. Android notifications without usable actions remain informational. A Mac dismissal asks Android to dismiss the matching active notification. Android removals, including a dismissal in the source app, clear the Mac alert.

Routine ongoing notifications are not mirrored. Timers, foreground-service status, playback controls and similar continuously updating alerts would otherwise replace the Mac alert every second. An incoming call is the only ongoing exception. If a mirrored notification later becomes a routine ongoing update, its existing Mac copy is cleared.

When Android can provide the app launcher icon, aniCe attaches it as an image alongside the native Mac alert. To keep Bluetooth traffic small, source icons are sent only over LAN. A notification received first over Bluetooth is enriched quietly if a LAN connection becomes available; a BLE-only connection uses aniCe's own sender icon. macOS keeps aniCe's app icon in the sender position; the source icon is notification content and does not replace it.

With **Mirror incoming calls** on, aniCe includes supported incoming-call alerts from unselected apps and system components. For app calls such as WhatsApp, aniCe forwards the actions Android exposes on the source alert. For SIM calls, aniCe can create its own alert from the phone’s ringing state, even when the dialer doesn’t expose actions. While that alert is active, aniCe folds a parallel dialer alert into it and uses Android Telecom for Answer and Decline. Dismissing aniCe’s SIM alert hides the Mac copy without rejecting the call. Audio stays on the phone in either case.

**Allow caller ID** in Notification sync requests `READ_CALL_LOG` for the incoming number and `READ_CONTACTS` for local name lookup. The protected phone-state broadcast enriches the existing alert without changing ringing detection or Answer/Decline. aniCe does not query call history or save caller details; it clears caller identity when ringing ends. Without a saved contact, it shows the number; if Android withholds the number, it uses exposed notification text or a generic alert.

Source-app content may be redacted by Android, including protected content on newer Android releases. aniCe mirrors only the fields Android provides. The app truncates unusually long text to fit the bounded secure record.

## Connection and privacy

Notifications are sent only after both connected peers advertise Notification Mirroring support. On a new secure connection, Android sends a silent snapshot of notifications that are still active. Only the first live revision of a source notification uses an active alert; later revisions replace the existing Mac notification in place without sound or another banner, including while aniCe is foreground. Whether that first alert shows a banner still follows the user's aniCe alert style, Focus and Scheduled Summary settings. Updates and removals carry a revision so delayed records and stale actions cannot replace or invoke a newer notification. Switching between BLE and LAN does not create a second alert for the same source notification, and same-revision source-icon enrichment does not re-enable an action already used.

When channel capacity refuses a submission, Android waits for the next capacity event and resynchronizes current active state on that same channel generation. Superseded and removed alerts are not replayed. An incomplete snapshot never emits a successful end marker. Capability and at most 32 cached action results have bounded pending retry state; no polling or disconnected-content queue is added.

aniCe stores no notification content, reply text, or action token on disk and creates no history. Current source notifications and action handles stay in process memory. The Mac notification center displays the alert and may retain its rendered content according to macOS behavior. aniCe clears mirrored alerts and their in-memory action targets when the final connection to that phone ends, and programmatic cleanup does not dismiss anything on Android.

Turning off an app clears its ordinary mirrored alerts; supported incoming calls can remain eligible while **Mirror incoming calls** is on. Revoking Android Notification Access clears mirrored alerts. Removing a phone's trust or quitting aniCe clears Mac-side mirrored alerts. Each distinct Mac action can be submitted once per notification revision; duplicate callbacks for that action are ignored. Android opts in to background launches for these authenticated user actions on supported OS versions, but Android and the source app still control execution.

## If an alert or action doesn’t work

- **No alerts reach Mac:** Check the connection in Devices. On the phone, open **Settings → Notification sync**. If access is granted but aniCe isn’t receiving alerts, use **Open Notification Access** to turn the grant off and back on. For a missing ordinary alert, also check **Select apps**. If the alert appears in Mac Notification Center without a banner, check the Mac’s alert style and Focus.
- **Answer or Decline didn’t work:** **Request sent to phone** confirms only that Android reported submitting the action. If the call is still ringing, use the phone. For third-party apps such as WhatsApp, call permissions and adding the app to **Select apps** do not make its action work. Call audio stays on the phone.
- **Notification out of date, unavailable, or unconfirmed:** Use the current notification on the phone. The Mac shows a silent local notice when it can’t use a mirrored action or receives no result in time. It doesn’t retry the action automatically. Successful routine app actions stay quiet; recognizable Answer or Decline buttons report dispatch.

## Limits

- Only the current default SMS app is excluded. SMS content should continue to use the Messages relay.
- Routine ongoing notifications are skipped; only an incoming call is mirrored while ongoing.
- Up to eight available source actions are relayed. macOS decides how many fit in a banner; additional actions may appear when the notification is expanded.
- Live SIM call detection and remote Answer/Decline require both **READ_PHONE_STATE** and **ANSWER_PHONE_CALLS**; aniCe asks through **Allow phone access** in Permissions or Notification sync settings. If either permission is denied, the listener-based app notifications can still work but SIM fallback calls will not appear.
- `READ_CALL_LOG` is restricted: the installer may need to allowlist it, and Google Play distribution requires an eligible use case. Denying caller-ID access does not disable ringing alerts or call controls.
- Android can hide sensitive content, and some source-app actions cannot be invoked outside Android.
- Notifications that arrive while the phone and Mac are disconnected are not replayed unless they remain active when they reconnect.
- Listener content and action availability depend on Android and the source app. Source-specific call actions are available only when that notification exposes them.

See the [Notification Mirroring v1 contract](../../protocol/notifications/README.md) for message bounds and lifecycle details.
