"""The Whisplay panel's geometry and pixel format, shared by the face and pairing.

Both draw on a 280x240 landscape canvas and hand the panel 240x280 portrait
RGB565, big-endian. Keeping the rotation and packing here means the two
processes that own the panel at different times cannot disagree about its
orientation.
"""
from PIL import Image, ImageChops

DISP_WIDTH, DISP_HEIGHT = 240, 280
WIDTH, HEIGHT = 280, 240

# Bit-disjoint halves of each RGB565 byte, so ImageChops.add never saturates.
_R_HI = [v & 0xF8 for v in range(256)]
_G_HI = [v >> 5 for v in range(256)]
_G_LO = [(v << 3) & 0xE0 for v in range(256)]
_B_LO = [v >> 3 for v in range(256)]


def to_rgb565(img):
    """Rotate a WIDTHxHEIGHT canvas 90 degrees CCW and pack it for draw_image."""
    r, g, b = img.convert("RGB").rotate(90, expand=True).split()
    hi = ImageChops.add(r.point(_R_HI), g.point(_G_HI))
    lo = ImageChops.add(g.point(_G_LO), b.point(_B_LO))
    return Image.merge("LA", (hi, lo)).tobytes()
