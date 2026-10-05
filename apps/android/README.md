# aniCe for Android

The Android client for aniCe, built with Kotlin, Jetpack Compose, and Material 3.

The first runnable version opens to **No devices paired**. It follows the system's light or dark appearance using aniCe's warm-neutral and slate-blue palette. Pairing and communication between devices are next-stage work.

## Run in Android Studio

1. Open `apps/android/` as the project and let Gradle sync finish.
2. Select Android Studio's bundled **JDK 21** as the Gradle JDK. Install **Android SDK 36** and **Build Tools 36.0.0** through SDK Manager.
3. Choose a connected Android device or create an emulator in Device Manager. For the foundation's reference device, use **Pixel 9**, **API 36 Google APIs ARM64**, and the name `aniCe_API_36`.
4. Select the **app** run configuration and your device, then click **Run**.

Android Studio stores your SDK location in `local.properties`, which stays out of Git.

## Build from the terminal

From the repository root, using Android Studio's bundled JDK on macOS:

```sh
cd apps/android
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew assembleDebug lintDebug
```

The debug APK is written to `app/build/outputs/apk/debug/app-debug.apk`. To install and open it with a running emulator or connected device, use `adb` from the Android SDK's `platform-tools`:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n io.github.anisharyal09.anice/.MainActivity
```

## Development baseline

- **Android:** minimum API 29 (Android 10), compile and target API 36 (Android 16). The minimum is provisional.
- **Build:** Gradle runs on JDK 21; Java and Kotlin target JVM 17. Versions are pinned in the Gradle files.
- **Identity:** `io.github.anisharyal09.anice`, development version `0.0.0-dev` (code `1`). No release has been published.

## Where to work

There is one application module, `app`.

| Location | Purpose |
| --- | --- |
| `app/src/main/java/io/github/anisharyal09/anice/MainActivity.kt` | App entry point and starting screen. |
| `app/src/main/java/io/github/anisharyal09/anice/ui/theme/Theme.kt` | Light and dark Material color schemes. |
| `app/src/main/res/` | Text, icons, and Android resources. |
| `app/src/main/AndroidManifest.xml` | Application and activity declarations. |
| `app/build.gradle.kts` | SDK settings and application dependencies. |

Follow the shared [design guide](../../docs/design/DESIGN.md) when extending the interface. Android changes belong in the local [changelog](CHANGELOG.md).

Licensed under [GNU GPL v3 or later](../../LICENSE) (`GPL-3.0-or-later`).
