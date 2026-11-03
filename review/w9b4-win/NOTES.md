# W9b4 Windows captures (511361d; first round f742629)

The build is 511361d (round 2; round 1 was f742629): MSVC /WX, Release, with CL unset, so plain /WX and 0 warnings. All PNGs come from this build.

Each run is `Kite.exe --capture --window-size 1280,820 --capture-scale 2` with a fresh temp profile. It starts from `windows/helix/states/sidebar.json`, with space 2's `symbol:briefcase` replaced by `symbol:<name>`.

- `<name>-spacebar-selected.png`: window points [0,770 240x50], with space 2 (Work) selected.
- `<name>-spacebar-unselected.png`: the same crop with space 1 selected, so space 2 is greyed.
- `<name>-header.png`: the header's icon slot, window points **[13,87 26x26]**, centred at (26,100), with space 2 selected. The Windows header row sits at y 87, where the Mac's is at y 162.
- `theatermasks.fill-header-wide.png`: window points [0,75 60x50], the Windows equivalent of the Mac's [0,150 60x50].
- `sheet.png`: an overview with lit, greyed and header for each symbol.

The space 2 cell (kitecore) is [119,778 36x34], centred at (137,795), for every symbol.

