<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Describes the pinned ADB-assisted call-audio experiment, local build and routing boundaries. -->
# ADB-assisted call audio

This experiment uses a separate scrcpy client and Android shell process to capture
SIM-call downlink and inject Mac microphone audio through Android audio policy.
It bypasses the Mac's native HFP audio path. It is not integrated into aniCe's
Calls UI, authenticated sessions or production audio lifecycle.

The pinned source is [TomBeckett/scrcpy](https://github.com/TomBeckett/scrcpy),
branch `tapline-client-audio`, revision
`0066c8425827682c4791232f0e248d20e53b7ee2`, from
[PR #7004](https://github.com/Genymobile/scrcpy/pull/7004).
The checkout retains its Apache-2.0 license and attribution; it is not vendored or
relicensed as aniCe source. Client and Android server must both come from this
revision. A stock scrcpy server lacks its injection implementation.

## Requirements

- A Mac with Xcode command-line tools, Python 3, Java 17 and an Android SDK with
  platform 36 and build-tools 36.0.0.
- Meson/Ninja and development libraries for SDL3, FFmpeg including libavdevice,
  and libusb. The upstream macOS capture backend is AVFoundation.
- Android 13 or later, an authorized ADB connection and compatible vendor audio
  policy. The helper requires shell audio-routing privileges; ordinary microphone
  permission in an installed aniCe app does not supply them.

USB debugging is sufficient; wireless debugging is optional. Audio and control
currently use ADB tunnels. This is not a debugging-free or persistent background
calling implementation.

## Local build

Run from the repository root. This installs build tools into a local Python
environment and compiles under ignored `build/`; it does not replace installed
scrcpy. Install missing native libraries and Java/SDK prerequisites before running.

```sh
mkdir -p build
git clone --branch tapline-client-audio --single-branch \
  https://github.com/TomBeckett/scrcpy.git build/scrcpy-client-audio
git -C build/scrcpy-client-audio checkout --detach \
  0066c8425827682c4791232f0e248d20e53b7ee2
python3 -m venv build/scrcpy-build-tools
build/scrcpy-build-tools/bin/pip install meson ninja
export PATH="$PWD/build/scrcpy-build-tools/bin:$PATH"
```

Configure the client with audio injection explicitly enabled:

```sh
build/scrcpy-build-tools/bin/meson setup \
  build/scrcpy-client-audio/x build/scrcpy-client-audio \
  --buildtype=debugoptimized -Dclient_audio=true -Dcompile_server=false
build/scrcpy-build-tools/bin/ninja -C build/scrcpy-client-audio/x
```

Build the matching server with upstream's SDK-only script. Set `JAVA_HOME` to
Java 17 and `ANDROID_HOME` to the SDK directory first:

```sh
export PATH="$JAVA_HOME/bin:$PATH"
(
  cd build/scrcpy-client-audio
  server_build_dir=$(mktemp -d /tmp/anice-scrcpy-server.XXXXXX)
  BUILD_DIR="$server_build_dir" ANDROID_PLATFORM=36 ANDROID_BUILD_TOOLS=36.0.0 \
    ./server/build_without_gradle.sh &&
    mkdir -p x/server &&
    cp "$server_build_dir/scrcpy-server" x/server/scrcpy-server
)
```

The temporary server build remains under `/tmp`. Use upstream's complete Gradle
build instead if the SDK-only build becomes incompatible with local tools.

## Run during a connected call

Check `adb devices` and answer or place a test SIM call. Start streaming after the
call timer begins. Keep the phone on its normal earpiece route rather than routing
to a Bluetooth headset, Watch or Mac HFP endpoint. Select the intended Mac output
in Sound settings; a virtual recording device can otherwise receive playback.

List Mac capture devices before selecting a microphone:

```sh
./scripts/run-scrcpy-client-audio.sh --list-client-audio-sources
```

Use the actual microphone index in place of `:0`. `-d` selects USB explicitly;
for wireless ADB, replace it with `-s PHONE_IP:PORT` for the authorized connection.

```sh
./scripts/run-scrcpy-client-audio.sh -d \
  --no-video --no-control --require-audio \
  --audio-source=voice-call-downlink \
  --client-audio-source :0 \
  --time-limit=120 --verbosity=debug
```

Grant Mac microphone access if requested. The command streams live audio without
requesting a recording file. The upstream log message about recording with Opus
refers to microphone capture/encoding; it does not mean a file was requested.
Ctrl+C or the time limit requests shutdown. A process exit, a server kill warning
or a phone microphone reverting to normal does not alone establish clean policy
release; inspect the remaining process and policy state when diagnosing cleanup.

## Audio behavior and acceptance boundary

Downlink capture does not exclusively transfer the phone's output to the Mac.
Both devices can remain audible. Lowering phone volume may also affect captured
audio, so exclusive output routing needs its own test and implementation.

The phone's call-screen mute is not a reliable mute for the injected Mac stream.
Stopping the experiment ends its input; a production Calls UI needs an explicit
mute that stops or zeros the injected stream and accurately reports that state.
Do not represent the phone's mute state as proof that Mac input is muted.

Use a remote tester to distinguish routes: place the phone away from speech,
mute Mac speaker output to prevent acoustic feedback, and compare the caller's
reception with the Mac input enabled and disabled. Check whether double sound is
the caller hearing their own voice returning or hearing local speech twice.
A recorder receiving injected audio does not prove the SIM-call uplink uses it.

Native HFP endpoint exposure, ADB-assisted duplex speech and complete calling
acceptance are separate results. This experiment provides no echo cancellation,
exclusive phone-speaker routing, production mute, automatic reconnect or verified
handback guarantees. Those behaviors must be resolved before production integration;
wireless ADB and host permissions remain external lifecycle dependencies.
