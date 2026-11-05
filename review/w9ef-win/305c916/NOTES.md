# W9e/W9f UI gate: Windows captures at 305c916

`Kite.exe --capture FILE --window-size 1280,820 --capture-scale 2` on a fresh profile holding `windows/helix/states/three-spaces.json` (2560×1640). The flags for each capture:

| file | flags | Mac reference |
|---|---|---|
| picker-emoji.png | `--icon-picker 1,emoji` | review/w9e-mac picker-emoji.png (`KITE_TEST_ICON_PICKER=Personal`) |
| picker-icon.png | `--icon-picker 2,icon` | review/w9e-mac picker-icon.png (`KITE_TEST_ICON_PICKER=Work`) |
| create-empty.png | `--create-space ""` | review/w9f-mac create-empty.png (`KITE_TEST_NEW_SPACE=1`) |
| create-named.png | `--create-space "Reading list"` | review/w9f-mac create-named.png |
| create-filled.png | `--create-space "Reading list" --create-space-theme 4` | review/w9f-mac create-filled.png (`_THEME=4`) |

`before/` holds the same captures from main at 577062a. `crops/` sets each before/after pair beside the Mac.

All measurements are in window points. Ink is counted where luminance differs from the local background by more than 18–40. A centre is the ink-weighted mean. Text is set in Segoe UI on Windows and SF Pro on the Mac, so text widths differ by about 5% at the same size. Baselines are compared instead, and they match (within 0.5pt). The one exception is the focused name field, which is covered below.

## Drift found and fixed

| what | Mac | Windows before | Windows after |
|---|---|---|---|
| Picker scale in a 2× capture | 33.5pt emoji cells | half size (drawn at its 1× monitor's scale) | 33.5pt cells |
| Grid emoji ink | 21×21, area ≈330 | 25×25, area ≈470 | 21×21, area ≈340 |
| Category bar and bin symbols (lightbulb, heart, flag, trash) | e.g. heart 12×12.5, area 39.5 | 1.3× the Mac's | heart 13.5×13, area 38 |
| NSPopover arrow (window = content + 13pt a side) | tabs 25pt under the tip; divider at 420 | 23pt; 418 | 25pt; 420 |
| Search field bezel | 234–254 | 231–253 | 234–254 |
| Popover appearance (picker, swatches) | dark over Work's light theme (NSApp's appearance) | the space's theme (light) | Kite's appearance (dark) |
| Choose a Theme swatches | purple swatch at x 328.3 | 324.3 (9pt arrow) | 328.3 |
| Disabled Create Space | fill (33,41,85), title peak 48.7 | fill (34,49,138), title 91.6 | fill (30,37,82), title 45.4 |
| Unfocused placeholder (What's it for?) | contrast 87 (dark), 105 (light) | 52, 63 | 88, 103 |
| Choose a Theme brush | area 72, weight 30–34 (filled) | area 59, weight 23 (outline) | area 71, weight 30–31 (bold) |

## Still different (documented in docs/windows.md)

- **Profile's face.smiling in a dark space.** The Mac's capture inks it filled (area 176, against 87). Its code asks for the outline, which it inks in the light space (80 against 87). Windows keeps the outline.
- **Mac in-process capture limits.** The Mac's capture draws the popover's material as a plain rectangle, so the arrow's width, the corners and the body's edges couldn't be measured.
- **Picker position.** The Mac's picker hangs centred under the icon, past the window's left edge, so its capture is cut off. Windows keeps it inside the window, as before.
- **Scroller shift.** The Mac runner has a mouse and no trackpad, so it shows a legacy scroller, which moves the Mac's grid 7.5pt left.
- **Icon tab glyphs.** The Segoe stand-ins ink within about 15% of SF's, glyph by glyph (mean area ratio 0.96). No single factor fits.
- **Emoji vertical position.** Grid emoji sit 0.7–1.1pt lower than the Mac's.
- **Focused name field baseline.** Its text sits 1pt lower than the Mac's while the field is focused. The Mac's own baseline moves by 1pt between its captures (260 in create-named, 261 in create-filled), so this wasn't changed.
- **Theme editor contents.** The Mac's popover is the whole theme editor. Windows' holds only its preset row (known difference), and that row matches.
