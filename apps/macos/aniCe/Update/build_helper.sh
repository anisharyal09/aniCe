#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds and signs the universal detached update helper inside the app bundle.
set -euo pipefail
root="$SRCROOT/aniCe/Update"
output="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
work="$TEMP_DIR/aniCeUpdateHelper"
mkdir -p "$output" "$work"
for arch in arm64 x86_64; do
  xcrun swiftc -swift-version 6 -O -target "${arch}-apple-macosx14.0" -sdk "$SDKROOT" \
    -module-cache-path "$work/ModuleCache" -module-name AniCeUpdateHelper \
    "$root/UpdateHelper/main.swift" "$root/UpdateVersion.swift" \
    "$root/MacUpdateRecord.swift" "$root/MacUpdateSignature.swift" \
    -o "$work/$arch"
done
xcrun lipo -create "$work/arm64" "$work/x86_64" -output "$work/aniCeUpdateHelper"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime \
  --identifier io.github.anisharyal09.anice.update-helper "$work/aniCeUpdateHelper"
mv -f "$work/aniCeUpdateHelper" "$output/"
