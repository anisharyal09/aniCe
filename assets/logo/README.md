<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# aniCe Brand Assets

The sculpted, ringless silver ribbon mark used across macOS and Android.

## Files

- [`anice-mark-final.svg`](anice-mark-final.svg): Path-only vector master on a transparent canvas (production source).
- [`anice-sculpted-mark-ringless-v1.svg`](anice-sculpted-mark-ringless-v1.svg): Original reference with embedded raster.

## Regenerating Icons

Requires ImageMagick (`brew install imagemagick`). From repository root:

```bash
python3 assets/logo/export-brand-icons.py
```

Generates macOS app/Dock/status icons, Android adaptive launcher icons, and previews in [`review/`](review/).

## Previews

- [Transparent Master](review/anice-mark-transparent-review.png)
- macOS App Icon: [Light](review/mac-app-icon-light-review.png) · [Dark](review/mac-app-icon-dark-review.png)
- macOS Dock Icon: [Light](review/mac-dock-icon-light-review.png) · [Dark](review/mac-dock-icon-dark-review.png)
- Android Launcher: [Light](review/android-app-icon-light-review.png) · [Dark](review/android-app-icon-dark-review.png)
