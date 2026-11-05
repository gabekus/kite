#!/usr/bin/env python3
"""Writes windows/resources/Kite.ico, Kite for Windows' app icon (Kite.exe, its windows, the
taskbar and Alt+Tab), from the Mac's Resources/AppIcon.icns, so the two apps show the same kite.

Apple's 1024 px icon is an 824 px body at a 100 px inset, with a drop shadow outside it. A
Windows icon has no shadow and fills its square, so this keeps the body only, centred with a
2% margin, and resamples it to the sizes Windows asks for: 16, 20, 24, 32, 40 and 48 (small
and large icons at 100% to 300%), 64, 96 and 128 (Explorer's views), and 256. Pillow stores
every frame as a PNG, which Windows reads at any size.

Rerun it whenever the Mac's icon changes, from the repository root, with Pillow 12.3.0 in a
virtual environment outside the repository (on Windows, `py` for `python`, and the
environment's python is in Scripts/ rather than bin/):

    python -m venv ../kite-icon-venv
    ../kite-icon-venv/bin/python -m pip install pillow==12.3.0
    ../kite-icon-venv/bin/python windows/scripts/make-icon.py

When the result has the same pixels as the existing Kite.ico, the file is left alone and the
script says "unchanged": PNG compression differs between Pillow builds (Linux and Windows
wheels write different bytes for identical pixels), so only a changed icon makes a diff.

An explicit source or output can be given: make-icon.py [AppIcon.icns [Kite.ico]].
"""
import io
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

    with Image.open(source) as opened:  # an .icns opens at its largest size
        if opened.size != (CANVAS, CANVAS):
            sys.exit(f"{source}: expected a {CANVAS} px icon, got {opened.size[0]}×{opened.size[1]}")
        icon = opened.convert("RGBA")

    body = icon.crop((INSET, INSET, INSET + BODY, INSET + BODY))
    side = round(BODY / (1 - 2 * MARGIN))
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(body, ((side - BODY) // 2, (side - BODY) // 2), body)

    images = [square.resize((s, s), Image.Resampling.LANCZOS) for s in SIZES]
    encoded = io.BytesIO()
    images[0].save(encoded, format="ICO", sizes=[(s, s) for s in SIZES], append_images=images[1:])

    written = frames(encoded)
    if sorted(written) != sorted((s, s) for s in SIZES):
        sys.exit(f"wrote sizes {sorted(written)}, expected {sorted(SIZES)}")
    name = output.relative_to(ROOT) if output.is_relative_to(ROOT) else output
    if output.exists() and frames(output) == written:
        print(f"{name}: unchanged (same pixels at every size)")
        return
    output.write_bytes(encoded.getvalue())
    print(f"wrote {name}: {', '.join(str(s) for s in sorted(SIZES))} px")


def frames(ico):
    """Each size's decoded RGBA pixels, by size."""
    if isinstance(ico, io.BytesIO):
        ico.seek(0)
    with Image.open(ico) as image:
        out = {}
        for size in image.info["sizes"]:
            image.size = size
            image.load()  # Pillow reloads the frame for the new size
            out[size] = image.convert("RGBA").tobytes()
        return out


if __name__ == "__main__":
    main()
