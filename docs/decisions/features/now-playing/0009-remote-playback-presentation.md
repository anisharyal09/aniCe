# Remote playback presentation and selected-player volume

## Context

Remote seeking needs immediate consistent phone feedback while execution and authoritative position samples remain asynchronous. Native Android media controls require continuity without creating another connection or background media service. Player volume is not part of media v1 and cannot safely assume system-wide or browser support.

## Decision

Keep one Android playback owner. Slider and elapsed label read one atomic dragging/pending/authoritative presentation. Capture subscription/source/revision at drag start, send on release and permit one executing command plus one latest unsent seek intent. Ignore older position samples until confirmation within one second or a fixed six-second deadline. An applied result alone does not confirm position; failure, target replacement and uncertain outcomes discard retained intent without replay.

Native MediaSession and Notification.MediaStyle present this owner, supported actions and monotonic position/rate samples. Notifications use a silent channel and the platform [media-session notification exemption](https://developer.android.com/develop/ui/compose/notifications/notification-permission#exemptions). Tapping opens Features → Now Playing; actions bind subscription/source/revision and retire with that state. No audio playback, audio focus, separate media service or progress polling is introduced.

Pausing starts one monotonic 90-second grace period; updates do not extend it and resume cancels it. Expiry hides compact and system presentation while Features retains current player controls. Background needs an already-secured BLE channel and the existing valid companion lease. Foreground LAN state retires before a fresh BLE subscription, dropping commands/artwork. After expiry an event-only subscription observes resumption. Without companion ownership background media stops. Security invalidation and player unavailability clear presentation immediately.

Selected-player volume is a separately negotiated [extension](../../../../protocol/media/PLAYER_VOLUME.md); media v1 bytes remain unchanged. Only Music/Spotify integer application sound-volume properties are candidates. An explicit packaged Mac verification reads, writes the same value and reads again using a PID-addressed, process-launch-bound Apple Event, validating 0–100 values. Permissions remain explicit; phone execution never prompts. Unproven targets advertise no volume support. Player-volume sliders use the same owner. A transient read failure withdraws current support but retains process-bound proof for event-driven or explicit read-only recovery; uncertain writes never replay. Both platforms keep a volume preview until a matching authoritative sample, target replacement, failure or a fixed six-second deadline. Features explains unavailable support and permissions. No system-volume fallback exists.

Native and scripting playback support is resolved per action, preferring an available native route. Late native discovery is bound to source/recording/helper generation and cannot overwrite position samples or a newer playback state. Explicit refresh preserves source selection.

Mac output volume uses a separately named [extension](../../../../protocol/media/OUTPUT_VOLUME.md) for foreground phone keys and native MediaSession VolumeProvider. The Mac binds commands to a native output device/property identity, revalidates before writing and uses property notifications without polling or capture. Five-point relative adjustments retain one executing request and one latest unsent intent; uncertain outcomes drop the intent. Existing media subscription, companion lifecycle and bounded cross-kind deduplication remain shared. Player volume remains an independent explicit control, with no implicit output fallback.

## Consequences

Existing app targets, signing, identity/trust storage, companion components and session cryptography remain unchanged. Player volume requires verified application support; Mac output volume requires a writable native device property. See [Now Playing](../../../features/NOW_PLAYING.md) for usage and current limitations.
