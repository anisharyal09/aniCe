# Now Playing adapter attribution

The adapter derives from [Vorssaint](https://github.com/vorssaint/vorssaint-utils), revision `b0599423cbf38dd0e28415ccd3f9874a2548668f`.

Copyright (C) 2026 Vorssaint. Licensed under GPL-3.0-or-later; the packaged GPL-LICENSE.txt and repository root LICENSE contain the GNU GPL text.

Reviewed incorporated files:

- `Sources/NowPlayingAdapter/NowPlayingAdapter.swift`: notification-driven reads, bounded callback waits and directed commands; failed capability queries preserve unknown support rather than reporting disabled commands. Queue calls removed and exported loader symbols renamed.
- `Sources/NowPlayingAdapter/NowPlayingSelection.swift`: native client/path discovery, recording validation and command routing; manual metadata gaps retain selection, and recording-bound position samples include recovered duration.
- `Sources/Vorssaint/Services/Notch/NotchPlaybackSource.swift`: bounded source inventory; all playing sources share eligibility before paused sources.
- `Sources/Vorssaint/Services/Notch/NotchPlaybackCommand.swift`: bounded line framing and recording-targeted requests; bounded capability publication waits and partial replies preserve known play/pause routing. Queue commands removed.
- `Sources/Vorssaint/Services/Notch/NotchMusicAutomationSupport.swift`: bounded installed scripting-dictionary parsing; shuffle support removed. Adapted as `aniCe/Features/NowPlaying/PlaybackAutomation.swift`.
- `Resources/now-playing.pl`: fixed loader entry points renamed for aniCe.

Original SPDX and copyright notices remain in each derived file; internal type names are adapted for aniCe. No notch UI, queue inspection, lyrics, radial menus or upstream artwork is incorporated.

The native implementation uses private MediaRemote APIs. Metadata availability and directed-command reliability require packaged-app runtime acceptance; symbol availability alone does not establish support.
