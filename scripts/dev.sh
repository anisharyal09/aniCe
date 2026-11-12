#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "dev: $*" >&2; exit 1; }
branch="$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"
if [[ -z "$branch" ]]; then
    branch="detached-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi
# Xcode interprets percent escapes in some cache paths; keep these names percent-free.
branch_slug="$(printf '%s' "$branch" | sed 's/_/_5F/g; s/%/_25/g; s|/|_2F|g')"
checkout="${ROOT##*/}"
usage() {
    echo "Usage: $0 mac | android [--serial DEVICE_SERIAL]"
    echo "Mac requires ANICE_DEVELOPMENT_TEAM; optional ANICE_CODE_SIGN_IDENTITY."
    echo "Local settings may be saved in scripts/dev.local.sh."
}
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    mac|android) platform="$1"; shift ;;
    *) usage >&2; exit 1 ;;
esac
serial=""
if [[ "$platform" == android && $# == 2 && "$1" == --serial && -n "$2" ]]; then
    serial="$2"; shift 2
fi
[[ $# == 0 ]] || { usage >&2; exit 1; }

# This ignored file is shell code owned by the developer, never shared signing settings.
if [[ -f "$ROOT/scripts/dev.local.sh" ]]; then
    source "$ROOT/scripts/dev.local.sh"
fi

if [[ "$platform" == mac ]]; then
    [[ "$(uname -s)" == Darwin ]] || fail "Mac builds require macOS."
    [[ "$(uname -m)" == arm64 ]] || fail "Mac builds require Apple Silicon and a native arm64 shell."
    [[ -n "${ANICE_DEVELOPMENT_TEAM:-}" ]] || fail "Set ANICE_DEVELOPMENT_TEAM to your Apple development team ID (see apps/macos/README.md)."
    identity="${ANICE_CODE_SIGN_IDENTITY:-Apple Development}"
    [[ "$identity" != - ]] || fail "Use an Apple Development certificate, not ad-hoc signing, for permission testing."
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
    command -v xcodebuild >/dev/null || fail "Install Xcode."
    # Branch copies share one bundle identity and persisted device state.
    osascript <<'APPLESCRIPT'
tell application "System Events"
    if exists (first application process whose bundle identifier is "io.github.anisharyal09.anice") then
        set aniCeProcess to first application process whose bundle identifier is "io.github.anisharyal09.anice"
        set frontmost of aniCeProcess to true
        delay 0.2
        keystroke "q" using {command down}
    end if
end tell
APPLESCRIPT
    for attempt in {1..25}; do
        pgrep -x aniCe >/dev/null || break
        sleep 0.2
    done
    if pgrep -x aniCe >/dev/null; then
        fail "Quit the remaining aniCe copies with Command-Q, then retry. Branch builds share permissions and device state."
    fi
    python3 "$ROOT/scripts/build-pairing-native.py" macos
    # Use a unique percent-free cache path for each branch.
    derived="$ROOT/build/dev-mac/$checkout-$branch_slug"
    echo "Building Mac branch '$branch' from $ROOT"
    xcodebuild -project "$ROOT/apps/macos/aniCe.xcodeproj" -scheme aniCe \
        -configuration Debug -destination 'platform=macOS' -derivedDataPath "$derived" \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
        "CODE_SIGN_IDENTITY=$identity" "DEVELOPMENT_TEAM=$ANICE_DEVELOPMENT_TEAM" \
        "INFOPLIST_KEY_CFBundleDisplayName=aniCe ($branch)" build
    app="$derived/Build/Products/Debug/aniCe.app"
    codesign --verify --deep --strict "$app"
    signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
    [[ "$signature" == *"Authority=Apple Development:"* ]] || fail "Built app is not Apple Development signed."
    grep -Fxq "TeamIdentifier=$ANICE_DEVELOPMENT_TEAM" <<< "$signature" || fail "Built app has an unexpected signing team."
    open -n "$app"
    echo "Launched: $app"
else
    echo "Building Android branch '$branch' from $ROOT"
    sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
    adb="$(command -v adb || true)"
    if [[ -z "$sdk_root" && "$adb" == */platform-tools/adb ]]; then
        sdk_root="${adb%/platform-tools/adb}"
    fi
    if [[ -z "$adb" ]]; then
        for candidate in "$sdk_root" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
            if [[ -n "$candidate" && -x "$candidate/platform-tools/adb" ]]; then
                sdk_root="$candidate"
                adb="$sdk_root/platform-tools/adb"; break
            fi
        done
    fi
    [[ -n "$adb" ]] || fail "adb not found; set ANDROID_HOME or add platform-tools to PATH."
    if [[ -z "$sdk_root" ]]; then
        for candidate in "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
            if [[ -d "$candidate/platform-tools" ]]; then sdk_root="$candidate"; break; fi
        done
    fi
    [[ -n "$sdk_root" ]] || fail "Android SDK not found; set ANDROID_HOME or ANDROID_SDK_ROOT."
    export ANDROID_HOME="$sdk_root" ANDROID_SDK_ROOT="$sdk_root"
    devices="$("$adb" devices)"
    authorized=()
    while read -r candidate state rest; do
        [[ "$state" != device ]] || authorized+=("$candidate")
    done <<< "$devices"
    [[ ${#authorized[@]} -gt 0 ]] || fail "No authorized device. Connect your phone, enable USB debugging and approve this computer."
    if [[ -n "$serial" ]]; then
        found=false
        for candidate in "${authorized[@]}"; do
            [[ "$candidate" != "$serial" ]] || found=true
        done
        [[ "$found" == true ]] || fail "Selected device is not connected and authorized. Check adb devices and approve USB debugging."
    else
        [[ ${#authorized[@]} == 1 ]] || fail "Multiple devices connected; pass --serial DEVICE_SERIAL (see adb devices)."
        serial="${authorized[0]}"
    fi
    if [[ -z "${JAVA_HOME:-}" && -d '/Applications/Android Studio.app/Contents/jbr/Contents/Home' ]]; then
        export JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home'
    fi
    (cd "$ROOT/apps/android" && ./gradlew :app:assembleDebug)
    echo "Updating aniCe on $serial"
    "$adb" -s "$serial" install -r "$ROOT/apps/android/app/build/outputs/apk/debug/app-debug.apk"
    "$adb" -s "$serial" shell am start -W -n io.github.anisharyal09.anice/.MainActivity
fi
