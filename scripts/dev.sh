#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds branch or isolated preview apps and guards their native installation targets.
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
    echo "Usage: $0 mac [--preview|--transfer-preview] | android [--preview|--transfer-preview] [--serial DEVICE_SERIAL]"
    echo "Mac requires ANICE_DEVELOPMENT_TEAM; optional ANICE_CODE_SIGN_IDENTITY."
    echo "Preview modes use isolated app/data identities; Android UI previews require an explicit emulator serial."
    echo "Local settings may be saved in scripts/dev.local.sh."
}
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    mac|android) platform="$1"; shift ;;
    *) usage >&2; exit 1 ;;
esac
serial=""
preview=false
transfer_preview=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --preview)
            [[ "$preview" == false && "$transfer_preview" == false ]] || { usage >&2; exit 1; }
            preview=true; shift ;;
        --transfer-preview)
            [[ "$preview" == false && "$transfer_preview" == false ]] || { usage >&2; exit 1; }
            transfer_preview=true; shift ;;
        --serial)
            [[ "$platform" == android && -z "$serial" && -n "${2:-}" && "${2:-}" != --* ]] || { usage >&2; exit 1; }
            serial="$2"; shift 2 ;;
        *) usage >&2; exit 1 ;;
    esac
done
if [[ "$platform" == android && "$preview" == true && ! "$serial" =~ ^emulator-[0-9]+$ ]]; then
    fail "UI preview mode requires --serial emulator-PORT; it never installs on a physical phone."
fi

# This ignored file is shell code owned by the developer, never shared signing settings.
if [[ "$platform" == mac && ( "$preview" == false || "$transfer_preview" == true ) && -f "$ROOT/scripts/dev.local.sh" ]]; then
    source "$ROOT/scripts/dev.local.sh"
fi

if [[ "$platform" == mac ]]; then
    [[ "$(uname -s)" == Darwin ]] || fail "Mac builds require macOS."
    [[ "$(uname -m)" == arm64 ]] || fail "Mac builds require Apple Silicon and a native arm64 shell."
    if [[ "$preview" == true ]]; then
        identity="-"
    else
        [[ -n "${ANICE_DEVELOPMENT_TEAM:-}" ]] || fail "Set ANICE_DEVELOPMENT_TEAM to your Apple development team ID (see apps/macos/README.md)."
        identity="${ANICE_CODE_SIGN_IDENTITY:-Apple Development}"
        [[ "$identity" != - ]] || fail "Use an Apple Development certificate, not ad-hoc signing, for permission testing."
    fi
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
    command -v xcodebuild >/dev/null || fail "Install Xcode."
    if [[ "$preview" == false && "$transfer_preview" == false ]]; then
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
    fi
    python3 "$ROOT/scripts/build-pairing-native.py" macos
    # Use a unique percent-free cache path for each branch.
    derived="$ROOT/build/dev-mac/$checkout-$branch_slug"
    product="aniCe"
    build_options=("CODE_SIGN_IDENTITY=$identity")
    if [[ "$preview" == true ]]; then
        derived="$ROOT/build/preview-mac/$checkout-$branch_slug"
        product="aniCePreview"
        build_options+=("DEVELOPMENT_TEAM=" "PRODUCT_NAME=$product" "PRODUCT_MODULE_NAME=aniCe"
            "PRODUCT_BUNDLE_IDENTIFIER=io.github.anisharyal09.anice.preview"
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG ANICE_DEVELOPMENT_KEYCHAIN ANICE_PREVIEW'
            "INFOPLIST_KEY_CFBundleDisplayName=aniCe Preview")
    elif [[ "$transfer_preview" == true ]]; then
        derived="$ROOT/build/transfer-preview-mac/$checkout-$branch_slug"
        product="aniCeTransferPreview"
        build_options+=("DEVELOPMENT_TEAM=$ANICE_DEVELOPMENT_TEAM" "PRODUCT_NAME=$product" "PRODUCT_MODULE_NAME=aniCe"
            "PRODUCT_BUNDLE_IDENTIFIER=io.github.anisharyal09.anice.preview.transfer"
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG ANICE_DEVELOPMENT_KEYCHAIN ANICE_PREVIEW ANICE_TRANSFER_PREVIEW'
            "INFOPLIST_KEY_CFBundleDisplayName=aniCe Transfer Preview")
    else
        build_options+=("DEVELOPMENT_TEAM=$ANICE_DEVELOPMENT_TEAM" "INFOPLIST_KEY_CFBundleDisplayName=aniCe ($branch)")
    fi
    echo "Building Mac branch '$branch' from $ROOT"
    xcodebuild -project "$ROOT/apps/macos/aniCe.xcodeproj" -scheme aniCe \
        -configuration Debug -destination 'platform=macOS' -derivedDataPath "$derived" \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
        "${build_options[@]}" build
    app="$derived/Build/Products/Debug/$product.app"
    codesign --verify --deep --strict "$app"
    signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
    if [[ "$preview" == true ]]; then
        grep -Fxq "Identifier=io.github.anisharyal09.anice.preview" <<< "$signature" || fail "Built app is not an isolated UI preview."
    else
        [[ "$signature" == *"Authority=Apple Development:"* ]] || fail "Built app is not Apple Development signed."
        grep -Fxq "TeamIdentifier=$ANICE_DEVELOPMENT_TEAM" <<< "$signature" || fail "Built app has an unexpected signing team."
        if [[ "$transfer_preview" == true ]]; then
            grep -Fxq "Identifier=io.github.anisharyal09.anice.preview.transfer" <<< "$signature" || fail "Built app is not an isolated transfer preview."
        fi
    fi
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
    if [[ "$preview" == true ]]; then
        hardware="$("$adb" -s "$serial" shell getprop ro.hardware | tr -d '\r')"
        [[ "$hardware" == ranchu || "$hardware" == goldfish ]] || fail "Selected UI preview target is not an Android emulator."
    fi
    if [[ -z "${JAVA_HOME:-}" && -d '/Applications/Android Studio.app/Contents/jbr/Contents/Home' ]]; then
        export JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home'
    fi
    gradle_options=(:app:assembleDebug)
    component="io.github.anisharyal09.anice/.MainActivity"
    preview_package=""
    if [[ "$preview" == true ]]; then
        gradle_options+=("-PanicePreview=true")
        preview_package="io.github.anisharyal09.anice.preview"
    elif [[ "$transfer_preview" == true ]]; then
        gradle_options+=("-PaniceTransferPreview=true")
        preview_package="io.github.anisharyal09.anice.preview.transfer"
    fi
    if [[ -n "$preview_package" ]]; then
        component="$preview_package/io.github.anisharyal09.anice.MainActivity"
    fi
    (cd "$ROOT/apps/android" && ./gradlew "${gradle_options[@]}")
    if [[ -n "$preview_package" ]]; then
        aapt="$sdk_root/build-tools/36.0.0/aapt"
        [[ -x "$aapt" ]] || fail "Android build-tools 36.0.0 aapt is required to verify the preview package."
        metadata="$("$aapt" dump badging "$ROOT/apps/android/app/build/outputs/apk/debug/app-debug.apk")"
        [[ "$metadata" == "package: name='$preview_package' "* ]] || fail "Refusing to install an APK without the $preview_package package ID."
    fi
    if [[ "$preview" == true ]]; then
        echo "Installing isolated aniCe Preview on $serial"
    elif [[ "$transfer_preview" == true ]]; then
        echo "Installing isolated aniCe Transfer Preview on $serial"
    else
        echo "Updating aniCe on $serial"
    fi
    "$adb" -s "$serial" install -r "$ROOT/apps/android/app/build/outputs/apk/debug/app-debug.apk"
    "$adb" -s "$serial" shell am start -W -n "$component"
fi
