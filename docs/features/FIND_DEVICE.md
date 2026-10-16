# Find Device

Mac and Android can request a native alert on a connected trusted peer. Home/Devices show Find Device for peers advertising support; the Mac companion shares the same owner. Features provides local notification permission and system-settings actions. LAN is preferred when both secured transports advertise support; otherwise BLE is used. Find Device does not establish a connection.

The receiving alert says “Your paired device <name> is looking for you.” using localized resources and the authenticated peer name. Android rings for up to sixty seconds using its system alarm tone and current alarm volume, including while the ringer is Silent/Vibrate. Mac retains ordinary notification sound/settings. Neither platform changes system volume or sound mode, bypasses DND, or tracks location. Android alarm muting, DND and audio routing still govern audibility.

Android presents a Stop ringing action in its foreground notification and an alert dialog while the app is open. Stop, dialog dismissal, native notification deletion where supported, disconnect, audio-focus loss and expiry release playback, audio focus and the service. Foreground-service notifications may not be swipeable on older Android versions; Stop remains available. Background requests do not forcibly open an activity or overlay the lock screen. Mac retains Dismiss and native notification dismissal.

Duplicate requests do not restore stopped alerts or extend their fixed deadline. A different request while an alert is active receives busy. The service accepts only an identifier already admitted by the authenticated feature owner. Native audio startup has a four-second deadline; service-start refusal, denied audio focus, zero/muted alarm volume, unavailable tone or preparation errors report failure and clean up. The service is not restarted after process death.

A successful peer result acknowledges OS alert submission; Android additionally waits for native player startup. It proves neither display nor audibility. No response after ten seconds leaves delivery unconfirmed. Missing notification permission or a blocked app/channel returns blocked. Incoming requests never open permission prompts. Features explains local ringing and provides explicit notification setup.

Android uses a `mediaPlayback` foreground service only during an admitted alert and holds playback's partial wake lock while sound runs. Background BLE reception still requires existing API 31+ companion ownership. API 29–30 remain foreground/manual. LAN follows its existing foreground/approved-work lifecycle; ringing grants no networking lease. Force-stop, process death and unavailable connections can prevent receipt. Background service starts remain subject to Android policy and existing companion eligibility.

Mac expiry runs while the application executes and is checked again when its timer resumes. Normal termination and startup remove owned notifications. An abrupt termination or suspension may leave a delivered Mac notification until native dismissal or application cleanup; macOS supplies no native local-notification expiry setting. Find Device does not wake a sleeping Mac or launch a stopped app.

Wire formats and replay/queue bounds are defined in [Find Device v1](../../protocol/find-device/README.md).

## Verification

Automated suites cover independent wire fixtures, duplicates, replay after dismissal/history eviction, permission/submission failures, peer/generation/result mismatch, disconnect races, expiry, bounded response queues and no transport replay. Android tests also cover stopping during preparation, stale popup actions and late audio completion. The native suite exercises Stop/delete PendingIntents, service admission, real audio startup and the sixty-second deadline without changing sound mode or alarm volume.

Full physical acceptance remains separate: both directions over BLE-only/LAN-only/both; foreground/background/lock and Mac sleep/wake; notification denial/channel blocking, DND and muted alarm volume; actual notification swipe gestures, audio-focus interruptions and Bluetooth audio routing. Verify long/Unicode peer names, light/dark themes, large text, keyboard/VoiceOver/TalkBack and compact Mac companion layout separately.

On the Samsung SM-A346E, native alarm playback while in Vibrate mode and audible output are verified. Stop/delete callbacks, preservation of sound mode/alarm volume, unadmitted-service rejection and startup checks pass. The strict uninterrupted sixty-second native test ended early and remains unverified; opt in on a controlled device with instrumentation argument -e findDeviceTimeout true. The bounded controller deadline is covered by JVM tests.
