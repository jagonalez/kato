"""Remove the AI-generation watermark from the bottom-left corner of Kato assets.

Transparent PNGs (idle/alert/success): zero the alpha in the corner rect.
Opaque icon: fill the corner rect with the median color of the surrounding
ring (smooth navy gradient), then feather with a slight blur.
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ASSETS = Path("/Users/jeremy/dev/kato/Assets/Mascot")


def clean_transparent(path: Path) -> None:
    img = Image.open(path).convert("RGBA")
    w, h = img.size
    # Watermark occupies roughly x:0-17%, y:last 10% (verified visually).
    x1, y1 = int(w * 0.18), int(h * 0.90)
    arr = np.array(img)
    arr[h - (h - y1):, 0:x1, 3] = 0
    out = Image.fromarray(arr)
    out.save(path)
    print(f"cleaned (alpha) {path.name} {out.size}")


def clean_opaque(path: Path) -> None:
    img = Image.open(path).convert("RGB")
    w, h = img.size
    x1, y1 = int(w * 0.18), int(h * 0.90)
    arr = np.array(img).astype(np.float64)
    # Sample a ring around the rect (above it and right of it) for the fill color.
    ring = np.concatenate([
        arr[y1 - 60:y1 - 10, 0:x1].reshape(-1, 3),          # directly above
        arr[y1:h, x1 + 10:x1 + 70].reshape(-1, 3),          # directly right
    ])
    fill = np.median(ring, axis=0)
    arr[y1:h, 0:x1] = fill
    out = Image.fromarray(arr.astype(np.uint8))
    # Feather the patch edges.
    patch = out.crop((0, y1, x1, h)).filter(ImageFilter.GaussianBlur(6))
    out.paste(patch, (0, y1))
    out.save(path)
    print(f"cleaned (fill {fill.astype(int)}) {path.name} {out.size}")


for name in ["kato-idle.png", "kato-alert.png", "kato-success.png"]:
    clean_transparent(ASSETS / name)
clean_opaque(ASSETS / "kato-appicon.png")
