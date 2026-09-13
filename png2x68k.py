#!/usr/bin/env python3
"""
png2x68k.py - convert an image into raw X68000 65536-colour data.

Output is one big-endian 16 bit word per pixel, rows top to bottom, in the
GVRAM colour format:

    bit 15..11  G (5 bits)
    bit 10..6   R (5 bits)
    bit  5..1   B (5 bits)
    bit  0      I - a shared least significant bit for all three channels

Note the channel order: GREEN first, not red. Getting it wrong swaps reds and
greens, which is the classic first-try bug.

The hardware builds each channel as (value << 1) | I, giving 6 bits per
channel - but I is shared, so it is either set for all three or for none.
--intensity chooses how to pick it:
    majority  (default) set I when at least two channels round up
    off                 always 0: channels never exceed 62/63, but a black
                        pixel is truly black and pure colours stay pure
    on                  always 1: brightest whites, but black becomes 1/63

Usage:
    ./png2x68k.py image.png -o image.bin
    ./png2x68k.py image.png -o image.bin --size 320x240 --header

Reads PNG via Pillow if installed; binary PPM (P6) needs nothing at all, so
"export as .ppm, raw" from GIMP always works.
"""

import argparse
import struct
import sys


def load_ppm(path):
    """Minimal binary PPM (P6) reader - no dependencies."""
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"P6"):
        return None

    fields, pos = [], 2
    while len(fields) < 3:
        while pos < len(data) and data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":                 # comment to end of line
            while data[pos:pos + 1] not in (b"\n", b""):
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    pos += 1                                          # single whitespace byte

    width, height, maxval = fields
    if maxval != 255:
        sys.exit("error: only 8 bit per channel PPM is supported")
    pixels = data[pos:pos + width * height * 3]
    if len(pixels) < width * height * 3:
        sys.exit("error: truncated PPM")
    return width, height, pixels


def load_pillow(path):
    try:
        from PIL import Image
    except ImportError:
        sys.exit(f"error: reading {path} needs Pillow (pip install Pillow), "
                 f"or export the image as binary PPM from GIMP")
    img = Image.open(path).convert("RGB")
    return img.width, img.height, img.tobytes()


def load_image(path):
    return load_ppm(path) or load_pillow(path)


def to_x68k(r, g, b, intensity):
    """Pack one RGB888 pixel into the GVRAM word."""
    if intensity == "on":
        i = 1
    elif intensity == "off":
        i = 0
    else:
        # I is the 6th bit each channel would have had; take the majority
        # vote so the shared bit hurts the fewest channels.
        i = 1 if ((r >> 2) & 1) + ((g >> 2) & 1) + ((b >> 2) & 1) >= 2 else 0
    return ((g >> 3) << 11) | ((r >> 3) << 6) | ((b >> 3) << 1) | i


def main():
    p = argparse.ArgumentParser(
        description="Convert an image to raw X68000 65536-colour GVRAM data")
    p.add_argument("input", help="PNG (needs Pillow) or binary PPM")
    p.add_argument("-o", "--output", required=True, help="raw output file")
    p.add_argument("--size", metavar="WxH",
                   help="expected size, e.g. 320x240 - refuses to convert "
                        "anything else instead of silently producing garbage")
    p.add_argument("--intensity", choices=["majority", "off", "on"],
                   default="majority", help="how to pick the shared I bit")
    p.add_argument("--header", action="store_true",
                   help="prepend width and height as two big-endian words")
    p.add_argument("--asm", metavar="FILE",
                   help="also write an .inc with the equates for the image")
    a = p.parse_args()

    width, height, pixels = load_image(a.input)

    if a.size:
        try:
            want_w, want_h = (int(v) for v in a.size.lower().split("x"))
        except ValueError:
            sys.exit("error: --size wants something like 320x240")
        if (width, height) != (want_w, want_h):
            sys.exit(f"error: {a.input} is {width}x{height}, "
                     f"expected {want_w}x{want_h}")

    if width > 512 or height > 512:
        print(f"warning: {width}x{height} is larger than the 512x512 GVRAM "
              f"page", file=sys.stderr)

    out = bytearray()
    if a.header:
        out += struct.pack(">HH", width, height)

    for i in range(0, len(pixels), 3):
        r, g, b = pixels[i], pixels[i + 1], pixels[i + 2]
        out += struct.pack(">H", to_x68k(r, g, b, a.intensity))

    with open(a.output, "wb") as f:
        f.write(out)

    print(f"{a.input}: {width}x{height} -> {a.output}, {len(out)} bytes "
          f"({width * 2} bytes per row)")

    if a.asm:
        name = a.output.rsplit("/", 1)[-1].rsplit(".", 1)[0].upper()
        with open(a.asm, "w") as f:
            f.write(f"; generated by png2x68k.py from {a.input}\n"
                    f"{name}_W\tequ\t{width}\n"
                    f"{name}_H\tequ\t{height}\n"
                    f"{name}_STRIDE\tequ\t{width * 2}\n")
        print(f"{a.asm}: equates written")


if __name__ == "__main__":
    main()