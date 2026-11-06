# W-text-weight, review round 1: Windows captures at 22c6ad6

Same recipe, states and metric as `../43df747/NOTES.md` (`before/` there is still main at 3895196). Only crops of the screens
this round changed are here. The full captures stay local.

- `crops/create-space-mac-before-after.png`: Mac | main | 22c6ad6. The title is in Segoe UI Black.
- `crops/create-space-windows10-before-after.png`, `crops/sidebar-windows10-before-after.png`: main | 22c6ad6 `--static-font`.
  Windows 10 keeps today's weights, so these differ from main only where main's views set their own weights.
- `crops/tip-before-after.png`: main | 22c6ad6 | 22c6ad6 `--static-font`. `crops/tip-mac.png` is the Mac's panel.

## Hierarchy (ink per pt² of the ink box, the first element over the second)

| density ratio | Mac | before | after | Windows 10 face |
|---|---|---|---|---|
| title / "Choose a Theme" | 1.06 | 1.06 | **1.05** | 1.10 |
| title / subtitle | 1.64 | 1.81 | **1.68** | 1.80 |
| "Choose a Theme" / "Reading list" | 1.20 | 1.46 | **1.38** | 1.41 |
| folder "Reading" / tab "Example Domain" | 1.40 | 1.49 | **1.37** | 1.51 |
| folder "Work stuff" / tab "Docs" | 1.10 | 1.19 | **1.09** | 1.21 |
| history title (medium) / URL field (regular) | 1.79 | 1.64 | **1.74** | 1.83 |
| header (semibold) / URL field (regular) | 1.36 | 1.44 | **1.41** | 1.45 |

Space tip key "1" (Mac bold 12, now Segoe UI Black on Windows 11): ink 1.19 of the Mac's (main 0.91, Windows 10 face 0.93), on a
10 pt² glyph.

## Other scripts' faces at 13pt (what `SystemFontTests` checks against a plain format at the Mac's weight)

```
== Windows 11 face
Japanese: | regular Yu Gothic UI 400 | medium Yu Gothic UI 600 | semibold Yu Gothic UI 600 | bold Yu Gothic UI 700
Korean: | regular Malgun Gothic 400 | medium Malgun Gothic 400 | semibold Malgun Gothic 700 | bold Malgun Gothic 700
Thai: | regular Leelawadee UI 400 | medium Leelawadee UI 400 | semibold Leelawadee UI 700 | bold Leelawadee UI 700
Hindi: | regular Nirmala UI 400 | medium Nirmala UI 400 | semibold Nirmala UI 700 | bold Nirmala UI 700
Arabic: | regular Segoe UI 400 | medium Segoe UI 600 | semibold Segoe UI 600 | bold Segoe UI 700
== Windows 10 face
Japanese: | regular Yu Gothic UI 400 | medium Yu Gothic UI 600 | semibold Yu Gothic UI 600 | bold Yu Gothic UI 700
Korean: | regular Malgun Gothic 400 | medium Malgun Gothic 400 | semibold Malgun Gothic 700 | bold Malgun Gothic 700
Thai: | regular Leelawadee UI 400 | medium Leelawadee UI 400 | semibold Leelawadee UI 700 | bold Leelawadee UI 700
Hindi: | regular Nirmala UI 400 | medium Nirmala UI 400 | semibold Nirmala UI 700 | bold Nirmala UI 700
Arabic: | regular Segoe UI 400 | medium Segoe UI 600 | semibold Segoe UI 600 | bold Segoe UI 700
```

At 62c14159 a regular label drew these in Yu Gothic UI 600 and in Malgun Gothic, Leelawadee UI and Nirmala UI 700. The test fails
there.

## Every element

| screen (Mac ref) | element | Mac weight | Mac ink / width (pt) | Windows before: ink, width | Windows after: ink, width | Windows 10 face (`--static-font`): ink, width |
|---|---|---|---|---|---|---|
| w9d-rest | URL field "example.com" | 13 regular | 103.9 / 79.0 | 0.79, 0.943 | **0.99, 0.981** | 0.78, 0.943 |
| w12-rest | URL field "example.com" | 13 regular | 103.9 / 79.0 | 0.79, 0.943 | **0.99, 0.981** | 0.78, 0.943 |
| w9e-rest | URL field "example.com" | 13 regular | 103.9 / 79.0 | 0.79, 0.943 | **0.99, 0.981** | 0.78, 0.943 |
| w9f-rest | URL field "example.com" | 13 regular | 103.9 / 79.0 | 0.79, 0.943 | **0.99, 0.981** | 0.78, 0.943 |
| w9d-rest | Personal header | 13 semibold | 76.1 / 53.0 | 0.76, 0.906 | **0.92, 0.934** | 0.76, 0.915 |
| w9d-rest | Docs tab | 14 regular | 78.8 / 31.5 | 0.73, 0.921 | **0.94, 0.937** | 0.72, 0.921 |
| w9d-rest | Work stuff folder | 14 semibold | 202.1 / 70.0 | 0.82, 0.957 | **0.98, 0.993** | 0.82, 0.957 |
| w9d-rest | New Tab | 14 regular | 97.9 / 54.5 | 0.80, 0.945 | **1.01, 0.972** | 0.79, 0.945 |
| w9d-new-space | Projects header | 13 semibold | 72.3 / 50.5 | 0.76, 0.901 | **0.93, 0.931** | 0.76, 0.901 |
| w9d-new-space | New Tab | 14 regular | 97.1 / 54.5 | 0.81, 0.945 | **1.02, 0.972** | 0.79, 0.945 |
| w9d-rename | Done | 12 semibold | 53.7 / 29.5 | 0.80, 0.949 | **0.95, 0.966** | 0.80, 0.949 |
| w9b-sidebar | Personal header | 13 semibold | 75.5 / 53.0 | 0.76, 0.906 | **0.93, 0.934** | 0.77, 0.915 |
| w9b-sidebar | Docs tab | 14 regular | 78.1 / 31.5 | 0.74, 0.921 | **0.95, 0.937** | 0.72, 0.921 |
| w9b-sidebar | Work stuff folder | 14 semibold | 200.2 / 70.0 | 0.83, 0.957 | **0.99, 0.993** | 0.83, 0.957 |
| w9c-rest | Personal header | 13 semibold | 76.1 / 53.0 | 0.76, 0.906 | **0.92, 0.934** | 0.76, 0.915 |
| w9c-rest | Work stuff folder | 14 semibold | 202.1 / 70.0 | 0.82, 0.957 | **0.98, 0.993** | 0.82, 0.957 |
| w13-four | Docs tab | 14 regular | 78.8 / 31.5 | 0.73, 0.921 | **0.94, 0.937** | 0.72, 0.921 |
| w13-four | New Tab | 14 regular | 97.9 / 54.5 | 0.80, 0.945 | **1.01, 0.972** | 0.79, 0.945 |
| w14-folders | "Drag to add Favorites" | 12 semibold | 244.5 / 124.5 | 0.79, 0.936 | **0.94, 0.960** | 0.79, 0.928 |
| w14-folders | Favorites subtitle, line 1 | 11 regular | 168.4 / 186.5 | 0.75, 0.917 | **0.98, 0.968** | 0.75, 0.917 |
| w14-folders | Favorites subtitle, line 2 | 11 regular | 73.4 / 78.0 | 0.75, 0.917 | **0.96, 0.962** | 0.74, 0.910 |
| w14-folders | Example Domain tab | 14 regular | 256.6 / 105.5 | 0.77, 0.967 | **0.99, 1.000** | 0.76, 0.967 |
| w14-folders | Reading folder | 14 semibold | 180.1 / 53.0 | 0.79, 0.934 | **0.95, 0.972** | 0.79, 0.934 |
| w14-folders | Elsewhere (nested) | 14 regular | 164.4 / 64.5 | 0.74, 0.930 | **0.96, 0.961** | 0.74, 0.930 |
| w14-folders | Old articles (nested folder) | 14 semibold | 224.1 / 76.0 | 0.77, 0.928 | **0.93, 0.954** | 0.78, 0.934 |
| w17-tab-rest | Elsewhere tab | 14 regular | 163.9 / 64.5 | 0.74, 0.930 | **0.96, 0.961** | 0.73, 0.930 |
| w17-tab-rest | Example Domain (Today) | 14 regular | 257.0 / 105.5 | 0.77, 0.967 | **1.00, 1.000** | 0.76, 0.967 |
| w13-light-selected | Personal header (light) | 13 semibold | 59.5 / 53.0 | 0.77, 0.906 | **0.95, 0.934** | 0.77, 0.915 |
| w13-light-selected | Docs tab (light) | 14 regular | 61.3 / 31.5 | 0.74, 0.921 | **0.97, 0.937** | 0.72, 0.921 |
| w13-light-selected | Work stuff folder (light) | 14 semibold | 162.4 / 70.0 | 0.82, 0.957 | **1.01, 0.993** | 0.82, 0.957 |
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
| w9b3-tip-Personal | name "Personal" | 13 semibold | 207.2 / 53.0 | 0.92, 0.943 | **0.88, 0.934** | 0.73, 0.915 |
| w9b3-tip-Personal | profile chip "Default" | 13 semibold | 102.1 / 44.5 | 1.03, 0.989 | **0.97, 0.978** | 0.80, 0.944 |
| w9f-create-named | title "Create a Space" | 17 bold | 525.4 / 122.0 | 0.84, 0.951 | **1.01, 0.988** | 0.84, 0.951 |
| w9f-create-named | subtitle, line 1 | 14 regular | 376.6 / 169.5 | 0.76, 0.950 | **0.98, 0.985** | 0.76, 0.947 |
| w9f-create-named | subtitle, line 2 | 14 regular | 341.7 / 163.0 | 0.76, 0.951 | **0.98, 0.982** | 0.75, 0.951 |
| w9f-create-named | name "Reading list" | 15 regular | 239.4 / 78.0 | 0.73, 0.968 | **0.93, 1.000** | 0.72, 0.968 |
| w9f-create-named | "Profile" | 15 semibold | 159.3 / 45.0 | 0.80, 0.956 | **0.97, 1.000** | 0.81, 0.944 |
| w9f-create-named | "Choose a Theme" | 15 semibold | 361.7 / 118.5 | 0.77, 0.945 | **0.92, 0.962** | 0.77, 0.945 |
| w9f-create-named | "Create Space" button | 13 semibold | 315.2 / 95.0 | 0.73, 0.921 | **0.87, 0.942** | 0.73, 0.916 |
| w9f-create-named | "Cancel" | 13 medium | 83.4 / 41.0 | 0.71, 0.915 | **0.92, 0.939** | 0.80, 0.915 |

| Mac weight | n | before: ink, width | after: ink, width | Windows 10 face: ink, width |
|---|---|---|---|---|
| regular | 23 | 0.73–0.81, 0.917–0.988 | **0.93–1.02, 0.937–1.023** | 0.72–0.79, 0.910–0.988 |
| medium | 8 | 0.70–0.72, 0.907–0.950 | **0.89–0.94, 0.939–0.990** | 0.78–0.82, 0.915–0.960 |
| semibold | 18 | 0.73–1.03, 0.901–0.989 | **0.87–1.01, 0.931–1.000** | 0.73–0.83, 0.901–0.957 |
| bold | 1 | 0.84–0.84, 0.951–0.951 | **1.01–1.01, 0.988–0.988** | 0.84–0.84, 0.951–0.951 |
