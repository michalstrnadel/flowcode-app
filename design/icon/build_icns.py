#!/usr/bin/env python3
"""Build flowcode.iconset (all macOS sizes) from the Orb concept, then the caller
runs `iconutil` to make flowcode.icns. Large sizes stay crisp pixel art (NEAREST
upscale from the 128 logical grid); small sizes use LANCZOS for legibility."""
import os
from PIL import Image
from gen_icons import concept_orb, LOGICAL

HERE = os.path.dirname(os.path.abspath(__file__))
ISET = os.path.join(HERE, "flowcode.iconset")
os.makedirs(ISET, exist_ok=True)

logical = concept_orb(LOGICAL)                 # 128x128 logical art
master = logical.resize((1024, 1024), Image.NEAREST)


def at(px):
    if px % LOGICAL == 0:                       # integer multiple -> crisp pixels
        return logical.resize((px, px), Image.NEAREST)
    return master.resize((px, px), Image.LANCZOS)  # downscale small -> legible


# (filename, pixel size)
SPECS = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for name, px in SPECS:
    at(px).save(os.path.join(ISET, name))
    print("  ", name, px)
master.save(os.path.join(HERE, "flowcode_icon_1024.png"))
print("iconset ready:", ISET)
