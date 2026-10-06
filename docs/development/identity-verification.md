# Device identity verification

Phase 2 proves local identity storage, recovery, and signature compatibility. It does not establish peer trust or a secure network session. See the [provisional decision](../decisions/0001-provisional-device-identity.md) and [shared contract](../../protocol/README.md).

## Automated checks

From `apps/android/`, use Android Studio's JDK 21 and the checked-in wrapper:

```sh
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' ./gradlew testDebugUnitTest lintDebug assembleDebug assembleDebugAndroidTest
```

With an authorized emulator or Android device attached, also run `./gradlew connectedDebugAndroidTest`. JVM tests cover normalization, contract validation, signatures, and fault-injected lifecycle transitions. Instrumentation exercises actual Android Keystore behavior with isolated test aliases. A desktop JVM passing tests does not prove Android Keystore compatibility.

From the repository root, using a full Xcode installation:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project apps/macos/aniCe.xcodeproj -scheme aniCe -configuration Debug -derivedDataPath /tmp/aniCe-DerivedData -destination 'platform=macOS' test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project apps/macos/aniCe.xcodeproj -scheme aniCe -configuration Debug -derivedDataPath /tmp/aniCe-DerivedData ONLY_ACTIVE_ARCH=NO build
```

Mac tests cover the same public contract and storage transitions. Prefix the test command with `TEST_RUNNER_ANICE_RUN_KEYCHAIN_TESTS=1` to include isolated Keychain integration, which otherwise skips. Tests use their own namespaces and clean up only their own records. Ad-hoc builds test development Keychain; they do not verify signed data-protection Keychain access or Secure Enclave operation. Access may require renewed authorization after rebuilding an ad-hoc binary. Do not substitute production keys into tests.

## Actual cross-platform signatures

Start one authorized Android device/emulator, then run:

```sh
python3 scripts/verify-identity-interchange.py
```

Use `--serial <adb-serial>` when more than one device is attached. The harness builds and installs the Android Debug/test APKs, creates an isolated Android Keystore signing key, exports a public test bundle, verifies it on Mac, creates a separate test Keychain signature, and verifies that signature on Android. `--skip-build` reuses existing Android APKs. `--output-dir <directory>` chooses where public bundles and logs remain.

Only public identity, message bytes, and signatures cross platforms. Separate Android instrumentation processes also verify persistence through process restart. Both native verifiers must reject altered messages, malformed signatures, and wrong keys; OpenSSL independently verifies both exported signatures. The runner gate rejects skipped/ignored tests, crashes, missing completion, and unexpected test counts. Every invocation creates a fresh subdirectory under `--output-dir` (or a temporary directory), so old bundles and success reports cannot satisfy a new run. The harness checks cleanup of its own keys, metadata, and device-side bundles. Test private scalars in the shared vectors are deliberately public and remain outside production assets. Fresh ECDSA signatures are verified, never compared for equality with a stored signature.

Run `python3 scripts/test_identity_interchange.py` without a device to exercise adversarial runner outputs and independent verification of shared signatures, including altered-message rejection. These checks supplement the native run; they do not replace it or prove hardware isolation.

## Manual acceptance

- Both platforms: open “This device”; check long names, themes, large text, accessibility labels, grouped fingerprint, ID/fingerprint copy actions, pending/error states, reset cancellation, and confirmed reset. Restart and verify the committed ID/fingerprint persist. Reset must change both.
- Android: check system Back, safe insets, gesture and three-button navigation, landscape, cold launch, background/resume, and maximum font scaling. Confirm the displayed protection matches the device rather than assuming an emulator has hardware isolation.
- Mac: check keyboard/focus and VoiceOver, sheet dismissal, window size/minimum, repeated Open actions, companion outside-click/Escape dismissal, reopening from the menu bar and Dock, and Quit/Command-Q. The companion must open details in the existing main window.
- Signed Mac setup, when available: verify entitlements, Secure Enclave selection or definitive hardware-unavailable fallback, no per-sign biometric prompts, locked/denied storage errors, and persistence across signed app updates.

Keep unavailable API 29, macOS 14, hardware-protection configurations, and signed Mac coverage marked unverified. Successful compilation with an older deployment target is not runtime compatibility evidence. Installation removal and explicit identity reset are distinct: Mac Keychain items can outlive app removal.

## Latest result — 2026-10-07

- Android: 17 JVM tests, lint, Debug/test APK assembly, and three native storage tests passed on API 36 emulator and Samsung hardware.
- Mac: 14 hosted tests passed without skips with isolated Keychain coverage enabled. Universal arm64/x86_64 build and strict signature verification passed.
- Actual Android Keystore ↔ Mac Keychain signatures passed in both directions on the Samsung, including negative controls, independent OpenSSL verification, persistence across Android processes, and scoped cleanup.
- The user reports that the earlier Keychain export prompt no longer appears. Older development identities with the incorrect export policy still require explicit confirmed reset.
- API 29, macOS 14, signed data-protection/Secure Enclave operation, and manual UI/accessibility acceptance remain pending.
