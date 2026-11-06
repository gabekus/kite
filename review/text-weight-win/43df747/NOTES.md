# W-text-weight: Windows captures against every Mac reference

`before/`: Release of origin/main 3895196. `after/`: Release of helix/W-text-weight 43df747. `static/`: the same build with
`--static-font` (Windows 10's face, Segoe UI's named weights), six of the screens. `crops/`: Mac | before | after, at 2x.

Each is `Kite.exe --capture NAME.png --window-size 1280,820 --capture-scale 2` on a fresh `KITE_SUPPORT_PATH` (`KITE_DIAGNOSTICS=1`)
with the Mac state's session (its request.json's `session`, from the same ref, or main's copy where the ref is gone) and the
capture flag that holds the same state: `--space-tip 1` (w9b3), `--rename-space 1` (w9d rename), `--command-bar recipe` with
the state's history.json (w25a), `--find domain --find-result 1/2` / `--find ""` / `--find zqxj --find-result 0/0` (w21),
`--icon-picker 1,emoji` / `2,icon` (w9e), `--create-space "" | "Reading list" [--create-space-theme 4]` (w9f). w9c's rest
selects Personal, as the Mac's did. File names are `<mac ref>-<state>.png`.

Measured with the UI gate reviewer's metric (`ink.py`: luminance more than 30 from the box's background; ink = the sum of
min(d, 255)/255 in pt² at 2x; width = the ink box's), each line found automatically in a box around it, the command bar's title and
subtitle split at the em dash. Ratios are Windows / Mac. Every Mac reference branch is covered: review/w9b4-mac has no text (symbol
renders only); the states not in the table (drags, swipes, the pickers, loading, the other favorites counts) draw the same labels
at the same weights as the ones measured, and are captured here.

| screen (Mac ref) | element | Mac weight | Mac ink / width (pt) | Windows before: ink, width | Windows after: ink, width | Windows 10 face (`--static-font`): ink, width |
|---|---|---|---|---|---|---|
| w9d-rest | URL field "example.com" | 13 regular | 103.9 / 79.0 | 0.79, 0.943 | **0.99, 0.981** | 0.78, 0.943 |
| w12-rest | URL field "example.com" | 13 regular | 103.9 / 79.0 | 0.79, 0.943 | **0.99, 0.981** | 0.78, 0.943 |
| w9e-rest | URL field "example.com" | 13 regular | 103.9 / 79.0 | 0.79, 0.943 | **0.99, 0.981** | 0.78, 0.943 |
| w9f-rest | URL field "example.com" | 13 regular | 103.9 / 79.0 | 0.79, 0.943 | **0.99, 0.981** | 0.78, 0.943 |
| w9d-rest | Personal header | 13 semibold | 76.1 / 53.0 | 0.76, 0.906 | **0.92, 0.934** | 0.96, 0.953 |
| w9d-rest | Docs tab | 14 regular | 78.8 / 31.5 | 0.73, 0.921 | **0.94, 0.937** | 0.72, 0.921 |
| w9d-rest | Work stuff folder | 14 semibold | 202.1 / 70.0 | 0.82, 0.957 | **0.98, 0.993** | 1.04, 1.007 |
| w9d-rest | New Tab | 14 regular | 97.9 / 54.5 | 0.80, 0.945 | **1.01, 0.972** | 0.79, 0.945 |
| w9d-new-space | Projects header | 13 semibold | 72.3 / 50.5 | 0.76, 0.901 | **0.93, 0.931** | 0.98, 0.941 |
| w9d-new-space | New Tab | 14 regular | 97.1 / 54.5 | 0.81, 0.945 | **1.02, 0.972** | 0.79, 0.945 |
| w9d-rename | Done | 12 semibold | 53.7 / 29.5 | 0.80, 0.949 | **0.95, 0.966** | 0.99, 0.983 |
| w9b-sidebar | Personal header | 13 semibold | 75.5 / 53.0 | 0.76, 0.906 | **0.93, 0.934** | 0.97, 0.953 |
| w9b-sidebar | Docs tab | 14 regular | 78.1 / 31.5 | 0.74, 0.921 | **0.95, 0.937** | 0.72, 0.921 |
| w9b-sidebar | Work stuff folder | 14 semibold | 200.2 / 70.0 | 0.83, 0.957 | **0.99, 0.993** | 1.05, 1.007 |
| w9c-rest | Personal header | 13 semibold | 76.1 / 53.0 | 0.76, 0.906 | **0.92, 0.934** | 0.96, 0.953 |
| w9c-rest | Work stuff folder | 14 semibold | 202.1 / 70.0 | 0.82, 0.957 | **0.98, 0.993** | 1.04, 1.007 |
| w13-four | Docs tab | 14 regular | 78.8 / 31.5 | 0.73, 0.921 | **0.94, 0.937** | 0.72, 0.921 |
| w13-four | New Tab | 14 regular | 97.9 / 54.5 | 0.80, 0.945 | **1.01, 0.972** | 0.79, 0.945 |
| w14-folders | "Drag to add Favorites" | 12 semibold | 244.5 / 124.5 | 0.79, 0.936 | **0.94, 0.960** | 0.99, 0.968 |
| w14-folders | Favorites subtitle, line 1 | 11 regular | 168.4 / 186.5 | 0.75, 0.917 | **0.98, 0.968** | 0.75, 0.917 |
| w14-folders | Favorites subtitle, line 2 | 11 regular | 73.4 / 78.0 | 0.75, 0.917 | **0.96, 0.962** | 0.74, 0.910 |
| w14-folders | Example Domain tab | 14 regular | 256.6 / 105.5 | 0.77, 0.967 | **0.99, 1.000** | 0.76, 0.967 |
| w14-folders | Reading folder | 14 semibold | 180.1 / 53.0 | 0.79, 0.934 | **0.95, 0.972** | 0.98, 0.981 |
| w14-folders | Elsewhere (nested) | 14 regular | 164.4 / 64.5 | 0.74, 0.930 | **0.96, 0.961** | 0.74, 0.930 |
| w14-folders | Old articles (nested folder) | 14 semibold | 224.1 / 76.0 | 0.77, 0.928 | **0.93, 0.954** | 0.98, 0.974 |
| w17-tab-rest | Elsewhere tab | 14 regular | 163.9 / 64.5 | 0.74, 0.930 | **0.96, 0.961** | 0.73, 0.930 |
| w17-tab-rest | Example Domain (Today) | 14 regular | 257.0 / 105.5 | 0.77, 0.967 | **1.00, 1.000** | 0.76, 0.967 |
| w13-light-selected | Personal header (light) | 13 semibold | 59.5 / 53.0 | 0.77, 0.906 | **0.95, 0.934** | 0.99, 0.953 |
| w13-light-selected | Docs tab (light) | 14 regular | 61.3 / 31.5 | 0.74, 0.921 | **0.97, 0.937** | 0.72, 0.921 |
| w13-light-selected | Work stuff folder (light) | 14 semibold | 162.4 / 70.0 | 0.82, 0.957 | **1.01, 0.993** | 1.07, 1.007 |
| w13-light-selected | New Tab (light) | 14 regular | 76.1 / 54.5 | 0.79, 0.945 | **1.02, 0.972** | 0.77, 0.945 |
| w25a-command-bar-history | typed query "recipe" | 18 medium | 219.3 / 50.0 | 0.70, 0.950 | **0.91, 0.990** | 0.78, 0.960 |
| w25a-command-bar-history | selected row "recipe" | 13 medium | 93.4 / 37.5 | 0.71, 0.907 | **0.91, 0.960** | 0.79, 0.920 |
| w25a-command-bar-history | "Search DuckDuckGo" | 13 medium | 242.3 / 126.5 | 0.72, 0.925 | **0.93, 0.957** | 0.82, 0.933 |
| w25a-command-bar-history | history title | 13 medium | 360.8 / 147.0 | 0.70, 0.918 | **0.89, 0.949** | 0.79, 0.932 |
| w25a-command-bar-history | history subtitle | 13 medium | 293.0 / 207.0 | 0.71, 0.925 | **0.91, 0.959** | 0.80, 0.937 |
| w25a-command-bar-history | "recipes.example" | 13 medium | 248.0 / 100.5 | 0.70, 0.910 | **0.90, 0.955** | 0.78, 0.925 |
| w25a-command-bar-history | history title, row 4 | 13 medium | 496.9 / 202.5 | 0.72, 0.936 | **0.94, 0.973** | 0.82, 0.956 |
| w21-find-matches | find field "domain" | 13 regular | 114.8 / 43.0 | 0.79, 0.988 | **1.00, 1.023** | 0.78, 0.988 |
| w21-find-empty | placeholder "Find in page…" | 13 regular | 110.3 / 82.5 | 0.75, 0.945 | **0.96, 0.988** | 0.75, 0.952 |
| w9b3-tip-Personal | name "Personal" | 13 semibold | 207.2 / 53.0 | 0.92, 0.943 | **0.88, 0.934** | 0.92, 0.953 |
| w9b3-tip-Personal | profile chip "Default" | 13 semibold | 102.1 / 44.5 | 1.03, 0.989 | **0.97, 0.978** | 1.01, 0.989 |
| w9f-create-named | title "Create a Space" | 17 bold | 525.4 / 122.0 | 0.84, 0.951 | **0.86, 1.008** | 1.01, 0.988 |
| w9f-create-named | subtitle, line 1 | 14 regular | 376.6 / 169.5 | 0.76, 0.950 | **0.98, 0.985** | 0.76, 0.947 |
| w9f-create-named | subtitle, line 2 | 14 regular | 341.7 / 163.0 | 0.76, 0.951 | **0.98, 0.982** | 0.75, 0.951 |
| w9f-create-named | name "Reading list" | 15 regular | 239.4 / 78.0 | 0.73, 0.968 | **0.93, 1.000** | 0.72, 0.968 |
| w9f-create-named | "Profile" | 15 semibold | 159.3 / 45.0 | 0.80, 0.956 | **0.97, 1.000** | 1.02, 1.000 |
| w9f-create-named | "Choose a Theme" | 15 semibold | 361.7 / 118.5 | 0.77, 0.945 | **0.92, 0.962** | 0.96, 0.970 |
| w9f-create-named | "Create Space" button | 13 semibold | 315.2 / 95.0 | 0.73, 0.921 | **0.87, 0.942** | 0.91, 0.947 |
| w9f-create-named | "Cancel" | 13 medium | 83.4 / 41.0 | 0.71, 0.915 | **0.92, 0.939** | 0.80, 0.915 |

| Mac weight | n | before: ink, width | after: ink, width | Windows 10 face: ink, width |
|---|---|---|---|---|
| regular | 23 | 0.73–0.81, 0.917–0.988 | **0.93–1.02, 0.937–1.023** | 0.72–0.79, 0.910–0.988 |
| medium | 8 | 0.70–0.72, 0.907–0.950 | **0.89–0.94, 0.939–0.990** | 0.78–0.82, 0.915–0.960 |
| semibold | 18 | 0.73–1.03, 0.901–0.989 | **0.87–1.01, 0.931–1.000** | 0.91–1.07, 0.941–1.007 |
| bold | 1 | 0.84–0.84, 0.951–0.951 | **0.86–0.86, 1.008–1.008** | 1.01–1.01, 0.988–0.988 |
