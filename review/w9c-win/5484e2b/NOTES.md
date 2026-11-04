# W9c PC gate at 5484e2b (final head of #315)

Gabe's PC, MSVC (Visual Studio 18 2026 generator), with CEF in windows/ThirdParty/cef. The build was `--clean-first` in both configs.

## Build and tests
- Release and Debug both build with **0 warnings and 0 errors** (/W4 /WX). All 63 sources were recompiled in each config.
- `ctest -C Release` and `ctest -C Debug` both pass **2/2** (KiteCoreTests, kitecore-cli). `KiteCoreTests.exe` itself prints `248 tests, 0 failed checks` in both configs.

## Smoke
- CI's steps on a fresh profile: `kitecore open <smoke.html>`, then `Kite.exe --smoke-test` exits **0**. `Chromium\Default` exists afterwards, and the selected tab is "Kite smoke page visible". `--capture` with no path exits 1. A file as `KITE_SUPPORT_PATH` exits 2. No `KITE_SUPPORT_PATH` exits 1.
- CI's profile has one space, so the four synthetic touchpad swipes in `SmokeTestSwipe` don't run there. With `two-spaces.json` plus the smoke page, `--smoke-test` exits **0** in both Release and Debug (Release also ran with `--frame-log`).
- `kitecore space swipe` results:
  - From Personal:
    - -150 lands on Work (landing 1, offset -150).
    - -150 again rubber-bands past the end and stays (offset -61.40).
    - 30 over 1 s stays (offset 30).
    - 150 lands back on Personal (landing -1).
    - -120 releases at offset -120, progress 0.5.
  - From Work, -100 past the end gives offset **-44.746 pt**. The Mac's figure is 44.75 pt.
  - `space swipe 0` exits 0 with no swipe, while `Kite.exe --swipe 0` refuses 0. `-10001` is accepted, while Kite.exe's range is ±10000. Neither matters for the gate.

## Captures (Release, fresh profiles, `--window-size 1280,820 --capture-scale 2`)
`two-spaces.json` was the session, with `selectedSpaceID` set as listed. `--swipe` is positive towards the previous space, so `-120` is the Mac's `dx +120` towards Work.

| File | State |
|---|---|
| rest.png | Personal, no swipe |
| swipe-next-120.png | Personal, `--swipe -120` |
| swipe-past-end-100.png | Work (the last space), `--swipe -100` |
| rest-work.png | Work, no swipe |

**All four are byte-identical to round 1's** (equal SHA-256, 0 differing pixels). The two swipe PNGs are therefore also identical to c62c9b9's.

Measured again here, by edge-correlating each swiped capture against the rest capture of the same space (2x px):
- swipe-next-120:
  - Personal's page is at **-240 px (-120 pt)**, and Work's at **+240 px (+120 pt)** from its own rest place.
  - The Mac's frames are [-112, ...] and [128, ...] in window points: the same 120 pt shift from 8 and 248.
- swipe-past-end-100:
  - Every inked row of the Work page is at **-89 px (-44.5 pt)**.
  - The model says -44.746 pt (the Mac's 44.75 pt). On screen that becomes 89.49 px, snapped to whole pixels. The address field and the bar don't move.

## 5484e2b's polling changes
- No real touchpad input was used. Synthetic precision-touchpad input doesn't exist, so `DM_POINTERHITTEST` never came. `TouchpadInput::HitTest` refuses any pointer that isn't `PT_TOUCHPAD`. As a result, **no `{"dm":"contact"}` or `{"dm":"poll"}` record was produced, and the resting-finger path (unboosted `Start(false)`, the 10 s `kLongestRest` cap, and dropping a lifted contact in `Update`) is unverified at run time.**
- Frame logs from every run hold only DirectManipulation's two startup reports: status 0→1 (BUILDING→ENABLED) and 1→5 (ENABLED→READY, per the SDK's enum).
  - A normal window, open about 15 s on two spaces with no input: **0 frames**. No contact or poll record, so the clock never ran.
  - The two-spaces smoke with `--frame-log`: **0 frames** after the swipe smoke cleared its frames, up to the close. The clock stopped once the swipes settled.
- Idle CPU in that normal window, measured from 5 to 15 s after launch: main Kite.exe **0.031 s CPU in 10.03 s (0.31% of one core)**. Its 6 Kite.exe processes, CEF's included, used 0.078 s in all.
- Not measured: CPU after a swipe in a long-lived window. A swipe can only come from the smoke test, and the smoke run closes about 2 s after launch, as soon as its page reports loaded.
