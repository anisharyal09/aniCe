# aniCe for Android

Kotlin, Jetpack Compose, and Material 3. Persistent identity uses Android Keystore. Pairing includes nearby numeric comparison, CameraX/ZXing QR scanning and shared OPAQUE PIN pairing, mutual approval and local peer trust. The nearby profile is provisional and requires independent security review.

## Requirements and user setup

Android 10 / API 29 or newer; compile/target API 36, JDK 21 and NDK r27d (`27.3.13750724`). Kotlin/Java target JVM 17. Background companion ownership requires API 31 or newer.

Release candidate: **0.9.0-beta.4 · build 90024** (unpublished). See [installation and updates](../../docs/GETTING_STARTED.md), [feature guides](../../README.md#features) and [architecture](../../ARCHITECTURE.md).

## Using the Android app

- **Home** shows the trusted Mac, peer battery/charging status, current transfers and playback. **Devices** owns pairing, trusted devices, transport controls and diagnostics.
- **Features** opens Control Mac, Mac Desk Deck, Send files, Clipboard, Now Playing, Messages, Find Device and Audio Sharing. **Favourites** keeps your chosen shortcuts and saved order.
- **Now Playing** brings Mac track details, album artwork, player selection and supported transport/volume controls to Home and the full player. Phone volume buttons can adjust supported Mac output; notification and lock-screen controls require eligible background ownership. Artwork travels over LAN, and audio stays on the Mac. See [playback and background limits](../../docs/features/NOW_PLAYING.md).
- **[Audio Sharing](../../docs/features/AUDIO_SHARING.md)** (Experimental) plays Mac audio on your phone or shares eligible phone audio with your Mac over the local network.
- **Share → Send to Mac** accepts supported files, literal text and links. Compatible text-selection menus also expose Send to Mac. A single HTTP(S) link offers Open in Mac when supported; other applications decide whether the selection action is visible.
- **Clipboard → Share → More options** offers setup for the Send to Mac Quick Settings tile. The tile opens a focused capture panel; it cannot read the clipboard continuously in the background. Automatic sharing and saved local history are separate, default-off preferences.
- **Settings → Notification sync** configures Notification Access, selected source apps, incoming-call controls and optional caller ID. **Settings → Do Not Disturb** enables phone-to-Mac sync after the Mac Shortcuts are configured. Desk Deck's DND button is a separate Mac-local action.

Background ownership uses the native companion association on supported API 31+ devices. First enable or association repair requires Android's setup dialog; force-stop and reboot have no automatic-recovery promise. Background LAN defaults to Never, but network/process loss, legacy-peer expiry and explicit Disconnect still apply. Capable LAN peers renew through fresh EDHOC on the same socket; eligible authenticated BLE peers supply direct IPv4 locators before bounded mDNS fallback. See [connection management](../../docs/GETTING_STARTED.md#manage-connections), [LAN behavior](../../docs/LAN_CONNECTIONS.md) and [background policy](../../docs/BACKGROUND_CONNECTIONS.md).

SMS live relay, history and replies have separate permission requirements. Phone-state access for SIM selection is optional; live SIM call controls have their own Phone permissions. Permission denial and restricted settings are explained in [Messages](../../docs/features/SMS.md#permissions) and [notification setup](../../docs/features/NOTIFICATION_MIRRORING.md#set-up).

## Code structure

```text
app/
  src/main/
    java/io/github/anisharyal09/anice/
      app/                          Assembly and navigation
      features/                     Feature models and presentation
        deskdeck/                   Mac readings, controls, approved shortcuts and peer power
        dndsync/                    Phone-to-Mac DND state relay
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
      update/                       GitHub release discovery, verification and Android installer
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

For an isolated emulator preview, run from the repository root:

```sh
./scripts/dev.sh android --preview --serial emulator-5554
```

UI preview mode verifies the target is an emulator and the APK package is `io.github.anisharyal09.anice.preview` before installing. **aniCe Preview** has its own app data and Keystore identity; it does not replace the normal aniCe package. Preview builds are Debug-only.

For an isolated transfer preview on an explicitly selected test phone, run:

```sh
./scripts/dev.sh android --transfer-preview --serial DEVICE_SERIAL
```

This builds **aniCe Transfer Preview** as `io.github.anisharyal09.anice.preview.transfer`, verifies the package ID and installs alongside the normal aniCe app. It never uninstalls or replaces production; remember that a fresh package starts with its own data and permissions.

The transfer preview contains the native manual and automatic connection controls. Pair it with the isolated Mac preview and grant its own Bluetooth permissions/system companion association; the normal app's identity, trust and connection setup are not shared. Nearby, QR/PIN and explicit Auto connect use the same single-Mac approval from the normal app, without a separate setup activity or broad device-management chooser.

Run only one branch's Transfer Preview at a time on each platform: branch copies share the preview identity, trust and preferences. New file actions can request enabled LAN after transport Disconnect; other feature demand retains the normal Disconnect gate. Connection Pause and native eligibility always apply.

For the strict aggregate gate, run from the repository root:

```sh
python3 scripts/verify-suite.py --only android
python3 scripts/verify-suite.py --only connected --serial DEVICE_SERIAL
python3 scripts/verify-suite.py fast --android --vector-python .venv/bin/python
python3 scripts/verify-suite.py device --serial DEVICE_SERIAL
```

`--only android` is the PR-time lane: it executes JVM unit tests, lint, and compiles instrumentation test sources (`assembleDebugAndroidTest`). `--only connected` runs the connected instrumentation suite against an authorized physical device or emulator. Emulator runs use the isolated UI-preview package; physical runs can replace the normal Debug installation, so choose a dedicated test phone and an explicit serial.

The suite parses JUnit reports and rejects failures, missing/truncated results and unexpected skips. Native tests can require device setup or explicit instrumentation arguments.

Comparison/approval presentation fixtures are deliberately UI-preview emulator tests; their mutations cannot approve a real pairing or native association. Typed injected presentation replaces compiler-field reflection, while post-trust one-shot candidate handoff has hardware-free JVM coverage. On physical runs, documented fixture skips are printed and do not satisfy the passing-test floor; `--strict-skips` rejects them. Use the [physical pairing checklist](../../docs/PROXIMITY_PAIRING_TESTING.md) for real discovery, consent, routing to one Mac and lifecycle acceptance.

Minimum API 29; compile/target API 36. Gradle uses JDK 21; Kotlin/Java target JVM 17. Key protection is reported from the actual device.

[Design](../../docs/design/DESIGN.md) · [Changelog](CHANGELOG.md)

## Native build

`preBuild` invokes the shared Rust build. Install the [native prerequisites](../../core/rust/pairing/README.md). Gradle pins NDK r27d (`27.3.13750724`) for the app and Rust build. For Android Studio, custom Cargo and Rustup installations can be configured with `cargo.home` and `rustup.home` in ignored `local.properties`; set `ANICE_NDK` if the NDK is outside the standard SDK path. Avoid `ndk.dir`, which Android Gradle Plugin deprecates. Keep these installations in persistent home/SDK directories rather than `/tmp`: Cargo under `~/.cargo`, Rustup under `~/.rustup`, and NDK r27d under the Android SDK’s `ndk/27.3.13750724`. Stale private paths can remain hidden by incremental native outputs until a clean build or task invalidation requires recompilation. Packaged ABIs: arm64-v8a, armeabi-v7a and x86_64, with 16 KiB ELF alignment. No Google Play Services are required.

Licensed under [GPL-3.0-or-later](../../LICENSE).
