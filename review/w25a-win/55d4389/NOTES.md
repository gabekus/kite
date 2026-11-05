# W25a Windows capture at 55d4389

`command-bar-history.png`: `Kite.exe --capture command-bar-history.png --window-size 1280,820 --capture-scale 2 --command-bar recipe`
(Release, 55d4389), on a fresh `KITE_SUPPORT_PATH` with `windows/helix/states/command-bar-history.json` as `session.json` and
`windows/helix/states/command-bar-history.history.json` as `history.json`. 2560×1640.

After the labelColor fix. Against the Mac's reference (review/w25a-mac 4f34cf6), brightest pixel over the background
(mean of R, G, B), Mac / Windows before / Windows now:

| | Mac | Windows before (9ed5d0d) | Windows now |
|---|---|---|---|
| field text "recipe" | 219 on 19 (85%) | 255 on 24 (100%) | 220 on 24 (85%) |
| history row title | 179 on 19 (68%) | 209 on 24 (80%) | 181 on 24 (68%) |
| history row subtitle | 113 on 19 (40%) | 117 on 24 (40%) | 117 on 24 (40%) |
| globe (no favicon) | 139 on 19 (51%) | 162 on 24 (60%) | 141 on 24 (51%) |
| arrow | 164 on 29 (60%) | 189 on 34 (70%) | 165 on 34 (59%) |

The backgrounds differ (19 against 24): the Mac's capture draws its blurred material, Windows the solid fallback
(docs/helix.md, UI match). Not for merge.
