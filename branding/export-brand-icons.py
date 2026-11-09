#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render application-sized assets from the path-only aniCe SVG master."""

import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT / "branding"
FINAL = BRAND / "anice-mark-final.svg"
MAC = ROOT / "apps/macos/aniCe/Assets.xcassets"
ANDROID = ROOT / "apps/android/app/src/main/res/drawable-nodpi"
REVIEW = BRAND / "review"


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
        mac_mark = temp / "mac-mark-standard-size.png"
        magick(master, "-resize", "78%", "-gravity", "center", "-background", "none",
               "-extent", "1024x1024", mac_mark)
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
            magick("-size", "1024x1024", f"xc:{color}", dock_mask,
                   "-compose", "CopyOpacity", "-composite", dock_background)
            magick(dock_background, mac_mark, "-compose", "Over", "-composite", dock_icon)
            dock_set = MAC / "DockIcon.imageset"
            name = f"DockIcon-{appearance}.png"
            magick(dock_icon, dock_set / name)

            # Gray surround reveals the transparent padding around each rounded tile.
            magick("-size", "1224x1224", "xc:#858B92", app_icon,
                   "-gravity", "center", "-compose", "Over", "-composite",
                   REVIEW / f"mac-app-icon-{appearance}-review.png")
            magick("-size", "1224x1224", "xc:#858B92", dock_icon,
                   "-gravity", "center", "-compose", "Over", "-composite",
                   REVIEW / f"mac-dock-icon-{appearance}-review.png")

        # Android color artwork, adaptive foreground, monochrome layer and notification glyph.
        magick(master, "-resize", "256x256", ANDROID / "ic_brand_mark.png")
        foreground = ANDROID / "ic_launcher_foreground.png"
        magick(master, "-resize", "700x700", "-gravity", "center", "-background", "none",
               "-extent", "1024x1024", foreground)
        for appearance, color in (("light", "#F1F0EC"), ("dark", "#3D4345")):
            adaptive = temp / f"android-icon-{appearance}-adaptive.png"
            rounded = temp / f"android-icon-{appearance}-rounded.png"
            magick("-size", "1024x1024", f"xc:{color}", foreground,
                   "-compose", "Over", "-composite", adaptive)
            # Preview with the same restrained mask; Android itself chooses the device mask.
            magick(adaptive, android_mask, "-compose", "CopyOpacity", "-composite", rounded)
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
