# aniCe for Android

Kotlin, Jetpack Compose, and Material 3. Persistent identity uses Android Keystore. Pairing includes CameraX/ZXing QR scanning, native QR authentication, shared OPAQUE PIN pairing, mutual approval and local peer trust.

Native EDHOC method 0/suite 5, directional AES-GCM records, BLE v2, readiness, negotiated encrypted keepalive and fresh-session renewal are implemented. Manual authenticated LAN connections over TCP operate independently alongside BLE with shared peer reservations.

Automatic nearby recovery uses an OS-bound companion lease and one device setting. The shared API 31+ resource enables notification-free ownership in Debug and Release. [Background BLE](../../docs/BACKGROUND_CONNECTIONS.md) records lifecycle policy.

## Current release

Current build: **v0.3.0 · build 3**. Now Playing, Local File Transfer, Find Device, text Clipboard and SMS relay are included.

## Nearby discovery

Android finds nearby aniCe candidates using a service-filtered foreground scan, validates a read-only GATT payload, then disconnects. Discovery does not pair or trust devices.

## Code structure

```text
app/
  src/main/
    java/io/github/anisharyal09/anice/
      app/                          Assembly and navigation
      features/                     Feature models and presentation
        clipboard/                  Clipboard model, automatic/manual sharing and focus gating
        finddevice/                 Peer ring request actions, sound player and notification lifecycle
        nowplaying/                 Playback, codecs, artwork and native media presentation
        notifications/              Notification listener, SIM call state/control, app selection and wire relay
        phoneinput/                 Remote Mac keyboard, text reconciliation and trackpad controls
        sms/                        SMS store, event assembler, sender, controller, receiver and panel
        transfer/                   Transfer controller, destination naming, storage worker, rate metrics, UI and service
      infrastructure/
        connections/                BLE/LAN owners, nearby policy and DATA dispatch
        identity/                   Keystore storage and identity lifecycle
        bluetooth/                  Native scan/GATT and framing
        lan/                        NSD, TCP, framing and bounded ingress queue
        pairing/                    Bootstrap, trust and native PAKE interface
        session/                    EDHOC, encrypted records and readiness
      ui/                           Shared theme and components
    res/                            Native resources and companion availability gates
    AndroidManifest.xml             Installed activity/service/receiver identities
  src/test/                         JVM suites mirroring feature/infrastructure packages
  src/androidTest/                  Native storage, transport and media-session suites
  src/debug/                        Debug-specific resources and probes
  src/testDebug/                    Debug probe tests
  src/androidTestDebug/             Native probes and opt-in connected-device tests
  build.gradle.kts                  App configuration and dependencies
gradle/wrapper/                     Supported Gradle entry point
build.gradle.kts                    Build plugins
settings.gradle.kts                 Modules and repositories
```

Kotlin uses the standard `src/main/java/` source root. Tests mirror the native infrastructure and feature packages. Shared contracts and vectors live in the root [`protocol/`](../../protocol/).

## Run and check

Open `apps/android/` in Android Studio. Use its bundled JDK 21, Android SDK 36, and Build Tools 36.0.0. Run the **app** configuration on a device or emulator.

From `apps/android/` on macOS:

```sh
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew testDebugUnitTest lintDebug assembleDebug
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew connectedDebugAndroidTest
```

To build, update and launch on a phone, run from the repository root:

```sh
./scripts/dev.sh android
./scripts/dev.sh android --serial DEVICE_SERIAL
```

Enable USB debugging and approve the computer first. One authorized device is selected automatically; with multiple devices, pass a serial from `adb devices`. ADB is found on PATH or in the Android SDK. On macOS, Android Studio's bundled JDK is used when `JAVA_HOME` is unset.

APK: `apps/android/app/build/outputs/apk/debug/app-debug.apk`. Installation uses `adb install -r`, preserving data and pairing. Installing another branch replaces the phone's current build. A signing mismatch fails without uninstalling. Android permissions still require user approval.

For the strict aggregate gate, run from the repository root:

```sh
python3 scripts/verify-suite.py fast --android --vector-python .venv/bin/python
python3 scripts/verify-suite.py device --serial DEVICE_SERIAL
```

The gate parses the JUnit reports and fails on zero tests, failures, crashes, truncated reports and undocumented skips. `connectedDebugAndroidTest` alone is not an acceptance result because several native tests are environment-gated.

Minimum API 29; compile/target API 36. Gradle uses JDK 21; Kotlin/Java target JVM 17. The minimum remains provisional. Key protection is reported from the actual device, not assumed.

[Design](../../docs/design/DESIGN.md) · [Roadmap](../../docs/ROADMAP.md) · [Changelog](CHANGELOG.md)

Licensed under [GPL-3.0-or-later](../../LICENSE).

## Pairing

Home → Pair a device → Devices offers QR scanning and six-digit entry. Camera access is requested only for QR scanning; Bluetooth access only after an invitation/code is entered and Start runs. A 15-second QR lookup gathers bounded candidates and checks ephemeral rendezvous IDs; manual mode selects a generic row. Both devices require explicit approval after identity verification. Trusted-device forgetting is local.

`preBuild` invokes the shared Rust build. Install the [native prerequisites](../../core/rust/pairing/README.md). For Android Studio, custom installations can be configured with `cargo.home`, `rustup.home` and `ndk.dir` in ignored `local.properties`; explicit environment variables take precedence. Keep these installations in persistent home/SDK directories rather than `/tmp`: Cargo under `~/.cargo`, Rustup under `~/.rustup`, and NDK r27d under the Android SDK’s `ndk/27.3.13750724`. Stale private paths can remain hidden by incremental native outputs until a clean build or task invalidation requires recompilation. Packaged ABIs: arm64-v8a, armeabi-v7a and x86_64, with 16 KiB ELF alignment. No Google Play Services are required.

## Secure sessions

Successful pairing returns to Home after cleanup and active trust confirmation. Connect starts the separate authenticated Bluetooth session; approval on both devices remains required for pairing. Manage devices shows saved devices first and keeps live connections running while browsing; Pair another Mac opens new-pairing inputs.

Mac selects an allowed Android (or Any trusted Android) and taps **Connect** to open Bluetooth admission; Android taps **Connect** beside its trusted Mac on Home. The device summary shows **Connected** after encrypted readiness and names the ready Bluetooth/local-network channels. Full fingerprints appear in Connection details; Mac admits one candidate at a time and pins a selected Android’s complete credential. **Devices** exposes independent Bluetooth/LAN controls and **Security and diagnostics** contains collapsed **Diagnostics** for encrypted checks, counters and nearby discovery. A failed secondary channel does not hide a working connection. **Manage devices** opens existing pairing/trust management. [LAN ownership and verification](../../docs/LAN_CONNECTIONS.md). [Local File Transfer](../../docs/features/FILE_TRANSFER.md) provides bidirectional transfers over authenticated LAN/BLE; the Mac asks before starting a new send over Bluetooth when LAN setup is unavailable.

## Background connection experiment

Devices exposes **Connect automatically**; **Connection details → Diagnostics → Setup settings** retains association management; that page contains only setup/reset controls. Checks, counters and Debug automatic-service events share the connection diagnostics section; event logs are collapsed by default. Home/setup navigation preserves LAN. Opening discovery preserves BLE and LAN; Scan retires only BLE and releases its temporary automatic-policy suspension after cleanup. Automatic preference state updates independently of connection progress. First setup or permission/association repair uses the native companion route; valid saved setup resumes directly from Devices. Turning automatic connection off retains eligible secured foreground work as manual, while releasing background ownership and retries. Opening setup settings preserves manual work while an activity remains visible. Only a system-bound companion service owns background operation. The companion resource gate controls platform/build availability. Nearby retries and fresh-session renewal are implemented; foreground-service fallback and reboot recovery remain deferred. [Policy and lifecycle checks](../../docs/BACKGROUND_CONNECTIONS.md).

Pairing offers Connect automatically before approval and starts fresh Bluetooth work after mutual trust activation and pairing cleanup, returning to Home. Android first enable still requires the native companion association dialog; build/platform availability gates remain enforced. Manual LAN is independent.

**Settings → This device → Edit name** persists a trimmed name of 1–64 Unicode code points in the atomic identity journal. Device ID, public key and fingerprint stay unchanged; existing trust remains valid. The initial name uses the Android model, and future identity exchanges carry the saved name.

Home contains a compact device/status header, file controls and playback; Devices owns pairing, trust and diagnostics. Features opens dedicated implemented control panels and supports starred local favourites on their own page. Features and Favourites use one full-width card per row. Devices retains automatic connection preferences and direct Bluetooth/LAN controls, with This device and Add device rows inside its scrollable content. Settings contains This device and saved System/Light/Dark appearance; the app bar opens a separate About page with a Made by website credit and source/license links. Bottom navigation preserves session owners and nested routes. Empty Home opens pairing through Pair a device.

## Now Playing

Home and Features → Now Playing provide playback, player selection and supported seek/player-volume controls. Phone volume buttons control supported Mac output volume. See [Now Playing](../../docs/features/NOW_PLAYING.md) for notification behavior, background ownership, permissions and limitations.

## Local File Transfer

Home → Files and Features → Send files provide transfer controls; Android’s system Share sheet can send files to a connected Mac. Receives default to `Downloads/aniCe`; File transfer settings allow a saved custom folder and per-Mac automatic receiving. Eligible background work uses the existing connected-device service; otherwise offers wait until aniCe opens. Transfers pause on connection loss and resume over LAN or explicit Bluetooth continuation. See [Local File Transfer](../../docs/features/FILE_TRANSFER.md).

## Find Device

Features → Find Device opens peer request actions and local notification setup. See [Find Device](../../docs/features/FIND_DEVICE.md) for acknowledgement semantics, verified Samsung ringing/Stop/timeout checks and the remaining device-state matrix.

## Messages (SMS relay)

Features → Messages relays incoming SMS to the Mac, serves its reads of conversations, history and search matches, and sends Mac replies over the secured session. RECEIVE_SMS covers live relay, READ_SMS conversations/history/search, and SEND_SMS replies; the permission block names each missing capability separately, permanent denial links to App info for Android 13+ restricted settings, and the block clears on the first full grant — the panel then confirms **SMS access granted** while Settings keeps one line naming what is still needed. READ_PHONE_STATE is optional: the composer reads the phone's subscriptions once per conversation and asks for it only when that read would offer a second active subscription, and the phone default, history and search all work without it. The conversation list loads 15 threads first and continues from the returned cursor; rows keep the subscription their message arrived on, a conversation that mixes two SIMs labels each such row with a SIM chip and groups messages under day headers, and the composer's keyboard send key shares the Send button's path so the chosen subscription always applies. SMS permissions remain Play-restricted in this sideloaded build. See [Messages](../../docs/features/SMS.md) for provider fallbacks, paging limits and permission handling.

## Notification Mirroring

Settings → Notification sync provides Notification Access setup, the default-on **Mirror incoming calls** checkbox and a separate **Select apps** screen with search. **Allow phone access** requests the additional permissions for live SIM call relay: Android detects ringing on active SIM subscriptions and accepts revision-bound Mac Answer/Decline requests through Telecom, keeping audio on the phone. Calling-app actions use their exposed notification controls. Alerts use authenticated BLE or LAN; source icons travel over LAN only. See [Notification mirroring](../../docs/features/NOTIFICATION_MIRRORING.md) and the [wire contract](../../protocol/notifications/README.md).

**Allow caller ID** in Notification sync requests incoming-number and Contacts access to show a saved name or phone number. Lookup stays on the phone and creates no call history. See the feature guide for Android permission restrictions.

## Clipboard

Features → Clipboard provides manual text sharing and off-by-default per-device automatic sharing over LAN or BLE. Receiving writes directly to the native clipboard. Android automatic reads require aniCe input focus; Mac observation respects pasteboard access settings. [Clipboard behavior](../../docs/features/CLIPBOARD.md) describes permissions, focus rules and the background-overwrite limitation.

## Control Mac

Features → Control Mac uses the phone's normal keyboard and trackpad to control a connected Mac over the existing authenticated Bluetooth session. Tap **Start control**, then type, move, click, drag or scroll. macOS Event Posting permission is required; a denied start shows recovery guidance on the phone. See [Phone-to-Mac input](../../docs/features/PHONE_TO_MAC.md) for typing modes, limits and interruption behavior.
