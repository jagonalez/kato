#!/usr/bin/env python3
"""Build a Kato.iconset directory from the master app-icon artwork.

Usage: make-icon.py <source-png> <output-iconset-dir>

Pipeline (source PNGs are never modified):
  1. Detect the non-black bounding box of the rounded tile (the artwork is a
     navy tile inset on a black margin) and crop to it.
  2. Apply a rounded-rect alpha mask, Apple-style corner radius ~= 22.4% of
     the tile width.
  3. Export all standard .iconset sizes (16..1024 plus @2x variants).
The caller then runs `iconutil -c icns` on the result.
"""

import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

# (filename, pixel size)
ICONSET_SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

CORNER_RADIUS_FRACTION = 0.224  # Apple-style squircle approximation
BLACK_THRESHOLD = 8             # channels <= this count as the black margin


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    source = Path(sys.argv[1])
    iconset = Path(sys.argv[2])
    if not source.is_file():
        print(f"error: source not found: {source}", file=sys.stderr)
        return 1

    image = Image.open(source).convert("RGBA")

    # 1. Crop to the non-black bounding box of the rounded tile.
    rgb = np.asarray(image)[:, :, :3].astype(np.int16)
    non_black = (rgb > BLACK_THRESHOLD).any(axis=2)
    if not non_black.any():
        print("error: image is entirely black", file=sys.stderr)
        return 1
    bbox = Image.fromarray(non_black.astype(np.uint8) * 255).getbbox()
    tile = image.crop(bbox)
    print(f"cropped {image.size} -> {tile.size} at bbox {bbox}")

    # 2. Rounded-rect alpha mask (Apple-style corner radius).
    width, height = tile.size
    radius = round(width * CORNER_RADIUS_FRACTION)
    mask = Image.new("L", tile.size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([0, 0, width - 1, height - 1], radius=radius, fill=255)
    # Combine with any existing alpha (source is opaque, but stay safe).
    existing_alpha = tile.getchannel("A")
    combined = Image.composite(
        existing_alpha, Image.new("L", tile.size, 0), mask
    )
    tile.putalpha(combined)

    # 3. Export the iconset.
    iconset.mkdir(parents=True, exist_ok=True)
    for filename, size in ICONSET_SIZES:
        resized = tile.resize((size, size), Image.LANCZOS)
        resized.save(iconset / filename)
    print(f"wrote {len(ICONSET_SIZES)} sizes to {iconset}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
