# aniCe for macOS

The native Mac client for aniCe, built with SwiftUI.

The foundation opens to **No devices paired**, with a menu-bar companion for reopening the main window and quitting the app. Both surfaces follow system appearance and the shared aniCe palette. Pairing and device communication are future work.

## Run in Xcode

1. Open `aniCe.xcodeproj` and complete Xcode's license and first-launch setup if prompted.
2. Select the **aniCe** scheme and **My Mac** destination.
3. Click **Run** or press **Command-R**.

Close the window to keep aniCe available in the menu bar. Choose **Open aniCe** or click its Dock icon to reopen it. **Quit aniCe** and the standard **Command-Q** shortcut exit the app.

## Build from the terminal

From this directory, select a full Xcode for this command. If your selected developer directory points to Command Line Tools, the example falls back to Xcode's usual installation location; adjust the fallback if you installed it elsewhere.

```sh
anice_developer="$(xcode-select -p)"
if [ ! -d "$anice_developer/Platforms/MacOSX.platform" ]; then
    anice_developer='/Applications/Xcode.app/Contents/Developer'
fi
DEVELOPER_DIR="$anice_developer" xcodebuild \
    -project aniCe.xcodeproj -scheme aniCe -configuration Debug \
    -derivedDataPath /tmp/aniCe-DerivedData ONLY_ACTIVE_ARCH=NO build
open /tmp/aniCe-DerivedData/Build/Products/Debug/aniCe.app
```

The build produces an Apple Silicon/Intel app and uses local ad-hoc signing. No Apple developer account is needed. Downloaded or quarantined copies can be subject to Gatekeeper checks; local ad-hoc signing is not distribution signing or notarization.

## Development baseline

- **Platform:** macOS 14 or later, provisionally.
- **Language:** Swift 6, using Apple frameworks only.
- **Identity:** `io.github.anisharyal09.anice`, development version `0.0.0` (build `1`).
- **Sandbox:** enabled, with no network or hardware-access entitlements.

## Where to work

`aniCe/` contains the app scenes, application delegate, main window, companion, shared empty state, and semantic palette. `aniCe.xcodeproj` contains the target settings and shared run scheme.

Follow the [design guide](../../docs/design/DESIGN.md) when extending the interface. Mac changes belong in the local [changelog](CHANGELOG.md).

Licensed under [GNU GPL v3 or later](../../LICENSE) (`GPL-3.0-or-later`).
