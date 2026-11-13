#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build a self-signed arm64 Mac release in an isolated, temporary signing keychain.
set -euo pipefail
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo 'Mac releases require Apple Silicon and a native arm64 shell.' >&2; exit 1;
}
: "${MAC_CERT_P12_BASE64:?Missing Mac signing certificate}"
: "${MAC_CERT_PASSWORD:?Missing Mac certificate password}"
: "${MAC_SIGNING_IDENTITY:?Missing Mac signing identity}"
: "${MAC_UPDATE_PIN_CURRENT:?Missing Mac certificate pin}"
: "${RELEASE_VERSION:?Missing release version}"
: "${RELEASE_CODE:?Missing release build code}"
: "${RUNNER_TEMP:?Missing runner temporary directory}"
[[ "$MAC_UPDATE_PIN_CURRENT" =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid current certificate pin' >&2; exit 1; }
next_pin="${MAC_UPDATE_PIN_NEXT:-}"
[[ -z "$next_pin" || "$next_pin" =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid next certificate pin' >&2; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "$RUNNER_TEMP/anice-signing.XXXXXXXX")"
keychain="$work/signing.keychain-db"
password="$(openssl rand -hex 24)"
cleanup() {
  local status=$?
  trap - EXIT
  python3 - "$work" "$keychain" <<'CLEANUP' || { [[ "$status" -ne 0 ]] || status=1; }
import subprocess, sys
work, keychain = sys.argv[1:]
failed = False
for label, command, timeout in (
    ('certificate trust', ['sudo', '-n', 'security', 'remove-trusted-cert', '-d', work + '/certificate.pem'], 15),
    ('signing keychain', ['security', 'delete-keychain', keychain], 15),
    ('temporary signing files', ['rm', '-rf', work], 30),
):
    print('Cleaning up ' + label, flush=True)
    try:
        subprocess.run(command, check=True, timeout=timeout,
                       stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    except (subprocess.SubprocessError, OSError) as error:
        print('::warning::Cleanup failed for %s: %s' % (label, error), flush=True)
        # Trust and keychain registration die with the ephemeral runner; private files must be removed.
        if label == 'temporary signing files':
            failed = True
sys.exit(1 if failed else 0)
CLEANUP
  exit "$status"
}
trap cleanup EXIT
umask 077
ANICE_CERT_DEST="$work/certificate.p12" python3 -c 'import base64, os, pathlib; pathlib.Path(os.environ["ANICE_CERT_DEST"]).write_bytes(base64.b64decode(os.environ["MAC_CERT_P12_BASE64"], validate=True))'
[[ "${CI:-}" == "true" ]] || { echo 'This signing script requires an ephemeral CI runner' >&2; exit 1; }
openssl pkcs12 -in "$work/certificate.p12" -clcerts -nokeys -passin env:MAC_CERT_PASSWORD -out "$work/certificate.pem"
pin="$(openssl x509 -in "$work/certificate.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')"
[[ "$pin" == "$MAC_UPDATE_PIN_CURRENT" ]] || { echo 'Mac certificate does not match the configured pin' >&2; exit 1; }
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security default-keychain -s "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$work/certificate.p12" -k "$keychain" -P "$MAC_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/xcodebuild
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain"
keychains=()
while IFS= read -r entry; do
  entry="${entry#"${entry%%[![:space:]]*}"}"
  entry="${entry#\"}"; entry="${entry%\"}"
  keychains+=("$entry")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$keychain" "${keychains[@]}"
sudo security add-trusted-cert -d -r trustRoot -k "$keychain" "$work/certificate.pem"
sudo chown "$(id -un):$(id -gn)" "$keychain"
cd "$root"
python3 scripts/build-pairing-native.py macos
security unlock-keychain -p "$password" "$keychain"
pins="$MAC_UPDATE_PIN_CURRENT"
if [[ -n "$next_pin" ]]; then pins="$pins,$next_pin"; fi
xcodebuild -project apps/macos/aniCe.xcodeproj -scheme aniCe -configuration Release \
  -derivedDataPath "$work/DerivedData" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$MAC_SIGNING_IDENTITY" \
  "OTHER_CODE_SIGN_FLAGS=--keychain $keychain" "MARKETING_VERSION=$RELEASE_VERSION" \
  "CURRENT_PROJECT_VERSION=$RELEASE_CODE" "ANICE_UPDATE_PINS=$pins" build
app="$work/DerivedData/Build/Products/Release/aniCe.app"
[[ -d "$app" && -x "$app/Contents/Helpers/aniCeUpdateHelper" ]] || { echo 'Signed update helper is missing; refusing to package a release' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print AniceUpdateCertificatePins' "$app/Contents/Info.plist")" == "$pins" ]] || { echo 'Pinned certificate list is missing from the built app' >&2; exit 1; }
codesign --verify --deep --strict "$app"
executable="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Contents/Info.plist")"
[[ -x "$executable" ]] || { echo 'Mac app executable is missing' >&2; exit 1; }
[[ "$(lipo -archs "$executable")" == arm64 ]] || {
  echo 'Mac app executable must contain exactly arm64' >&2; exit 1;
}
codesign -dvv "$app" 2> "$work/signature.txt"
grep -q 'flags=.*runtime' "$work/signature.txt" || { echo 'Mac hardened runtime is missing' >&2; exit 1; }
codesign --verify --strict "$app/Contents/Helpers/aniCeUpdateHelper"
helper="$app/Contents/Helpers/aniCeUpdateHelper"
[[ "$(lipo -archs "$helper")" == arm64 ]] || {
  echo 'Update helper must contain exactly arm64' >&2; exit 1;
}
adapter="$app/Contents/Resources/NowPlaying/libaniCeNowPlaying.dylib"
[[ -f "$adapter" && "$(lipo -archs "$adapter")" == arm64 ]] || {
  echo 'Now Playing adapter must contain exactly arm64' >&2; exit 1;
}
codesign -dvv "$helper" 2> "$work/helper-signature.txt"
grep -q '^Identifier=io.github.anisharyal09.anice.update-helper$' "$work/helper-signature.txt" || {
  echo 'Update helper identifier is wrong' >&2; exit 1;
}
grep -q 'flags=.*runtime' "$work/helper-signature.txt" || { echo 'Update helper hardened runtime is missing' >&2; exit 1; }
codesign -d --extract-certificates="$work/helper-cert" "$helper" 2>/dev/null
helper_pin="$(openssl x509 -inform DER -in "$work/helper-cert0" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')"
[[ "$helper_pin" == "$MAC_UPDATE_PIN_CURRENT" ]] || { echo 'Update helper signing identity differs from the pinned certificate' >&2; exit 1; }
codesign -d --extract-certificates="$work/signed-cert" "$app" 2>/dev/null
signed_pin="$(openssl x509 -inform DER -in "$work/signed-cert0" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')"
[[ "$signed_pin" == "$MAC_UPDATE_PIN_CURRENT" ]] || { echo 'App signing identity differs from the pinned certificate' >&2; exit 1; }
codesign -d --entitlements :- "$app" > "$work/entitlements.plist" 2>/dev/null
python3 - "$root/apps/macos/aniCe/aniCe.entitlements" "$work/entitlements.plist" <<'PYCODE'
import plistlib, sys
with open(sys.argv[1], 'rb') as source, open(sys.argv[2], 'rb') as signed:
    expected, actual = plistlib.load(source), plistlib.load(signed)
    if expected != actual:
        for key in sorted(expected.keys() | actual.keys()):
            if key not in expected or key not in actual or expected[key] != actual[key]:
                print('%s: expected %r, signed %r' % (key, expected.get(key), actual.get(key)), file=sys.stderr)
        raise SystemExit('Signed Mac entitlements differ from the project entitlements')
PYCODE
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == 'io.github.anisharyal09.anice' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$RELEASE_VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")" == "$RELEASE_CODE" ]]
mkdir -p "$root/dist"
/usr/bin/ditto -c -k --keepParent "$app" "$root/dist/aniCe-mac.zip"
[[ "$(stat -f '%z' "$root/dist/aniCe-mac.zip")" -le 268435456 ]]

cat > "$work/main.swift" <<'SWIFTCODE'
import Foundation
try MacUpdateArchive.validate(URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFTCODE
xcrun swiftc -swift-version 6 "$root/apps/macos/aniCe/Update/UpdateVersion.swift" \
  "$root/apps/macos/aniCe/Update/ReleaseCatalog.swift" "$root/apps/macos/aniCe/Update/MacUpdateArchive.swift" \
  "$work/main.swift" -o "$work/archive-check"
"$work/archive-check" "$root/dist/aniCe-mac.zip"
