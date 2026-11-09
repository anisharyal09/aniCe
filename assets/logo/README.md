<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# aniCe logo and icon assets

`anice-mark-final.svg` is the path-only master for the ringless silver ribbon. It preserves the selected reference's silhouette, reflected light, shaded folds and fine metal grain. The canvas is transparent: it adds no background, border or embedded bitmap, so the mark scales without pixelation.

`anice-sculpted-mark-ringless-v1.svg` remains as the original supplied reference. It embeds a raster; app assets are generated from the path-only final master instead.

Run `python3 assets/logo/export-brand-icons.py` from the repository root to regenerate the Mac app icon, appearance-aware Dock icon, sidebar/About and menu-bar artwork, plus Android app bar/About, launcher and notification artwork. The script requires ImageMagick. It also writes transparent-edge and platform appearance previews under `assets/logo/review/`.

The Mac app icon uses a full rounded Light tile (`#F1F0EC`). The Dock switches with system appearance and uses an inset tile around the unchanged mark: Light `#F1F0EC`, Dark near-black graphite with a subtle inner glow and fine top/bottom rim highlights. Android keeps its current foreground size and monochrome layer: Light uses a softly warm background, while Dark uses the same graphite glow and a fine adaptive edge highlight. Each platform applies its native launcher mask. Reviews include [Mac app icons](review/mac-app-icon-light-review.png), [inset Dock icons](review/mac-dock-icon-light-review.png), and [Android icons](review/android-app-icon-light-review.png), each with Light/Dark variants.
