# Now Playing

## Using playback controls

Android Home shows playback from the connected trusted Mac, including Auto/player selection and supported play/pause, previous/next and seek controls. Features → Now Playing opens the dedicated full player with artwork and the originating Mac. Device summaries stay above playback.

Mac Features → Now Playing → Playback setup shows the active subscription and explicit permission actions. Full Now Playing exposes Auto/manual player selection directly. Its options retain refresh and existing permission/verification actions. Settings → Show Now Playing on this Mac optionally adds playback to Mac Overview and the companion; it is off by default and does not affect phone controls.

Auto follows playing sources before paused ones, retains the current source among equals, then prefers system current and stable PID order. Manual selection lasts until the player exits or observation stops. Temporary metadata gaps disable controls without changing the selection. Available actions depend on the selected player; metadata alone does not establish control support.

Seeking previews the slider and elapsed label together and sends once on release. A matching position sample confirms the preview; failure, track replacement or a six-second deadline clears it with feedback. Unknown duration and live streams omit seeking. Progress advances locally without per-second network updates.

### Volume and permissions

**Player volume** changes the selected application's volume. Music and Spotify are candidates; support requires explicit Mac permission and packaged read/write/read verification. Unverified players, browsers and wrappers do not offer this slider. Refresh player controls preserves selection and can recover temporarily unavailable support without prompting or retrying writes.

**Mac output volume** changes the Mac's default audio output. Phone volume buttons and native system media controls adjust it in five-point steps when Now Playing is active and the output device exposes a writable volume property. This needs no Automation permission. When unavailable, foreground volume buttons keep their normal Android behavior.

Supported native playback controls are automatic. Scripting controls require an explicit Mac permission action; phone commands cannot trigger approval prompts. Features explains discovering, unsupported, permission-needed and temporarily unavailable controls.

### Notifications and background use

Android uses a silent native media notification and lock-screen controls. Tapping opens Now Playing. Pausing starts a fixed 90-second grace period, after which compact cards and system media presentation disappear; explicit Now Playing access retains paused controls. Resuming restores presentation.

Foreground Android subscribes automatically. Background controls require existing companion ownership and an already-secured BLE connection. Without that ownership, including API 29–30, background playback presentation stops. Disconnect, player exit, trust removal or identity/session replacement clears remote state.

## Implementation

Mac code lives under `apps/macos/aniCe/Features/NowPlaying/`, with packaged helper sources in `Adapter/` and tests in `apps/macos/aniCeTests/NowPlaying/`. Android implementation and matching tests use `features/nowplaying/`; the installed media receiver retains its original component namespace.

One application-scoped `MacPlaybackModel` owns selection, revisions, permissions, commands and observation leases. `MediaProcessBridge` handles the packaged helper; `MediaSessionLink` handles subscriptions and bounded submissions. Observation runs only while a Mac media surface or remote subscription needs it. Shared Connections dispatches authenticated DATA without owning playback.

Commands validate the selected process/recording and never fall back to global playback commands.

Each subscription uses one already-secured channel, preferring compatible LAN and otherwise BLE. Channel changes require a fresh subscription and snapshot; submitted commands never replay. Artwork is LAN-only, in memory, bounded to 256 pixels/64 KiB with 2 KiB chunks and a ten-second assembly deadline. LAN never activates automatically.

Detailed contracts and decisions:

- [Media messages and lifecycle](../../protocol/media/README.md), [player volume](../../protocol/media/PLAYER_VOLUME.md) and [Mac output volume](../../protocol/media/OUTPUT_VOLUME.md).
- [Mac process boundary and signing](../decisions/0007-macos-unsandboxed-playback-prototype.md), [feature DATA boundaries](../decisions/0008-application-data-feature-boundaries.md) and [seek, notification and volume behavior](../decisions/features/now-playing/0009-remote-playback-presentation.md).
- [Presentation guidance](../design/DESIGN.md#now-playing).

## References and attribution

[Vorssaint](https://github.com/vorssaint/vorssaint-utils/tree/b0599423cbf38dd0e28415ccd3f9874a2548668f) supplied the reference architecture for a Perl-loaded MediaRemote adapter. Six files incorporate adapted upstream code: the native adapter, native selection, source inventory, command framing, playback scripting support and Perl loader. This is code reuse, beyond architectural inspiration. Their original copyright/SPDX headers remain; the [packaged attribution](../../apps/macos/aniCe/Features/NowPlaying/Adapter/THIRD_PARTY_NOTICES.md) maps each file and records its modifications.

aniCe implements the application-scoped playback owner, authenticated transport integration, media contracts, Android controls, notification lifecycle and Mac output-volume extension around that adapter.

## Verification

Manual application testing exercises playback controls, player selection and presentation on the current phone/Mac setup, including playback alongside Phone→Mac transfer. Packaged WebKit controls, native API checks and Mac output writes have also been exercised on Apple Silicon macOS. Offline Android tests/lint/builds and Mac hosted tests pass; earlier universal builds are recorded separately. Current totals and test tiers are listed in [Verification status](../VERIFICATION.md).

## Known limitations

The remaining matrix includes extended phone-button/lock-screen lifecycle, Music/Spotify permission and volume combinations, simultaneous-player isolation, broader browser targeting, sleep/wake and CPU/battery measurements. Optional Mac Home/companion display correlates with approximately 15–20% app CPU during playback and peaks around 35% with concurrent Phone→Mac transfer; profiling is still required to identify the cause and quantify control latency. macOS 14, Intel runtime and certificate-signed Debug coverage remain open; universal compilation does not establish runtime support.

Audio streaming, a separate media background service, automatic LAN activation, shuffle, lyrics and queues are outside this feature. Discovery-disconnect recovery remains separate.
