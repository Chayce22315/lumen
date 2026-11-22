"""Renders Lumen's app icon (default, dark and tinted appearances) into the asset catalog.

    python3 Tools/AppIcon/render.py

Requires Pillow. The artwork is a four-point spark of light on the palette's navy, with a soft
accent glow. Colors come from `LumenDesignTokens/Palette.swift`; keep them in step.
"""
from __future__ import annotations

import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
SCALE = 4  # supersampling factor for smooth edges
CANVAS = SIZE * SCALE

BACKGROUND = (0x10, 0x18, 0x27)  # Palette.background (dark)
SURFACE = (0x18, 0x24, 0x38)     # Palette.surface (dark)
ACCENT = (0x39, 0x7B, 0xFF)      # Palette.accent (dark)
HIGHLIGHT = (0xD6, 0xE4, 0xFF)   # the spark's cool white core

OUTPUT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..",
    "App", "Lumen", "Assets.xcassets", "AppIcon.appiconset",
)


def spark_points(cx: float, cy: float, rx: float, ry: float, sharpness: float, steps: int = 720):
    """A four-point star with concave sides: a superellipse with exponent < 1."""
    points = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = cx + rx * math.copysign(abs(c) ** sharpness, c)
        y = cy + ry * math.copysign(abs(s) ** sharpness, s)
        points.append((x, y))
    return points


def spark_mask(scale_x: float = 0.30, scale_y: float = 0.37, sharpness: float = 4.2) -> Image.Image:
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    draw = ImageDraw.Draw(mask)
    centre = CANVAS / 2
    draw.polygon(spark_points(centre, centre, CANVAS * scale_x, CANVAS * scale_y, sharpness), fill=255)
    return mask


def radial(color: tuple[int, int, int], radius: float, strength: float) -> Image.Image:
    """An RGBA radial glow centred on the canvas, alpha falling off smoothly to zero."""
    small = 256
    glow = Image.new("L", (small, small), 0)
    pixels = glow.load()
    centre = (small - 1) / 2
    for y in range(small):
        for x in range(small):
            d = math.hypot(x - centre, y - centre) / (small / 2 * radius)
            pixels[x, y] = int(255 * strength * max(0.0, 1 - d) ** 2.2)
    glow = glow.resize((CANVAS, CANVAS), Image.Resampling.BICUBIC)
    layer = Image.new("RGBA", (CANVAS, CANVAS), color + (0,))
    layer.putalpha(glow)
    return layer


def vertical_gradient(top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    column = Image.new("RGB", (1, CANVAS))
    for y in range(CANVAS):
        t = y / (CANVAS - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return column.resize((CANVAS, CANVAS))


def spark_layer(core: tuple[int, int, int], rim: tuple[int, int, int]) -> Image.Image:
    """The spark filled with a radial blend from `core` at the centre to `rim` at the tips."""
    mask = spark_mask()
    fill = Image.new("RGBA", (CANVAS, CANVAS), rim + (255,))
    centre_glow = radial(core, radius=0.30, strength=1.0)
    fill = Image.alpha_composite(fill, centre_glow)
    fill.putalpha(mask)
    return fill


def halo_layer(color: tuple[int, int, int], strength: float) -> Image.Image:
    """A blurred copy of the spark: light bleeding into the background."""
    mask = spark_mask(scale_x=0.31, scale_y=0.38, sharpness=3.6)
    blurred = mask.filter(ImageFilter.GaussianBlur(CANVAS * 0.03))
    blurred = blurred.point(lambda v: int(v * strength))
    layer = Image.new("RGBA", (CANVAS, CANVAS), color + (0,))
    layer.putalpha(blurred)
    return layer


def artwork(background: Image.Image | None, glow: tuple[int, int, int], core, rim) -> Image.Image:
    base = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    if background is not None:
        base.paste(background, (0, 0))
        base.putalpha(255)
    base = Image.alpha_composite(base, radial(glow, radius=0.75, strength=0.45))
    base = Image.alpha_composite(base, halo_layer(glow, strength=0.9))
    base = Image.alpha_composite(base, spark_layer(core, rim))
    return base.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def main() -> int:
    os.makedirs(OUTPUT, exist_ok=True)
    light_rim = (0x8F, 0xB4, 0xFF)

    default = artwork(vertical_gradient(SURFACE, BACKGROUND), ACCENT, HIGHLIGHT, light_rim)
    # The App Store icon must be opaque: drop the alpha channel entirely.
    default.convert("RGB").save(os.path.join(OUTPUT, "AppIcon.png"), optimize=True)

    # Dark appearance: the system supplies the dark backdrop, so the background is transparent.
    dark = artwork(None, ACCENT, HIGHLIGHT, light_rim)
    dark.save(os.path.join(OUTPUT, "AppIcon-Dark.png"), optimize=True)

    # Tinted appearance: grayscale artwork the system tints.
    tinted = artwork(None, (0x9A, 0x9A, 0x9A), (0xFF, 0xFF, 0xFF), (0xC8, 0xC8, 0xC8))
    gray = tinted.convert("LA").convert("RGBA")
    gray.save(os.path.join(OUTPUT, "AppIcon-Tinted.png"), optimize=True)

    # Sanity checks the asset catalog relies on.
    with Image.open(os.path.join(OUTPUT, "AppIcon.png")) as check:
        assert check.size == (SIZE, SIZE) and check.mode == "RGB", (check.size, check.mode)
    for name in ("AppIcon-Dark.png", "AppIcon-Tinted.png"):
        with Image.open(os.path.join(OUTPUT, name)) as check:
            assert check.size == (SIZE, SIZE), (name, check.size)
    print("Rendered", os.path.normpath(OUTPUT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
