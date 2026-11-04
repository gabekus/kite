# W9d Windows rename capture at e400a9a

Only `rename.png` is recaptured here: the same recipe as `review/w9d-win/NOTES.md` (Release build of
`helix/W9d-space-editing` e400a9a, a fresh `KITE_SUPPORT_PATH` profile with `windows/helix/states/three-spaces.json`,
`--window-size 1280,820 --capture-scale 2 --rename-space 1`). The other five states are unchanged from `../b5b5870/`.

The editor's background now spans x 76–395 in 2× px, 160pt as on the Mac. It runs 3pt before the field and 1pt past
its end. The field's frame ends where the Mac's does, 2pt before Done's frame: 197pt (394 px) on both.

At b5b5870 the background stopped at the field's end (393). That was the 1pt shortfall, not a font effect. Done's ink
starting 2 px later on Windows (400 vs 398) is Segoe's left bearing inside the same frame.
