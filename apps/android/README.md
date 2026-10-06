# aniCe for Android

Kotlin, Jetpack Compose, and Material 3. Phase 2 provides persistent device identity through Android Keystore. Pairing and device communication are not implemented yet.

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

[Code organization](../../docs/development/code-organization.md) · [Design](../../docs/design/DESIGN.md) · [Verification](../../docs/development/identity-verification.md) · [Changelog](CHANGELOG.md)

Licensed under [GPL-3.0-or-later](../../LICENSE).
