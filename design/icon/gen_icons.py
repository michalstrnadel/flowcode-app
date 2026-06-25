#!/usr/bin/env python3
"""flowcode pixel-art app-icon concept generator.

Renders on a small LOGICAL grid (crisp pixel-art) then nearest-upscales. Dark
rounded-square, cyan->violet glow palette matching the Jarvis HUD orb. Ordered
(Bayer) dithering gives the classic pixel-art gradient banding.
"""
import math
import os
from PIL import Image

LOGICAL = 128          # logical pixel grid
OUT = os.path.dirname(os.path.abspath(__file__))

BAYER = [
    [0, 8, 2, 10],
    [12, 4, 14, 6],
    [3, 11, 1, 9],
    [15, 7, 13, 5],
]


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def ramp_eval(stops, t):
    t = max(0.0, min(1.0, t))
    for i in range(len(stops) - 1):
        t0, c0 = stops[i]
        t1, c1 = stops[i + 1]
        if t <= t1:
            return lerp(c0, c1, (t - t0) / (t1 - t0) if t1 > t0 else 0.0)
    return stops[-1][1]


def quantize_ramp(stops, n):
    return [ramp_eval(stops, i / (n - 1)) for i in range(n)]


def dither_pick(palette, idx, x, y):
    """Ordered-dither between palette[k] and palette[k+1] by the fractional part."""
    idx = max(0.0, min(len(palette) - 1.0, idx))
    k = int(math.floor(idx))
    fr = idx - k
    if k >= len(palette) - 1:
        return palette[-1]
    thr = (BAYER[y % 4][x % 4] + 0.5) / 16.0
    return palette[k + 1] if fr > thr else palette[k]


# flowcode palette (core -> outer)
ORB = [
    (0.00, (236, 255, 255)),
    (0.16, (130, 244, 255)),
    (0.40, (44, 178, 240)),
    (0.66, (124, 92, 244)),
    (0.86, (70, 36, 104)),
    (1.00, (16, 14, 26)),
]
BG = [
    (0.00, (16, 17, 30)),
    (0.55, (10, 11, 20)),
    (1.00, (5, 6, 11)),
]
ORB_PAL = quantize_ramp(ORB, 7)
BG_PAL = quantize_ramp(BG, 5)


def rounded_alpha(x, y, n, radius):
    """1.0 inside an macOS-ish rounded square, 0.0 outside (hard pixel edge)."""
    r = radius
    fx = min(x, n - 1 - x)
    fy = min(y, n - 1 - y)
    if fx >= r or fy >= r:
        return 1.0
    dx = r - fx
    dy = r - fy
    return 1.0 if (dx * dx + dy * dy) <= r * r else 0.0


def base_bg(n):
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    px = img.load()
    cx = cy = (n - 1) / 2.0
    maxd = math.hypot(cx, cy)
    radius = int(round(0.2235 * n))
    for y in range(n):
        for x in range(n):
            a = rounded_alpha(x, y, n, radius)
            if a <= 0:
                continue
            r = math.hypot(x - cx, y - cy) / maxd
            col = dither_pick(BG_PAL, r * (len(BG_PAL) - 1), x, y)
            px[x, y] = (col[0], col[1], col[2], 255)
    return img, px, cx, cy, radius


def add_orb(px, n, cx, cy, R, rings=True):
    for y in range(n):
        for x in range(n):
            if px[x, y][3] == 0:
                continue
            d = math.hypot(x - cx, y - cy)
            t = d / R
            if t > 1.05:
                continue
            col = dither_pick(ORB_PAL, t * (len(ORB_PAL) - 1), x, y)
            # additive-ish blend over bg for a glow that fades into the square
            base = px[x, y]
            w = max(0.0, 1.0 - t)  # stronger near core
            out = lerp(base[:3], col, min(1.0, 0.25 + 0.75 * w))
            px[x, y] = (out[0], out[1], out[2], 255)
    if rings:
        # two thin darker concentric rings for a "tech orb" read
        for y in range(n):
            for x in range(n):
                if px[x, y][3] == 0:
                    continue
                d = math.hypot(x - cx, y - cy) / R
                for rr in (0.52, 0.80):
                    if abs(d - rr) < (1.1 / R):
                        b = px[x, y]
                        out = lerp(b[:3], (6, 8, 16), 0.45)
                        px[x, y] = (out[0], out[1], out[2], 255)


def concept_orb(n):
    img, px, cx, cy, radius = base_bg(n)
    add_orb(px, n, cx, cy, R=n * 0.34, rings=True)
    # white-hot pixel core
    for y in range(n):
        for x in range(n):
            if px[x, y][3] == 0:
                continue
            d = math.hypot(x - cx, y - cy)
            if d < n * 0.06:
                px[x, y] = (240, 255, 255, 255)
    return img


def concept_ripple(n):
    img, px, cx, cy, radius = base_bg(n)
    R = n * 0.40
    for y in range(n):
        for x in range(n):
            if px[x, y][3] == 0:
                continue
            d = math.hypot(x - cx, y - cy) / R
            if d > 1.0:
                continue
            wave = 0.5 + 0.5 * math.cos(d * math.pi * 5.0)  # concentric rings
            col = dither_pick(ORB_PAL, (1.0 - wave) * (len(ORB_PAL) - 1) * 0.9, x, y)
            base = px[x, y]
            out = lerp(base[:3], col, 0.30 + 0.6 * wave * max(0.0, 1.0 - d))
            px[x, y] = (out[0], out[1], out[2], 255)
    for y in range(n):
        for x in range(n):
            if px[x, y][3] and math.hypot(x - cx, y - cy) < n * 0.05:
                px[x, y] = (240, 255, 255, 255)
    return img


def concept_wave(n):
    img, px, cx, cy, radius = base_bg(n)
    # soft central glow
    add_orb(px, n, cx, cy, R=n * 0.42, rings=False)
    bars = 9
    bw = int(n * 0.055)
    gap = int(n * 0.028)
    total = bars * bw + (bars - 1) * gap
    x0 = int(cx - total / 2)
    heights = [0.30, 0.55, 0.78, 0.95, 0.62, 0.95, 0.78, 0.55, 0.30]
    for i in range(bars):
        h = heights[i] * n * 0.34
        bx = x0 + i * (bw + gap)
        top = int(cy - h)
        bot = int(cy + h)
        for x in range(bx, bx + bw):
            for y in range(top, bot):
                if 0 <= x < n and 0 <= y < n and px[x, y][3]:
                    vt = abs(y - cy) / (n * 0.34)
                    col = dither_pick(ORB_PAL, vt * (len(ORB_PAL) - 1) * 0.85, x, y)
                    px[x, y] = (col[0], col[1], col[2], 255)
    return img


def concept_mono(n):
    img, px, cx, cy, radius = base_bg(n)
    add_orb(px, n, cx, cy, R=n * 0.36, rings=False)
    # blocky lowercase 'f' mask (pixel font), centered
    grid = [
        "..####",
        ".#....",
        ".#....",
        "####..",
        ".#....",
        ".#....",
        ".#....",
        ".#....",
    ]
    gh = len(grid)
    gw = len(grid[0])
    cell = int(n * 0.072)
    ox = int(cx - gw * cell / 2)
    oy = int(cy - gh * cell / 2)
    for gy, row in enumerate(grid):
        for gx, ch in enumerate(row):
            if ch != "#":
                continue
            for yy in range(oy + gy * cell, oy + (gy + 1) * cell):
                for xx in range(ox + gx * cell, ox + (gx + 1) * cell):
                    if 0 <= xx < n and 0 <= yy < n and px[xx, yy][3]:
                        px[xx, yy] = (244, 255, 255, 255)
    return img


def render(fn, name, scale):
    img = fn(LOGICAL)
    big = img.resize((LOGICAL * scale, LOGICAL * scale), Image.NEAREST)
    out = os.path.join(OUT, f"{name}.png")
    big.save(out)
    print(f"wrote {out} ({big.size[0]}px)")


if __name__ == "__main__":
    scale = 4  # 512px previews
    render(concept_orb, "concept_orb", scale)
    render(concept_ripple, "concept_ripple", scale)
    render(concept_wave, "concept_wave", scale)
    render(concept_mono, "concept_mono", scale)
    print("done")
