# aniCe for Android

Kotlin, Jetpack Compose, and Material 3. Persistent identity uses Android Keystore. Pairing includes CameraX/ZXing QR scanning, native QR authentication, shared OPAQUE PIN pairing, mutual approval and local peer trust. User manual/radio acceptance, minimum-OS coverage and independent integration security review remain pending. See local [verification status](../../docs/A&V/VERIFICATION_STATUS.md).

Native EDHOC method-0/suite-5 session feasibility is implemented without a new runtime dependency. Session record, BLE and UI integration await API 29/macOS 14 runtime evidence; see local [session verification](../../docs/A&V/SESSION_VERIFICATION.md).

## Nearby discovery

Android finds nearby aniCe candidates using a service-filtered foreground scan, validates a read-only GATT payload, then disconnects. Discovery does not pair or trust devices.

## Code structure

```text
app/
  src/main/
    java/io/github/anisharyal09/anice/
      AniCeApplication.kt           Application-scoped identity service
      MainActivity.kt               Activity entry point and UI host
      app/
        AppRoot.kt                  Navigation and safe insets
      features/deviceidentity/
        DeviceIdentityScreen.kt     Details, copying, reset confirmation
        DeviceIdentityViewModel.kt  Presentation state and async requests
      infrastructure/identity/
        DeviceIdentity.kt           Public identity validation and encoding
        IdentityService.kt          Identity lifecycle and signing
        AndroidIdentityStorage.kt   Keystore and atomic metadata
      features/discovery/          Nearby screen and lifecycle ViewModel
      infrastructure/bluetooth/    Scan/GATT adapter, codec, coordinator
      infrastructure/session/     EDHOC engine, bounded CBOR, native crypto/DER adapters
      ui/theme/
        Theme.kt                    Semantic Material palette
    res/                            Strings, icons, themes, backup rules
    AndroidManifest.xml             Application declarations
  src/test/                         JVM validation and lifecycle tests
  src/androidTest/                  Native Keystore and interchange tests
  build.gradle.kts                  App configuration and dependencies
gradle/wrapper/                     Gradle wrapper configuration
build.gradle.kts                    Build plugins
settings.gradle.kts                 Modules and repositories
```

Kotlin uses the standard `src/main/java/` source root. Tests mirror the identity infrastructure package. Shared contracts and vectors live in the root [`protocol/`](../../protocol/).

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

`preBuild` invokes the shared Rust build. Install the [native prerequisites](../../core/rust/pairing/README.md); set `ANICE_NDK` if NDK r27d is outside the documented temporary location. Packaged ABIs: arm64-v8a, armeabi-v7a and x86_64, with 16 KiB ELF alignment. No Google Play Services are required.
