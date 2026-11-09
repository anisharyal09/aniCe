#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render application-sized assets from the path-only aniCe SVG master."""

import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOGO_ASSETS = ROOT / "assets" / "logo"
FINAL = LOGO_ASSETS / "anice-mark-final.svg"
MAC = ROOT / "apps/macos/aniCe/Assets.xcassets"
ANDROID = ROOT / "apps/android/app/src/main/res/drawable-nodpi"
ANDROID_DARK_BACKGROUND = ANDROID / "ic_launcher_background_dark.png"
REVIEW = LOGO_ASSETS / "review"


def magick(*args):
    subprocess.run(["magick", *map(str, args)], check=True)


def white_glyph(mask, size, output):
    magick("-size", f"{size}x{size}", "xc:white", mask,
           "-compose", "CopyOpacity", "-composite", output)


def menu_template_mask(source, size, output, temp):
    gray = temp / "menu-luma.png"
    alpha = temp / "menu-alpha.png"
    magick(source, "-alpha", "off", "-colorspace", "gray", "-level", "7%,90%", gray)
    magick(source, "-alpha", "extract", alpha)
    magick(gray, alpha, "-compose", "Multiply", "-composite",
           "-filter", "Lanczos", "-resize", f"{size}x{size}", output)


def export():
    if not FINAL.is_file():
        raise SystemExit(f"Missing vector master: {FINAL}")
    REVIEW.mkdir(parents=True, exist_ok=True)
    ANDROID.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="anice-brand-") as temp_name:
        temp = Path(temp_name)
        master = temp / "master.png"
        alpha = temp / "alpha.png"
        magick("-background", "none", FINAL, "-resize", "1024x1024", master)
        magick(master, "-alpha", "extract", alpha)

        # Sidebar and About marks keep the source canvas and transparency.
        brand_set = MAC / "BrandMark.imageset"
        for scale in (1, 2, 3):
            pixels = 22 * scale
            name = "BrandMark" + ("" if scale == 1 else f"@{scale}x") + ".png"
            magick(master, "-resize", f"{pixels}x{pixels}", brand_set / name)

        # The menu-bar asset is a single-color template; AppKit supplies its foreground tint.
        status_set = MAC / "StatusBarMark.imageset"
        for scale, pixels in ((1, 22), (2, 43), (3, 65)):
            mask = temp / f"status-alpha-{scale}.png"
            menu_template_mask(master, pixels, mask, temp)
            name = "StatusBarMark" + ("" if scale == 1 else f"@{scale}x") + ".png"
            white_glyph(mask, pixels, status_set / name)

        # AppIcon fills its native rounded-square tile; the Dock tile is inset so
        # its visible background matches neighboring Dock icons without shrinking the mark.
        app_mask = temp / "mac-app-rounded-mask.png"
        magick("-size", "1024x1024", "xc:black", "-fill", "white",
               "-draw", "roundrectangle 0,0 1023,1023 160,160", "-alpha", "off", app_mask)
        dock_mask = temp / "mac-dock-inset-mask.png"
        magick("-size", "1024x1024", "xc:black", "-fill", "white",
               "-draw", "roundrectangle 72,72 951,951 140,140", "-alpha", "off", dock_mask)
        android_mask = temp / "android-launcher-mask.png"
        magick("-size", "1024x1024", "xc:black", "-fill", "white",
               "-draw", "roundrectangle 0,0 1023,1023 160,160", "-alpha", "off", android_mask)
        android_preview_rim = temp / "android-dark-preview-rim.png"
        magick("-size", "1024x1024", "xc:none",
               "-fill", "none", "-stroke", "rgba(245,247,248,0.22)",
               "-strokewidth", "10",
               "-draw", "roundrectangle 9,9 1014,1014 151,151",
               android_preview_rim)
        mac_mark = temp / "mac-mark-standard-size.png"
        magick(master, "-resize", "78%", "-gravity", "center", "-background", "none",
               "-extent", "1024x1024", mac_mark)
        dark_dock_gradient = temp / "mac-dock-dark-gradient.png"
        magick("-size", "1024x1024", "radial-gradient:#2C3133-#171A1C",
               dark_dock_gradient)
        # Keep the Dark tile near-black; a faint rim and top/bottom glints define its edge.
        dark_dock_rim = temp / "mac-dock-dark-edge-highlight.png"
        magick("-size", "1024x1024", "xc:none",
               "-fill", "none", "-stroke", "rgba(220,224,228,0.12)",
               "-strokewidth", "8",
               "-draw", "roundrectangle 76,76 947,947 136,136",
               "-stroke", "none", "-fill", "rgba(245,247,248,0.22)",
               "-draw", "roundrectangle 220,76 803,84 4,4 roundrectangle 220,939 803,947 4,4",
               dark_dock_rim)
        magick(dark_dock_gradient, "-depth", "8", ANDROID_DARK_BACKGROUND)
        for appearance, color in (("light", "#F1F0EC"), ("dark", "#454C4F")):
            tile = temp / f"mac-app-icon-{appearance}.png"
            app_icon = temp / f"mac-app-icon-{appearance}-rounded.png"
            magick("-size", "1024x1024", f"xc:{color}", mac_mark,
                   "-compose", "Over", "-composite", tile)
            magick(tile, app_mask, "-compose", "CopyOpacity", "-composite", app_icon)
            if appearance == "light":
                app_icons = MAC / "AppIcon.appiconset"
                app_catalog = json.loads((app_icons / "Contents.json").read_text())
                for entry in app_catalog["images"]:
                    pixels = round(int(entry["size"].split("x")[0]) * int(entry["scale"][0]))
                    magick(app_icon, "-resize", f"{pixels}x{pixels}", app_icons / entry["filename"])

            dock_background = temp / f"mac-dock-background-{appearance}.png"
            dock_icon = temp / f"mac-dock-icon-{appearance}.png"
            if appearance == "dark":
                magick(dark_dock_gradient, dock_mask,
                       "-compose", "CopyOpacity", "-composite", dock_background)
                highlighted_background = temp / "mac-dock-dark-highlighted-background.png"
                magick(dock_background, dark_dock_rim,
                       "-compose", "Over", "-composite", highlighted_background)
                dock_background = highlighted_background
            else:
                magick("-size", "1024x1024", f"xc:{color}", dock_mask,
                       "-compose", "CopyOpacity", "-composite", dock_background)
            magick(dock_background, mac_mark, "-compose", "Over", "-composite", dock_icon)
            dock_set = MAC / "DockIcon.imageset"
            name = f"DockIcon-{appearance}.png"
            if appearance == "dark":
                magick(dock_icon, "-depth", "8", dock_set / name)
            else:
                magick(dock_icon, dock_set / name)

            # Gray surround reveals the transparent padding around each rounded tile.
            magick("-size", "1224x1224", "xc:#858B92", app_icon,
                   "-gravity", "center", "-compose", "Over", "-composite",
                   REVIEW / f"mac-app-icon-{appearance}-review.png")
            dock_review = REVIEW / f"mac-dock-icon-{appearance}-review.png"
            if appearance == "dark":
                magick("-size", "1224x1224", "xc:#858B92", dock_icon,
                       "-gravity", "center", "-compose", "Over", "-composite",
                       "-depth", "8", dock_review)
            else:
                magick("-size", "1224x1224", "xc:#858B92", dock_icon,
                       "-gravity", "center", "-compose", "Over", "-composite",
                       dock_review)

        # Android color artwork, adaptive foreground, monochrome layer and notification glyph.
        magick(master, "-resize", "256x256", ANDROID / "ic_brand_mark.png")
        foreground = ANDROID / "ic_launcher_foreground.png"
        magick(master, "-resize", "700x700", "-gravity", "center", "-background", "none",
               "-extent", "1024x1024", foreground)
        for appearance in ("light", "dark"):
            adaptive = temp / f"android-icon-{appearance}-adaptive.png"
            rounded = temp / f"android-icon-{appearance}-rounded.png"
            if appearance == "dark":
                magick(ANDROID_DARK_BACKGROUND, foreground,
                       "-compose", "Over", "-composite", adaptive)
            else:
                magick("-size", "1024x1024", "xc:#F1F0EC", foreground,
                       "-compose", "Over", "-composite", adaptive)
            # Preview with the same restrained mask; Android itself chooses the device mask.
            magick(adaptive, android_mask, "-compose", "CopyOpacity", "-composite", rounded)
            if appearance == "dark":
                rounded_with_rim = temp / "android-icon-dark-with-rim.png"
                magick(rounded, android_preview_rim,
                       "-compose", "Over", "-composite", rounded_with_rim)
                rounded = rounded_with_rim
            magick("-size", "1224x1224", "xc:#858B92", rounded,
                   "-gravity", "center", "-compose", "Over", "-composite",
                   REVIEW / f"android-app-icon-{appearance}-review.png")
        foreground_alpha = temp / "foreground-alpha.png"
        magick(foreground, "-alpha", "extract", foreground_alpha)
        white_glyph(foreground_alpha, 1024, ANDROID / "ic_brand_monochrome.png")
        notification_alpha = temp / "notification-alpha.png"
        magick(alpha, "-filter", "Lanczos", "-resize", "256x256", notification_alpha)
        white_glyph(notification_alpha, 256, ANDROID / "ic_notification_small.png")

        # Boundary proof on a neutral checkerboard.
        cells = []
        step = 128
        for y in range(8):
            for x in range(8):
                if (x + y) % 2:
                    x0, y0 = x * step, y * step
                    cells.append(f"rectangle {x0},{y0} {x0 + step - 1},{y0 + step - 1}")
        checker = temp / "checker.png"
        magick("-size", "1024x1024", "xc:#eef0f2", "-fill", "#cbd0d4",
               "-draw", " ".join(cells), checker)
        magick(checker, master, "-compose", "Over", "-composite",
               REVIEW / "anice-mark-transparent-review.png")

if __name__ == "__main__":
    export()
