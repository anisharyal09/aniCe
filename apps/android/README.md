# aniCe for Android

Kotlin, Jetpack Compose, and Material 3. Persistent identity uses Android Keystore. Pairing includes CameraX/ZXing QR scanning, native QR authentication, shared OPAQUE PIN pairing, mutual approval and local peer trust. Comprehensive manual/radio acceptance, minimum-OS coverage and independent integration security review remain pending.

Native EDHOC method 0/suite 5, directional AES-GCM records, BLE v2, readiness, negotiated encrypted keepalive and fresh-session renewal are implemented. Manual authenticated LAN connections over TCP operate independently alongside BLE with shared peer reservations. Physical API 36 verification covers authenticated BLE and LAN sockets, settings navigation, Pause/Resume and 190 seconds of quiet secured traffic after Recents removal. Locked-screen endurance, out-of-range recovery, minimum-OS coverage, and independent security review remain pending.

Automatic nearby recovery uses an OS-bound companion lease and one device setting. Release ownership remains disabled pending physical companion acceptance; Debug API 31+ exercises it. [Background BLE](../../docs/BACKGROUND_CONNECTIONS.md) records policy and hardware gates.

## Nearby discovery

Android finds nearby aniCe candidates using a service-filtered foreground scan, validates a read-only GATT payload, then disconnects. Discovery does not pair or trust devices.

## Code structure

```text
app/
  src/main/
    java/io/github/anisharyal09/anice/
      AniCeApplication.kt           Shared identity, trust and session owners
      MainActivity.kt               Activity entry point and UI host
      app/
        AppRoot.kt                  Navigation and safe insets
        HomeScreen.kt               Device list and contextual actions
      features/deviceidentity/
        DeviceIdentityScreen.kt     Details, copying, reset confirmation
        DeviceIdentityViewModel.kt  Presentation state and async requests
      features/discovery/           Nearby screen and lifecycle ViewModel
      features/pairing/             Camera scanning, PIN entry, approval UI
      features/session/             Session ViewModel, panels and connection feedback
      features/backgroundprobe/     Native companion setup/service and automatic policy
      infrastructure/identity/
        DeviceIdentity.kt           Public identity validation and encoding
        IdentityService.kt          Identity lifecycle and signing
        AndroidIdentityStorage.kt   Keystore and atomic metadata
      infrastructure/bluetooth/     Scan/GATT adapter, codec, coordinator
      infrastructure/lan/           NSD discovery, TCP transport, stream framing, resolution lane
      infrastructure/pairing/       Native PAKE JNI, pairing codec, engine, trust store
      infrastructure/session/       EDHOC, records, ordering owner, envelope, peer reservation
      ui/theme/
        Theme.kt                    Semantic Material palette
    res/                            Strings, icons, themes, backup rules
    AndroidManifest.xml             Application declarations
  src/test/                         JVM validation, pairing, session, and LAN unit tests
  src/androidTest/                  Native Keystore, session, LAN, and ownership tests
  src/debug/                        API 31+ companion ownership build gate
  src/testDebug/                    Probe presence-state unit test
  src/androidTestDebug/             Native probe checks and opt-in radio/connected-idle tests
  build.gradle.kts                  App configuration and dependencies
gradle/wrapper/                     Gradle wrapper configuration
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

Home → Pair your Mac offers QR scanning and six-digit entry. Camera access is requested only for QR scanning; Bluetooth access only after an invitation/code is entered and Start runs. A 15-second QR lookup gathers bounded candidates and checks ephemeral rendezvous IDs; manual mode selects a generic row. Both devices require explicit approval after identity verification. Trusted-device forgetting is local.

`preBuild` invokes the shared Rust build. Install the [native prerequisites](../../core/rust/pairing/README.md). For Android Studio, custom installations can be configured with `cargo.home`, `rustup.home` and `ndk.dir` in ignored `local.properties`; explicit environment variables take precedence. Packaged ABIs: arm64-v8a, armeabi-v7a and x86_64, with 16 KiB ELF alignment. No Google Play Services are required.

## Secure sessions

Mac selects an allowed Android (or Any trusted Android) and opens **Allow connections**; Android selects a trusted Mac on Home and taps **Connect**. Both show **Secured** after encrypted readiness. Android identifies each entry with eight fingerprint hex digits; Mac admits one candidate at a time and pins a selected Android’s complete credential. **Send connection check** tests the live path in either direction; Disconnect and Retry require a fresh handshake. **Connection details** adds independent manual LAN controls for the same trusted peer. [LAN ownership and verification](../../docs/LAN_CONNECTIONS.md). Feature synchronization remains deferred.

## Background connection experiment

Device settings expose **More → Connection settings → Connect automatically**. First setup reconnects through the native companion association; opening the settings screen preserves a manual connection while an activity remains visible. Only a system-bound companion service owns background operation. Debug API 31+ enables the feasibility path; Release keeps service ownership disabled pending physical acceptance. Nearby retries and fresh-session renewal are implemented; foreground-service fallback and reboot recovery remain deferred. [Policy and physical test steps](../../docs/BACKGROUND_CONNECTIONS.md).
