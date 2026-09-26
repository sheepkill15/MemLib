"""Regenerate the Windows and Android icons from assets/app_icon*.svg.

Requires Pillow and CairoSVG: python -m pip install Pillow cairosvg
"""

from io import BytesIO
from pathlib import Path

import cairosvg
from PIL import Image


ROOT = Path(__file__).resolve().parent.parent
SIZES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def render(source: str, size: int) -> Image.Image:
    data = cairosvg.svg2png(
        url=str(ROOT / "assets" / source), output_width=size, output_height=size
    )
    return Image.open(BytesIO(data)).convert("RGBA")


def main() -> None:
    icon = render("app_icon.svg", 1024)
    icon.save(ROOT / "assets" / "app_icon.png")

    ico_sizes = [(size, size) for size in (16, 24, 32, 48, 64, 128, 256)]
    for destination in (
        ROOT / "assets" / "tray_icon.ico",
        ROOT / "windows" / "runner" / "resources" / "app_icon.ico",
    ):
        icon.save(destination, format="ICO", sizes=ico_sizes)

    res = ROOT / "android" / "app" / "src" / "main" / "res"
    for density, size in SIZES.items():
        directory = res / f"mipmap-{density}"
        render("app_icon.svg", size).save(directory / "ic_launcher.png")
        render("app_icon_foreground.svg", round(size * 2.25)).save(
            directory / "ic_launcher_foreground.png"
        )


if __name__ == "__main__":
    main()
