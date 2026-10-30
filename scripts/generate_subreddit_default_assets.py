#!/usr/bin/env python3
"""Build the bundled subreddit default artwork from its source images.

Needs ImageMagick plus numpy, Pillow and scipy (dev-only; nothing ships).
"""

from pathlib import Path
import subprocess
import tempfile

import numpy as np
from PIL import Image
from scipy import ndimage


ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Resources"
SOURCE_BANNER = RESOURCES / "SubredditHeaderDefaultBannerArtwork.png"
OUTPUT_BANNER = RESOURCES / "SubredditHeaderDefaultBanner.png"
OUTPUT_TINT = RESOURCES / "SubredditHeaderDefaultBannerTint.png"
OUTPUT_SNOO = RESOURCES / "SubredditHeaderDefaultBannerSnoo.png"
OUTPUT_C = ROOT / "src" / "ApolloSubredditDefaultAssets.c"


def make_transparent_banner():
    # Use the provided transparent artwork directly as a full-opacity template
    # image. Scale to fill the 5:1 banner viewport and preserve its alpha.
    subprocess.run([
        "magick", str(SOURCE_BANNER), "-background", "none", "-resize", "1280x256^",
        "-gravity", "center", "-extent", "1280x256", "-define", "png:compression-level=9",
        str(OUTPUT_BANNER),
    ], check=True)


# Snoo's footprint in the 1280x256 banner, and seed points inside his parts.
SNOO_BOX = (slice(98, 236), slice(495, 610))  # (rows, cols)
HEAD_SEED = (140, 540)
ANTENNA_BALL_SEED = (108, 585)
STEM_BOX = (slice(98, 122), slice(545, 577))
# Where Snoo is moved to (columns), so the subreddit icon centred over the
# banner doesn't cover him. Picked where his silhouette clears the arrows.
SNOO_SHIFT = -190
# A row that runs through the hills along the bottom of the art.
HILL_ROW = 230
# The supplied reference drawing of the same Snoo (white with a dark outline
# and a red heart), cropped from the screenshot it came in. It is the source
# for the outline and the heart's shape; the banner's own Snoo pixels stay.
REFERENCE_SNOO = RESOURCES / "SubredditHeaderDefaultBannerSnooReference.png"
# Source-artwork (row, col) -> reference (row, col), found once by fitting the
# reference's white Snoo onto the artwork's (scale 0.415, 0.25 deg, IoU 0.93).
REFERENCE_MATRIX = np.array([[2.409616, -0.010514], [0.010514, 2.409616]])
REFERENCE_OFFSET = np.array([-699.455, -2004.722])
REFERENCE_HEART_SEED = (390, 150)


def disk(radius):
    return ndimage.iterate_structure(ndimage.generate_binary_structure(2, 1), radius)


def to_banner(mask):
    # Scale a source-resolution mask exactly like the banner artwork.
    with tempfile.TemporaryDirectory() as scratch:
        full = Path(scratch) / "mask.png"
        scaled = Path(scratch) / "mask-banner.png"
        Image.fromarray(np.rint(np.clip(mask, 0, 1) * 255).astype(np.uint8)).save(full)
        subprocess.run([
            "magick", str(full), "-resize", "1280x256^", "-gravity", "center",
            "-extent", "1280x256", str(scaled),
        ], check=True)
        return np.asarray(Image.open(scaled).convert("L")).astype(np.float64) / 255.0


def reference_masks():
    # Outline and heart from the reference, mapped into the banner. Outline:
    # the dark strokes, ramped around their half-depth (red ~182 between the
    # ~244 background and ~121 stroke core) so the width matches the drawing;
    # it defines Snoo's edge. Line: the strokes' darker core (red < ~155),
    # about 60% as wide, which is what gets drawn.
    # Heart: the bright area its line work encloses around the seed, grown over
    # its own thin rim and a little under the strokes so no gap shows.
    reference = np.asarray(Image.open(REFERENCE_SNOO).convert("RGB")).astype(np.float64)
    red = ndimage.gaussian_filter(reference[..., 0], 0.8)

    outline = np.clip((205.0 - red) / 45.0, 0.0, 1.0)
    line = np.clip((175.0 - red) / 40.0, 0.0, 1.0)
    labels, count = ndimage.label(outline > 0.5)
    sizes = ndimage.sum(outline > 0.5, labels, range(1, count + 1))
    strokes = np.isin(labels, [i + 1 for i, size in enumerate(sizes) if size > 200])
    near_strokes = ndimage.binary_dilation(strokes, iterations=3)
    outline *= near_strokes
    line *= near_strokes

    labels, _ = ndimage.label(ndimage.binary_opening(red > 232, iterations=1))
    heart = ndimage.binary_fill_holes(labels == labels[REFERENCE_HEART_SEED])
    heart |= ndimage.binary_dilation(heart, disk(5)) & (outline < 0.95)

    source_shape = Image.open(SOURCE_BANNER).size[::-1]
    def warp(mask):
        # Pre-blur so the 2.4x reduction stays antialiased.
        soft = ndimage.gaussian_filter(mask.astype(np.float64), 1.0)
        return to_banner(ndimage.affine_transform(
            soft, REFERENCE_MATRIX, offset=REFERENCE_OFFSET, output_shape=source_shape, order=1))
    return warp(outline), warp(line), warp(heart)


def split_snoo_layers():
    # Split the banner into a tinted template layer and an untinted Snoo layer.
    # Every mask comes from the artwork's own alpha; Snoo's pixels are copied,
    # never redrawn, and moved left as a whole. The eyes, smile and heart are see-through in the artwork,
    # so the template fills them solid and the accent shows through exactly as
    # much as the artwork lets it. The antenna stem, the reference's outline and
    # the reference's heart shape are drawn in the tint too.
    banner = np.asarray(Image.open(OUTPUT_BANNER).convert("RGBA")).astype(np.float64) / 255.0
    alpha = banner[..., 3]

    # Snoo's opaque parts: alpha components that sit inside his footprint.
    labels, _ = ndimage.label(alpha > 0.5)
    in_box = np.zeros_like(alpha, dtype=bool)
    in_box[SNOO_BOX] = True
    core = np.zeros_like(in_box)
    for index, region in enumerate(ndimage.find_objects(labels), 1):
        if region and in_box[region[0].start, region[1].start] and in_box[region[0].stop - 1, region[1].stop - 1]:
            core |= labels == index
    head = labels == labels[HEAD_SEED]
    ball = labels == labels[ANTENNA_BALL_SEED]

    # Eyes and smile: holes in the face at 90% opacity, which keeps the
    # smile's thin, half-transparent right tip.
    face = (alpha > 0.9) & ndimage.binary_dilation(ndimage.binary_fill_holes(head), disk(1))
    features = ndimage.binary_dilation(ndimage.binary_fill_holes(face) & ~face, disk(1))

    outline, line, heart = reference_masks()

    # Antenna stem: the thin strokes between the head and the ball.
    thin = core & ~ndimage.binary_opening(core, disk(2))
    in_stem_box = np.zeros_like(in_box)
    in_stem_box[STEM_BOX] = True
    stem = ndimage.binary_dilation(thin & in_stem_box, disk(2)) & in_stem_box
    stem &= ~ndimage.binary_opening(core, disk(2)) & ~ndimage.binary_dilation(ball, disk(2))

    region = ndimage.binary_dilation(core | features | (heart > 0) | (outline > 0), disk(3))

    # Snoo's white: his own pixels, with the stem moved to the tint and trimmed
    # to the reference outline. White reaches the middle of the reference
    # stroke, where the thinner drawn line covers the seam.
    snoo_alpha = np.where(region, alpha, 0.0)
    snoo_alpha[stem] = 0.0
    inside = ndimage.binary_fill_holes((outline > 0.5) | (heart > 0.5) | features)
    inner = inside & ~(outline > 0.5)
    to_inner = ndimage.distance_transform_edt(~inner)
    to_outside = ndimage.distance_transform_edt(inside)
    white_area = inner | (inside & (to_inner <= to_outside))
    snoo_alpha *= (1.0 - line) * ndimage.gaussian_filter(white_area.astype(np.float64), 0.7)

    # Tinted parts of Snoo: eyes, smile, heart, stem and line, carried a couple
    # of pixels in under the white so partial edges don't show the sky.
    drawn = np.maximum(features * region, np.maximum(heart, line))
    drawn[stem] = np.maximum(drawn[stem], alpha[stem])
    snoo_tint = np.maximum(drawn, ndimage.grey_dilation(drawn, size=(5, 5)) * white_area)

    # Background art, brightened (hills ~0.2 -> ~0.45, arrows ~0.6 -> ~0.95).
    # The artwork has faint speckle (alpha < ~0.06) that brightening would
    # turn into visible smudges, so it is floored out first.
    floor = 0.06
    background = np.clip((alpha - floor) / (1.0 - floor), 0.0, 1.0)
    background = 1.0 - (1.0 - background) ** 3
    # Snoo's old spot is filled with the hills alone (no arrows): each column
    # cross-fades the hill's vertical profile from either side, stretched so
    # its top edge follows a curve joining the two sides' hilltops (matching
    # their slopes) while its flat bottom edge stays put.
    hills_labels, _ = ndimage.label(alpha > 0.12)
    hills = np.isin(hills_labels, np.unique(hills_labels[HILL_ROW][hills_labels[HILL_ROW] > 0]))
    hill_art = np.where(hills, background, 0.0)
    hole_columns = np.where(region.any(axis=0))[0]
    left, right = hole_columns.min() - 1, hole_columns.max() + 1
    rows = np.arange(alpha.shape[0], dtype=np.float64)
    bottom = float(np.where(hill_art.any(axis=1))[0].max())

    def hilltop(column):
        profile = hill_art[:, column]
        return float(np.argmax(profile > 0.5 * profile.max()))

    top_left, top_right = hilltop(left), hilltop(right)
    slope_left = (top_left - hilltop(left - 4)) / 4.0
    slope_right = (hilltop(right + 4) - top_right) / 4.0
    span = float(right - left)

    def restretch(column, top_from, top_to):
        # Rows below the hilltop map linearly onto the source's hill band;
        # rows above it keep their distance from the top.
        source = np.where(rows >= top_to,
                          top_from + (rows - top_to) * (bottom - top_from) / max(bottom - top_to, 1.0),
                          rows - top_to + top_from)
        return np.interp(source, rows, hill_art[:, column])

    for column in range(left + 1, right):
        t = (column - left) / span
        # Cubic Hermite between the hilltops, with the hills' own slopes.
        top = ((2 * t ** 3 - 3 * t ** 2 + 1) * top_left + (t ** 3 - 2 * t ** 2 + t) * span * slope_left
               + (-2 * t ** 3 + 3 * t ** 2) * top_right + (t ** 3 - t ** 2) * span * slope_right)
        fill = (1 - t) * restretch(left, top_left, top) + t * restretch(right, top_right, top)
        # The whole hill band (and anything of Snoo above it) is replaced, so
        # the new hill edge never meets leftover pixels of the old one.
        hole = region[:, column] | (rows >= min(top_left, top_right, top) - 20)
        background[hole, column] = fill[hole]

    # Move Snoo (both layers) left, whole pixels only, so his pixels are copied
    # unchanged.
    snoo_alpha = np.roll(snoo_alpha, SNOO_SHIFT, axis=1)
    snoo_rgb = np.roll(banner[..., :3], SNOO_SHIFT, axis=1)
    tint_alpha = np.maximum(background, np.roll(snoo_tint, SNOO_SHIFT, axis=1))

    tint = np.dstack([np.ones_like(alpha)] * 3 + [tint_alpha])
    snoo = np.dstack([snoo_rgb, snoo_alpha])
    snoo[..., :3] *= (snoo_alpha > 0)[..., None]
    for layer, path in ((tint, OUTPUT_TINT), (snoo, OUTPUT_SNOO)):
        Image.fromarray(np.rint(layer * 255).astype(np.uint8)).save(path, optimize=True)


def c_array(name, data):
    lines = [f"const unsigned char {name}[] = {{"]
    for index in range(0, len(data), 12):
        lines.append("    " + ", ".join(f"0x{value:02x}" for value in data[index:index + 12]) + ",")
    lines.extend(["};", f"const unsigned int {name}_len = {len(data)};", ""])
    return "\n".join(lines)


def main():
    make_transparent_banner()
    split_snoo_layers()
    icon = (RESOURCES / "SubredditHeaderDefaultIcon.png").read_bytes()
    tint = OUTPUT_TINT.read_bytes()
    snoo = OUTPUT_SNOO.read_bytes()
    OUTPUT_C.write_text(
        "// Generated from Resources/. Do not edit by hand.\n"
        '#include "ApolloSubredditDefaultAssets.h"\n\n'
        + c_array("ApolloSubredditDefaultIconPNG", icon)
        + c_array("ApolloSubredditDefaultBannerPNG", tint)
        + c_array("ApolloSubredditDefaultBannerSnooPNG", snoo),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
