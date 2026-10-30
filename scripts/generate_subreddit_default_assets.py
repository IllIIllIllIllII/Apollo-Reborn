#!/usr/bin/env python3
"""Build the embedded subreddit default banner from its source artwork.

The banner is drawn in two layers: an untinted base (the astronaut, the
rocket's body and window, white sparkles and cloud highlights) and a template
whose alpha is filled with the theme accent on top (hills, clouds' shading,
arrows, crosses, the antenna ball, the rocket's nose and fins). Both are
derived from assets/subreddit-default-banner/artwork.png, a transparent
painting whose themed parts are drawn in one azure blue.

Sources and generated layers live in assets/subreddit-default-banner/, which
the tweak bundle doesn't include; the layers ship only as the byte arrays in
src/ApolloSubredditDefaultAssets.c. Needs numpy, Pillow, scipy and
opencv-python-headless (dev-only).
"""

from pathlib import Path

import cv2
import numpy as np
from PIL import Image
from scipy import ndimage


ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Resources"
ASSETS = ROOT / "assets" / "subreddit-default-banner"
SOURCE = ASSETS / "artwork.png"
OUTPUT_BASE = ASSETS / "base.png"
OUTPUT_TINT = ASSETS / "tint.png"
OUTPUT_C = ROOT / "src" / "ApolloSubredditDefaultAssets.c"

# The azure the artwork's themed parts are painted in.
ART_BLUE = np.array([11, 128, 254]) / 255.0
# Rows of the artwork that hold the scene, and the embedded width.
CROP_ROWS = (200, 658)
OUTPUT_WIDTH = 1280
# The bottom share of the crop that fades out, so the clouds don't end in a
# hard line on the page.
BOTTOM_FADE = 0.12

# Extra arrows, pluses and circles to fill the middle, which shows when the
# subreddit icon is hidden: (source x, y, w, h) copied from the art, to (x, y).
ARROW_BIG, ARROW_MID, ARROW_SMALL = (556, 210, 90, 97), (759, 290, 73, 78), (305, 345, 50, 53)
PLUS, CIRCLE = (845, 225, 28, 28), (348, 254, 27, 28)
STAMPS = [
    (ARROW_BIG, (930, 228)), (ARROW_MID, (995, 342)), (ARROW_SMALL, (852, 382)),
    (PLUS, (1062, 246)), (PLUS, (882, 300)), (PLUS, (1122, 292)), (PLUS, (918, 452)),
    (CIRCLE, (782, 240)), (CIRCLE, (1046, 300)), (CIRCLE, (1236, 398)),
]

# Hints for segmenting the astronaut and the rocket (artwork pixels, x/y).
# Strokes are (start, end, thickness): definitely object / definitely not.
ASTRONAUT_BOX = (340, 290, 690, 665)
ASTRONAUT_SEED = (480, 440)
ASTRONAUT_STROKES = [((420, 325), (480, 440), 14), ((480, 440), (520, 540), 24),
                     ((520, 540), (462, 628), 14), ((520, 540), (560, 620), 14),
                     ((520, 500), (652, 392), 12)]
ASTRONAUT_BACKGROUND = [((515, 596), (515, 650), 7), ((498, 644), (532, 644), 5)]  # between the legs
ANTENNA_BALL_SEED = (420, 325)
ANTENNA_BALL_BOTTOM = 350
ROCKET_BOX = (1440, 265, 1705, 520)
ROCKET_SEED = (1580, 390)
ROCKET_STROKES = [((1668, 292), (1532, 450), 14), ((1585, 385), (1490, 405), 8),
                  ((1575, 420), (1570, 488), 8)]
ROCKET_BACKGROUND = [((1445, 500), (1505, 455), 6), ((1460, 515), (1520, 470), 6)]  # exhaust


def disk(radius):
    return ndimage.iterate_structure(ndimage.generate_binary_structure(2, 1), radius)


def ramp(x, low, high):
    return np.clip((x - low) / (high - low), 0.0, 1.0)


def stamp(source):
    # Paste copies of existing elements (with their soft edges) into the art.
    out = source.copy()
    for (x, y, w, h), (dx, dy) in STAMPS:
        pad = 4
        patch = source[y - pad:y + h + pad, x - pad:x + w + pad]
        labels, _ = ndimage.label(patch[..., 3] > 0.02)
        keep = labels == labels[pad + h // 2, pad + w // 2 if labels[pad + h // 2, pad + w // 2] else pad]
        if not keep.any():
            keep = labels > 0
        alpha = patch[..., 3] * keep
        region = out[dy - pad:dy + h + pad, dx - pad:dx + w + pad]
        over = alpha[..., None]
        color = patch[..., :3] * over + region[..., :3] * region[..., 3:] * (1 - over)
        total = over[..., 0] + region[..., 3] * (1 - over[..., 0])
        region[..., :3] = np.where(total[..., None] > 0, color / np.maximum(total[..., None], 1e-6), 0)
        region[..., 3] = total
    return out


def segment(image, alpha, blue, box, seed, strokes, background, likely=None):
    # GrabCut from a box plus hint strokes; transparent pixels are never object.
    height, width = alpha.shape
    x0, y0, x1, y1 = box
    mask = np.full((height, width), cv2.GC_BGD, np.uint8)
    mask[y0:y1, x0:x1] = cv2.GC_PR_BGD
    if likely is not None:
        mask[likely & (mask == cv2.GC_PR_BGD)] = cv2.GC_PR_FGD
    for start, end, thickness in strokes:
        cv2.line(mask, start, end, int(cv2.GC_FGD), thickness)
    for start, end, thickness in background:
        cv2.line(mask, start, end, int(cv2.GC_BGD), thickness)
    mask[alpha < 0.1] = cv2.GC_BGD
    cv2.grabCut(image, mask, None, np.zeros((1, 65)), np.zeros((1, 65)), 10, cv2.GC_INIT_WITH_MASK)
    found = (mask == cv2.GC_FGD) | (mask == cv2.GC_PR_FGD)
    labels, _ = ndimage.label(found)
    return ndimage.binary_fill_holes(labels == labels[seed[1], seed[0]])


def build_layers():
    source = stamp(np.asarray(Image.open(SOURCE).convert("RGBA")).astype(np.float64) / 255.0)
    rgb, alpha = source[..., :3], source[..., 3]
    alpha = np.where(alpha < 0.03, 0.0, alpha)  # stray specks along the bottom edge
    rows = np.arange(alpha.shape[0])[:, None]

    # How much of each pixel is the art's blue: rgb ~ gray + amount * ART_BLUE.
    blue = np.clip(np.einsum("ij,hwj->hwi", np.linalg.pinv(np.stack([np.ones(3), ART_BLUE], 1)), rgb)[..., 1], 0, 1)
    brightest = rgb.max(-1)
    chroma = brightest - rgb.min(-1)
    hue = np.where(chroma > 1e-6,
                   (60 * (rgb[..., 0] - rgb[..., 1]) / np.maximum(chroma, 1e-6) + 240) % 360, 0)

    # Themed: the azure family (hue ~185-230), not the navy outlines (dark),
    # the purple window or the magenta eyes.
    tint = blue * ramp(hue, 175, 185) * (1 - ramp(hue, 230, 240)) * ramp(brightest, 0.45, 0.6)

    image = cv2.cvtColor((rgb * 255).astype(np.uint8), cv2.COLOR_RGB2BGR)
    astronaut = segment(image, alpha, blue, ASTRONAUT_BOX, ASTRONAUT_SEED,
                        ASTRONAUT_STROKES, ASTRONAUT_BACKGROUND)
    rocket_box = np.zeros_like(alpha, dtype=bool)
    rocket_box[ROCKET_BOX[1]:ROCKET_BOX[3], ROCKET_BOX[0]:ROCKET_BOX[2]] = True
    rocket = segment(image, alpha, blue, ROCKET_BOX, ROCKET_SEED, ROCKET_STROKES,
                     ROCKET_BACKGROUND, likely=rocket_box & (blue > 0.85))

    # Astronaut: only the antenna ball is themed; the rest turns neutral below.
    above_stem = rows < ANTENNA_BALL_BOTTOM
    labels, _ = ndimage.label(astronaut & (blue > 0.5) & above_stem)
    ball = ndimage.binary_dilation(labels == labels[ANTENNA_BALL_SEED[1], ANTENNA_BALL_SEED[0]], disk(2))
    ball &= astronaut & above_stem
    tint = tint * (1 - ndimage.gaussian_filter((astronaut & ~ball).astype(np.float64), 0.6))
    tint = np.maximum(tint, blue * ndimage.gaussian_filter(ball.astype(np.float64), 0.6))

    # Rocket: the nose and fins in full, rim lines too; the body (its shading
    # is mid-blue, under the strongest-blue cores) and the window stay as drawn.
    cores = ndimage.binary_opening(rocket & (blue > 0.85), disk(4))
    tips = ndimage.binary_dilation(cores, disk(4)) & rocket & (blue > 0.5)
    tips = ndimage.binary_fill_holes(ndimage.binary_closing(tips, disk(2))) & rocket
    ring = rocket & (hue > 245) & (hue < 290) & (chroma > 0.3)
    window = ndimage.binary_dilation(ndimage.binary_fill_holes(ndimage.binary_closing(ring, disk(3))), disk(2))
    tips &= ~window
    rim = ndimage.binary_dilation(tips, disk(3)) & rocket & ~tips & (brightest < 0.7) & ~window
    tint = tint * (1 - ndimage.gaussian_filter((rocket & ~(tips | rim)).astype(np.float64), 0.8))
    tint = np.maximum(tint, blue * ndimage.gaussian_filter(tips.astype(np.float64), 0.6))
    tint = np.clip(np.maximum(tint, ndimage.gaussian_filter(rim.astype(np.float64), 0.6)), 0, 1)
    glass = ndimage.binary_erosion(window, disk(2)) & ~ndimage.binary_dilation(ring, disk(1))
    glass_soft = ndimage.gaussian_filter(glass.astype(np.float64), 0.8)

    # Untinted colour: the pixel with its blue share taken out, so with the
    # accent set to ART_BLUE the two layers rebuild the painting.
    base = np.clip((rgb - tint[..., None] * ART_BLUE) / np.maximum(1 - tint[..., None], 1e-3), 0, 1)
    # Neutral astronaut and rocket body: their blue shading and outlines go
    # gray; the eyes keep their magenta and the window its purple and glass.
    eyes = ndimage.binary_dilation((hue > 280) & (hue < 325) & (chroma > 0.25), disk(2))
    body = rocket & ~(tips | rim) & ~window
    neutral = ndimage.gaussian_filter(((astronaut & ~ball & ~eyes) | body).astype(np.float64), 0.8)[..., None]
    gray = (base * np.array([0.2126, 0.7152, 0.0722])).sum(-1, keepdims=True)
    base = base * (1 - neutral) + gray * neutral
    # The window's purple ring matches the astronaut's visor ring: gray, with
    # its shading scaled to the visor ring's average tone.
    visor = astronaut & ~ball & ~eyes & (brightest < 0.6)
    ring_soft = ndimage.gaussian_filter((ring & ~ndimage.binary_erosion(window, disk(6))).astype(np.float64), 0.8)
    ring_soft = np.maximum(ring_soft, ndimage.gaussian_filter(ring.astype(np.float64), 0.8))[..., None]
    ring_gray = gray * (gray[visor].mean() / max(gray[ring].mean(), 1e-6))
    base = base * (1 - ring_soft) + np.clip(ring_gray, 0, 1) * ring_soft
    # The window glass goes neutral gray too.
    base = base * (1 - glass_soft[..., None]) + gray * glass_soft[..., None]

    # Two layers, accent drawn over base: base alpha a1, template alpha a2.
    tint_alpha = alpha * tint
    base_alpha = alpha * (1 - tint) / np.maximum(1 - tint_alpha, 1e-6)

    top, bottom = CROP_ROWS
    fade = np.clip((bottom - 1 - rows) / (BOTTOM_FADE * (bottom - top)), 0, 1)
    tint_alpha, base_alpha = tint_alpha * fade, base_alpha * fade
    height = round(OUTPUT_WIDTH * (bottom - top) / alpha.shape[1])

    def scaled(channels):
        return np.asarray(Image.fromarray(channels).resize((OUTPUT_WIDTH, height), Image.LANCZOS)).astype(np.float64) / 255.0

    def to8(values):
        return np.rint(np.clip(values, 0, 1) * 255).astype(np.uint8)

    # Scale the base premultiplied so transparent pixels don't bleed colour.
    premultiplied = scaled(to8(np.dstack([base * base_alpha[..., None], base_alpha])[top:bottom]))
    base_out = premultiplied[..., :3] / np.maximum(premultiplied[..., 3:], 1e-6)
    base_out = np.dstack([np.where(premultiplied[..., 3:] > 0, base_out, 0), premultiplied[..., 3]])
    Image.fromarray(to8(base_out)).save(OUTPUT_BASE, optimize=True)
    # Only the template's alpha is used, so store it as white + alpha.
    mask = Image.fromarray(to8(scaled(to8(tint_alpha[top:bottom]))))
    Image.merge("LA", (Image.new("L", mask.size, 255), mask)).save(OUTPUT_TINT, optimize=True)


def c_array(name, data):
    lines = [f"const unsigned char {name}[] = {{"]
    for index in range(0, len(data), 12):
        lines.append("    " + ", ".join(f"0x{value:02x}" for value in data[index:index + 12]) + ",")
    lines.extend(["};", f"const unsigned int {name}_len = {len(data)};", ""])
    return "\n".join(lines)


def main():
    build_layers()
    icon = (RESOURCES / "SubredditHeaderDefaultIcon.png").read_bytes()
    OUTPUT_C.write_text(
        "// Generated by scripts/generate_subreddit_default_assets.py. Do not edit by hand.\n"
        '#include "ApolloSubredditDefaultAssets.h"\n\n'
        + c_array("ApolloSubredditDefaultIconPNG", icon)
        + c_array("ApolloSubredditDefaultBannerBasePNG", OUTPUT_BASE.read_bytes())
        + c_array("ApolloSubredditDefaultBannerTintPNG", OUTPUT_TINT.read_bytes()),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
