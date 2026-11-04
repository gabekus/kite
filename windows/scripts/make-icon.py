#!/usr/bin/env python3
"""Writes windows/resources/Kite.ico, Kite for Windows' app icon (Kite.exe, its windows, the
taskbar and Alt+Tab), from the Mac's Resources/AppIcon.icns, so the two apps show the same kite.

Apple's 1024 px icon is an 824 px body at a 100 px inset, with a drop shadow outside it. A
Windows icon has no shadow and fills its square, so this keeps the body only, centred with a
2% margin, and resamples it to the sizes Windows asks for: 16, 20, 24, 32, 40 and 48 (small
and large icons at 100% to 300%), 64, 96 and 128 (Explorer's views), and 256 (stored as PNG).

Rerun it whenever the Mac's icon changes:

    python3 -m venv /tmp/icon && /tmp/icon/bin/pip install pillow==12.3.0
    /tmp/icon/bin/python windows/scripts/make-icon.py

An explicit source or output can be given: make-icon.py [AppIcon.icns [Kite.ico]].
"""
import pathlib
import sys

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
CANVAS = 1024  # Apple's icon grid
INSET = 100  # the body's inset in it
BODY = CANVAS - 2 * INSET  # 824
MARGIN = 0.02  # each side of the Windows icon
SIZES = [256, 128, 96, 64, 48, 40, 32, 24, 20, 16]


def main():
    source = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "Resources" / "AppIcon.icns"
    output = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "windows" / "resources" / "Kite.ico"

    icon = Image.open(source)  # an .icns opens at its largest size
    icon.load()
    if icon.size != (CANVAS, CANVAS):
        sys.exit(f"{source}: expected a {CANVAS} px icon, got {icon.size[0]}×{icon.size[1]}")
    icon = icon.convert("RGBA")

    body = icon.crop((INSET, INSET, INSET + BODY, INSET + BODY))
    side = round(BODY / (1 - 2 * MARGIN))
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(body, ((side - BODY) // 2, (side - BODY) // 2), body)

    images = [square.resize((s, s), Image.Resampling.LANCZOS) for s in SIZES]
    images[0].save(output, format="ICO", sizes=[(s, s) for s in SIZES], append_images=images[1:])

    written = sorted(Image.open(output).info["sizes"])
    if written != sorted((s, s) for s in SIZES):
        sys.exit(f"{output}: wrote sizes {written}, expected {sorted(SIZES)}")
    print(f"wrote {output.relative_to(ROOT) if output.is_relative_to(ROOT) else output}: "
          f"{', '.join(str(s) for s in sorted(SIZES))} px")


if __name__ == "__main__":
    main()
