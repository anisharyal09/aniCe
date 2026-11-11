<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Release updates and signing

aniCe reads GitHub Releases directly. Stable releases are the default; the Updates section in Settings enables prereleases. A release tag has the form `vMAJOR.MINOR.PATCH` or `vMAJOR.MINOR.PATCH-beta.N`, with `alpha` and `rc` also supported. `scripts/release_version.py` validates the bounds and computes the Android version code shared with both app parsers.

The Android updater downloads a bounded APK into app-private cache, checks the package, version and signing lineage, then opens a user-confirmed Android installer session. Android may require allowing aniCe to install apps. Install the first production-signed APK manually; subsequent APKs must use the same key or an Android-supported signing lineage. Keep two encrypted offline backups of the production keystore. Never reuse the sandbox keystore or commit passwords or key files.

The Mac app downloads a release beside the installed bundle, preflights the ZIP, extracts it into private staging and verifies the staged bundle’s signature, identifier, versions and certificate pins before it copies the signed update helper and hands over a nonce-bound install record. The helper waits for the app to exit, re-verifies both bundles, atomically exchanges the staged and installed bundles, and relaunches. The new app deletes the previous bundle only after its main window initializes. An install that fails before the exchange leaves the installed bundle unchanged; a failed relaunch exchanges the previous bundle back. If the new build does not reach its main window within 30 seconds, the helper terminates it, restores the previous bundle and relaunches the previous version. A failed or abandoned install appears in the main window and in Settings → Updates. When aniCe cannot write beside itself, it offers the GitHub release for manual installation and can reveal the current app in Finder. Automatic installation also requires a volume that supports an atomic exchange; aniCe checks this before downloading and offers the release for manual installation when the check fails. A self-signed certificate does not provide Apple notarization, and the first launch may require Gatekeeper approval. Changing a signing identity can prompt again for existing Keychain items or privacy permissions.

## GitHub release setup

Configure a protected GitHub Actions environment named `release` with a required reviewer, and restrict creation and updates of `v*` tags to maintainers using a repository ruleset. Enable immutable releases if available. These repository settings must be configured separately; the checked-in workflow cannot enforce their existence.

Set these environment secrets without committing their contents:

- `ANDROID_KEYSTORE_BASE64`: single-line base64 production keystore.
- `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`: Android signing credentials.
- `MAC_CERT_P12_BASE64`: single-line base64 self-signed code-signing identity export. Export the identity and certificate from Keychain Access; an OpenSSL-generated `.p12` may need `-legacy` for macOS to import it.
- `MAC_CERT_PASSWORD`: export password.

Set these environment variables:

- `ANDROID_CERT_SHA256`: lowercase SHA-256 fingerprint of the Android signing certificate, without separators.
- `MAC_SIGNING_IDENTITY`: the Mac identity accepted by `codesign`.
- `MAC_UPDATE_PIN_CURRENT`: lowercase SHA-256 fingerprint of the Mac leaf certificate, without separators.
- `MAC_UPDATE_PIN_NEXT`: optional future Mac certificate fingerprint for a planned rotation. To rotate, publish one release signed by the current certificate with the replacement pinned, then make the replacement current for the following release.
- `RELEASE_DEVICE_VERIFIED_COMMIT`: the full source commit SHA, set only after the signed device and recovery checks pass for that commit. Publication fails closed if it is absent or differs from the tagged commit; dry runs do not require it.

The workflow uses temporary signing files and a temporary Mac keychain. A manual dispatch with `dry_run` enabled uploads workflow artifacts only. A real tag or non-dry-run dispatch publishes a draft only after signed builds and release checks succeed. The Mac packaging step refuses to proceed without the signed update helper and the pinned certificate list in the built app. No public release should be published until the signed baseline/update pair and recovery behavior have been verified on physical devices.

Use separate test signing keys and isolated app data for device tests, or production-key test versions strictly below the first intended public release. Never install a production-key test build with the same version code as the intended public release.

Android APK delivery remains direct from GitHub, without a Play Store publishing workflow. Review Google's current direct-distribution requirements before broad rollout, since platform verification requirements can change.
