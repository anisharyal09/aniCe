#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds and signs the arm64 MediaRemote adapter and packages its fixed Perl loader.
set -euo pipefail
adapter_root="$SRCROOT/aniCe/Features/NowPlaying/Adapter"
adapter_output="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/NowPlaying"
adapter_intermediates="$TEMP_DIR/NowPlayingAdapter"
mkdir -p "$adapter_output" "$adapter_intermediates"
xcrun swiftc -swift-version 5 -O -emit-library \
  -target "arm64-apple-macosx14.0" -sdk "$SDKROOT" \
  -module-cache-path "$adapter_intermediates/ModuleCache" -module-name AniCeNowPlaying \
  "$adapter_root/NowPlayingAdapter.swift" "$adapter_root/NowPlayingSelection.swift" \
  "$adapter_root/PlaybackSource.swift" "$adapter_root/PlaybackCommand.swift" \
  -o "$adapter_intermediates/libaniCeNowPlaying.dylib"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
  --options runtime "$adapter_intermediates/libaniCeNowPlaying.dylib"
# Replace the signed inode; overwriting a loaded image can invalidate cached code signatures.
mv -f "$adapter_intermediates/libaniCeNowPlaying.dylib" "$adapter_output/"
cp "$adapter_root/now-playing.pl" "$adapter_root/THIRD_PARTY_NOTICES.md" "$adapter_output/"
cp "$SRCROOT/../../LICENSE" "$adapter_output/GPL-LICENSE.txt"
