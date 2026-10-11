# aniCe for Android

Kotlin, Jetpack Compose, and Material 3. Persistent identity uses Android Keystore. Pairing includes CameraX/ZXing QR scanning, native QR authentication, shared OPAQUE PIN pairing, mutual approval and local peer trust. Comprehensive manual/radio acceptance, minimum-OS coverage and independent integration security review remain pending.

Native EDHOC method 0/suite 5, directional AES-GCM records, BLE v2, readiness, negotiated encrypted keepalive and fresh-session renewal are implemented. Manual authenticated LAN connections over TCP operate independently alongside BLE with shared peer reservations. Physical API 36 verification covers authenticated BLE and LAN sockets, settings navigation, Pause/Resume and 190 seconds of quiet secured traffic after Recents removal. Locked-screen endurance, out-of-range recovery, minimum-OS coverage, and independent security review remain pending.

Automatic nearby recovery uses an OS-bound companion lease and one device setting. The shared API 31+ resource enables notification-free ownership in Debug and Release. Physical endurance and minimum-OS acceptance remain pending. [Background BLE](../../docs/BACKGROUND_CONNECTIONS.md) records policy and hardware gates.

## Nearby discovery

Android finds nearby aniCe candidates using a service-filtered foreground scan, validates a read-only GATT payload, then disconnects. Discovery does not pair or trust devices.

## Code structure

```text
app/
  src/main/
    java/io/github/anisharyal09/anice/
      app/                          Assembly and navigation
      features/                     Feature models and presentation
        nowplaying/                 Playback, codecs, artwork and native media presentation
      infrastructure/
        connections/                BLE/LAN owners, nearby policy and DATA dispatch
        identity/                   Keystore storage and identity lifecycle
        bluetooth/                  Native scan/GATT and framing
        lan/                        NSD, TCP and framing
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

Debug APK: `app/build/outputs/apk/debug/app-debug.apk`.

Minimum API 29; compile/target API 36. Gradle uses JDK 21; Kotlin/Java target JVM 17. The minimum remains provisional. Key protection is reported from the actual device, not assumed.

[Design](../../docs/design/DESIGN.md) · [Roadmap](../../docs/ROADMAP.md) · [Changelog](CHANGELOG.md)

Licensed under [GPL-3.0-or-later](../../LICENSE).

## Pairing

Home → Pair a device → Devices offers QR scanning and six-digit entry. Camera access is requested only for QR scanning; Bluetooth access only after an invitation/code is entered and Start runs. A 15-second QR lookup gathers bounded candidates and checks ephemeral rendezvous IDs; manual mode selects a generic row. Both devices require explicit approval after identity verification. Trusted-device forgetting is local.

`preBuild` invokes the shared Rust build. Install the [native prerequisites](../../core/rust/pairing/README.md). For Android Studio, custom installations can be configured with `cargo.home`, `rustup.home` and `ndk.dir` in ignored `local.properties`; explicit environment variables take precedence. Packaged ABIs: arm64-v8a, armeabi-v7a and x86_64, with 16 KiB ELF alignment. No Google Play Services are required.

## Secure sessions

Successful pairing returns to Home after cleanup and active trust confirmation. Connect starts the separate authenticated Bluetooth session; approval on both devices remains required for pairing. Manage devices shows saved devices first and keeps live connections running while browsing; Pair another Mac opens new-pairing inputs.

Mac selects an allowed Android (or Any trusted Android) and taps **Connect** to open Bluetooth admission; Android taps **Connect** beside its trusted Mac on Home or Devices. The device summary shows **Connected** after encrypted readiness and names the ready Bluetooth/local-network channels. Android identifies each entry with eight fingerprint hex digits; Mac admits one candidate at a time and pins a selected Android’s complete credential. **Connection details** contains independent transport controls and collapsed **Diagnostics** for encrypted checks, counters and nearby discovery. A failed secondary channel does not hide a working connection. **Manage devices** opens existing pairing/trust management. [LAN ownership and verification](../../docs/LAN_CONNECTIONS.md). Feature synchronization remains deferred.

## Background connection experiment

Devices exposes **Connect automatically**; **Connection details → Diagnostics → Setup settings** retains association management; that page contains only setup/reset controls. Checks, counters and Debug automatic-service events share the Devices diagnostics section; event logs are collapsed by default. Home/setup navigation preserves LAN. Opening discovery preserves BLE and LAN; Scan retires only BLE and releases its temporary automatic-policy suspension after cleanup. Automatic preference state updates independently of connection progress. First setup or permission/association repair uses the native companion route; valid saved setup resumes directly in Devices. Turning automatic connection off retains eligible secured foreground work as manual, while releasing background ownership and retries. Opening setup settings preserves manual work while an activity remains visible. Only a system-bound companion service owns background operation. The companion resource gate controls platform/build availability; physical compatibility acceptance remains separate. Nearby retries and fresh-session renewal are implemented; foreground-service fallback and reboot recovery remain deferred. [Policy and physical test steps](../../docs/BACKGROUND_CONNECTIONS.md).

Pairing offers Connect automatically before approval and starts fresh Bluetooth work after mutual trust activation and pairing cleanup, returning to Home. Android first enable still requires the native companion association dialog; build/platform availability gates remain enforced. Manual LAN is independent.

**Settings → This device → Edit name** persists a trimmed name of 1–64 Unicode code points in the atomic identity journal. Device ID, public key and fingerprint stay unchanged; existing trust remains valid. The initial name uses the Android model, and future identity exchanges carry the saved name.

Home shows compact device summaries and playback; Devices contains connections, pairing and diagnostics; Features contains implemented Mac controls; Settings contains a compact This device entry and saved System/Light/Dark appearance. Bottom navigation preserves session owners and nested routes. Empty Home opens pairing through Pair a device.

## Now Playing

Home and Features → Mac controls provide playback, player selection and supported seek/player-volume controls. Phone volume buttons control supported Mac output volume. See [Now Playing](../../docs/features/NOW_PLAYING.md) for notification behavior, background ownership, permissions and limitations.
