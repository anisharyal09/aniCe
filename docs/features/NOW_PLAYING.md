# Now Playing

Android Home and **Features → Now Playing** control playback on the connected trusted Mac. The full player shows artwork, player selection, play/pause, previous/next and seeking when the selected source supports them. Audio stays on Mac unless [Private Listening](PRIVATE_LISTENING.md) explicitly streams system audio to the phone.

## Player selection and controls

**Auto** prefers playing sources and retains the current source among equally eligible players. A manual selection remains until that player exits or observation stops. Missing metadata does not silently select another player.

Seeking previews the slider and elapsed time together, then sends on release. A matching position sample confirms the preview; failure, track replacement or a six-second deadline clears it. Unknown duration and live streams omit seeking. Progress advances locally without per-second network updates.

The available actions belong to the selected running player. Metadata alone does not establish control support. Expired unsent actions report that they were not sent; a missing result after submission reports an uncertain outcome and is never automatically replayed.

## Volume and permissions

- **Player volume** changes the selected application's volume. Music and Spotify are candidates; the Mac must grant the required permission and complete the explicit player-control check. Browsers, wrappers and unsupported targets do not expose this slider.
- **Mac output volume** changes the default output device. Phone volume buttons and system media controls use five-point steps while playback is active and the output device has writable volume. Fixed-volume devices remain unavailable.
- During Private Listening ownership, phone hardware/system media volume controls local headphone output instead of the Mac. Existing player-volume controls remain separate.

Native playback controls use their available native route. Scripting controls require an explicit Mac permission action; phone commands cannot open approval prompts. **Refresh player controls** preserves selection and can recover available support without replaying writes.

Mac **Features → Now Playing → Playback setup** contains subscription information and setup actions. **Settings → Show Now Playing on this Mac** optionally adds playback to Overview and the companion. It defaults off and does not affect phone controls.

## Notifications and background use

Android uses a silent media notification and lock-screen controls. Tapping the notification opens Now Playing. Pausing starts a fixed 90-second grace period, after which compact cards and system media controls disappear; the explicit full player retains paused controls.

Background presentation requires existing companion ownership. Playing state and paused-grace presentation can retain eligible LAN or request it through authenticated BLE coordination. Without eligible LAN, controls use an already-secured BLE channel. Without companion ownership, including API 29–30, background presentation stops.

A connected LAN/BLE handoff keeps Android's system media session for up to six seconds while commands remain tied to the current subscription. A failed handoff or full disconnection removes it.

## Connection behavior

Each subscription uses one compatible secured channel, preferring LAN and otherwise BLE. Changing channels requires a fresh subscription and snapshot; submitted commands never migrate or replay. Successful retained-socket LAN renewal preserves the existing channel and subscription.

Artwork travels only over LAN. It belongs to the current recording and subscription; track or subscription replacement releases it, and missing artwork shows a placeholder. There is no artwork history or remote image fetching.

Controls share the ordered LAN stream with file transfers. Already-submitted transfer bytes cannot be reprioritized behind a later media command. Repeated continuous controls retain only their latest unsent intent, with bounded feedback and deadlines.

Disconnect, player exit, trust removal or channel replacement clears remote state. Now Playing does not itself capture/play audio, expose shuffle/lyrics/queues or own a playback service; Private Listening supplies its independent audio service.

## Implementation and attribution

One Mac playback owner manages selection, observation and commands through the packaged native adapter and the shared authenticated DATA dispatcher. Android uses one playback/presentation owner. Code lives in the platforms' `features/nowplaying/` and `Features/NowPlaying/` directories.

The adapter incorporates attributed [Vorssaint source](https://github.com/vorssaint/vorssaint-utils/tree/b0599423cbf38dd0e28415ccd3f9874a2548668f); [packaged notices](../../apps/macos/aniCe/Features/NowPlaying/Adapter/THIRD_PARTY_NOTICES.md) identify the adapted files and licenses.

See [media messages](../../protocol/media/README.md), [player volume](../../protocol/media/PLAYER_VOLUME.md), [output volume](../../protocol/media/OUTPUT_VOLUME.md), [architecture](../../ARCHITECTURE.md) and [the playback decision](../decisions/features/now-playing/0009-remote-playback-presentation.md).
