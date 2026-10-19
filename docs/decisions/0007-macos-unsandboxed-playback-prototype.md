# macOS application process boundary

## Decision

Mac Debug and Release disable App Sandbox in the Xcode target and app entitlements. This applies to the entire Mac app; playback motivated the change but does not limit its scope. Hardened runtime remains enabled in build settings; signing remains Manual / Sign to Run Locally. The existing development Keychain backend, key tags, trust credentials and session cryptography remain unchanged.

Identity metadata and trust journals keep their original location beneath `~/Library/Containers/io.github.anisharyal09.anice/Data/Library/Application Support/aniCe/`. Resolve the account home independently of Foundation's sandbox redirection. Removing sandboxing must not select a fresh journal directory, create another identity or migrate existing trust. Explicit test journal URLs remain supported.

A signed universal dylib and a fixed Perl loader are packaged as resources. The main app does not load private MediaRemote symbols in-process. One application-scoped owner observes native playback only while a local media surface is visible or Android holds an active subscription. Installed playback scripting dictionaries provide scoped Apple Event capabilities; permission requests originate only from an explicit Mac action.

## Context

The pinned Vorssaint reference uses private MediaRemote APIs through a dylib loaded by Apple's Perl executable. aniCe adapts its loader, native adapter/selection, source inventory, command framing and scripting support, retaining upstream notices. Application ownership, authenticated subscriptions, presentation and output-volume integration are implemented in aniCe. Vorssaint is not sandboxed; its working process architecture does not establish aniCe's platform support or safe command routing.

Removing sandboxing permits a broader process/filesystem boundary; it does not grant TCC consent, guarantee MediaRemote availability, or establish future ADB, clipboard or streaming functionality.

## Consequences

- App Sandbox no longer confines aniCe. Existing signing defaults remain development-oriented.
- Release app and universal helper signatures carry `adhoc,runtime` flags. Xcode disables effective hardened runtime for its ad-hoc Debug app despite `ENABLE_HARDENED_RUNTIME = YES`; the existing signing defaults are retained. Forcing runtime on the ad-hoc Debug split dylib fails Team ID library validation.
- Permission prompts, Bluetooth/LAN admission and Keychain access remain subject to native OS policy.
- The adapter must refuse commands that cannot be bound to the selected running player and recording. No global playback-command fallback is permitted.
- Unsupported player/action combinations remain disabled. Physical targeting acceptance is recorded per player rather than inferred from metadata availability. See [Now Playing](../features/NOW_PLAYING.md).
