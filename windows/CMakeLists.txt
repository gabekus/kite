# Kite for Windows: native C++20 on Win32. See docs/windows.md.
#
#   cmake -S windows -B windows/build -A x64      (newest Visual Studio)
#   cmake --build windows/build --config Release
#   ctest --test-dir windows/build -C Release
#
# Off Windows the model and its tests build natively (`cmake -S windows -B /tmp/kite-core`),
# and windows/cmake/mingw-w64.cmake cross-compiles the whole app.
cmake_minimum_required(VERSION 3.24)
project(Kite LANGUAGES CXX)
if(WIN32)
  enable_language(RC)  # resources/Kite.rc: the app icon (and MinGW's manifest)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(MSVC)
  # Static CRT, matching CEF's libcef_dll_wrapper, so Kite.exe needs no VC++ redistributable.
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  add_compile_options(/W4 /WX /permissive- /utf-8 /Zc:__cplusplus)
else()
  # No fused multiply-adds: the theme backdrop's grain hash ends in a fract() of values near
  # 1e4, so contracting it (clang's default, and every arm64 build) moves the reference off
  # the golden fixture the Mac shares. MSVC doesn't contract without /fp:contract.
  # KITE_WERROR=OFF is for the sanitizer build: -Werror from here comes after CMAKE_CXX_FLAGS,
  # so a -Wno-error there can't undo it, and the plain build already gates warnings.
  option(KITE_WERROR "Treat warnings as errors" ON)
  add_compile_options(-Wall -Wextra -ffp-contract=off $<$<BOOL:${KITE_WERROR}>:-Werror>)
endif()
if(WIN32)
  add_compile_definitions(UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0A00)
endif()

# The model (the Windows counterpart of KiteCore): standard C++ only, unit-tested headless.
add_library(KiteCoreWin STATIC
  src/core/AirTrafficControl.cpp
  src/core/ArcHistoryImport.cpp
  src/core/ArcImport.cpp
  src/core/ArcImportController.cpp
  src/core/ArcImportFiles.cpp
  src/core/ColorSpaces.cpp
  src/core/CommandBar.cpp
  src/core/CommandLine.cpp
  src/core/Favorites.cpp
  src/core/Files.cpp
  src/core/History.cpp
  src/core/HistoryStore.cpp
  src/core/Json.cpp
  src/core/KeyBindings.cpp
  src/core/Models.cpp
  src/core/OKLab.cpp
  src/core/OneShotFlags.cpp
  src/core/SessionBackups.cpp
  src/core/SessionSaveDelay.cpp
  src/core/SessionStore.cpp
  src/core/SessionWriter.cpp
  src/core/StoreFile.cpp
  src/core/SpaceBar.cpp
  src/core/SpaceEditing.cpp
  src/core/SpaceIcon.cpp
  src/core/SymbolShape.cpp
  src/core/TextMatch.cpp
  src/core/PictureLoads.cpp
  src/core/Plist.cpp
  src/core/Profiles.cpp
  src/core/SiteSearch.cpp
  src/core/SQLiteReader.cpp
  src/core/SpaceSwipe.cpp
  src/core/SpaceSwipeGesture.cpp
  src/core/TouchpadPhases.cpp
  src/core/LiveTabPolicy.cpp
  src/core/Sidebar.cpp
  src/core/SidebarTopRow.cpp
  src/core/TabClosing.cpp
  src/core/SupportDirectory.cpp
  src/core/ThemeBackdrop.cpp
  src/core/TitleBar.cpp
  src/core/Unicode.cpp
  src/core/URLInput.cpp
  src/core/Url.cpp
  src/core/Uuid.cpp
  src/core/WorkerThread.cpp
)
target_include_directories(KiteCoreWin PUBLIC src)
# SessionWriter's worker is a std::thread (pthreads off Windows).
find_package(Threads REQUIRED)
target_link_libraries(KiteCoreWin PUBLIC Threads::Threads)
if(MSVC)
  # Control Flow Guard: the model is linked into Kite.dll, which every sandboxed helper maps.
  target_compile_options(KiteCoreWin PRIVATE /guard:cf)
endif()

# Headless model CLI (the behaviour gate in docs/helix.md).
add_executable(kitecore src/cli/main.cpp)
target_link_libraries(kitecore PRIVATE KiteCoreWin)

if(WIN32)
  # HLSL shaders (src/shell/shaders). MSVC builds compile them with the Windows SDK's fxc
  # at build time and embed the bytecode, so Kite.exe never compiles a shader at startup.
  # /Gis keeps IEEE float rules (no reassociating the grain hash); /WX fails on any warning.
  # Where there's no fxc (the MinGW cross-compile check) the source is embedded instead and
  # compiled with D3DCompile at startup (KITE_RUNTIME_SHADERS).
  set(KITE_SHADER_DIR "${CMAKE_CURRENT_BINARY_DIR}/shaders")
  file(MAKE_DIRECTORY "${KITE_SHADER_DIR}")
  set(KITE_FXC_HINTS)
  set(KITE_PROGRAM_FILES_X86 "ProgramFiles(x86)")
  if(CMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION)
    list(APPEND KITE_FXC_HINTS "$ENV{${KITE_PROGRAM_FILES_X86}}/Windows Kits/10/bin/${CMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION}/x64")
  endif()
  find_program(KITE_FXC fxc HINTS ${KITE_FXC_HINTS} "$ENV{WindowsSdkVerBinPath}/x64")
  set(KITE_THEME_HLSL "${CMAKE_CURRENT_SOURCE_DIR}/src/shell/shaders/Theme.hlsl")
  if(KITE_FXC)
    set(KITE_SHADER_HEADERS "${KITE_SHADER_DIR}/FullscreenVertex.h" "${KITE_SHADER_DIR}/ThemePixel.h")
    add_custom_command(OUTPUT "${KITE_SHADER_DIR}/FullscreenVertex.h"
      COMMAND "${KITE_FXC}" /nologo /T vs_4_0 /E FullscreenVertex /O3 /Gis /WX /Vn kFullscreenVertexShader
              /Fh "${KITE_SHADER_DIR}/FullscreenVertex.h" "${KITE_THEME_HLSL}"
      DEPENDS "${KITE_THEME_HLSL}" VERBATIM)
    add_custom_command(OUTPUT "${KITE_SHADER_DIR}/ThemePixel.h"
      COMMAND "${KITE_FXC}" /nologo /T ps_4_0 /E ThemePixel /O3 /Gis /WX /Vn kThemePixelShader
              /Fh "${KITE_SHADER_DIR}/ThemePixel.h" "${KITE_THEME_HLSL}"
      DEPENDS "${KITE_THEME_HLSL}" VERBATIM)
  elseif(MSVC)
    # Shipping builds embed bytecode; never fall back to compiling at startup silently.
    message(FATAL_ERROR "fxc not found: install the Windows SDK, or configure from a Visual Studio developer prompt")
  else()
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${KITE_THEME_HLSL}")
    file(READ "${KITE_THEME_HLSL}" KITE_THEME_SOURCE)
    # Written only when it changes, so a reconfigure doesn't rebuild Renderer.cpp.
    file(CONFIGURE OUTPUT "${KITE_SHADER_DIR}/ThemeHlsl.inc"
         CONTENT "// Generated from src/shell/shaders/Theme.hlsl by CMake. Don't edit.\nconstexpr char kThemeHlsl[] = R\"hlsl(@KITE_THEME_SOURCE@)hlsl\";\n" @ONLY)
    set(KITE_SHADER_HEADERS "${KITE_SHADER_DIR}/ThemeHlsl.inc")
  endif()

  set(KITE_SHELL_SOURCES
    src/shell/main.cpp
    src/shell/BackdropTest.cpp
    src/shell/BrowserWindowController.cpp
    src/shell/BrowserWindowController+Chromium.cpp
    src/shell/BrowserWindowController+Spaces.cpp
    src/shell/BrowserWindowController+Tests.cpp
    src/shell/BrowserWindowControllerArcImport.cpp
    src/shell/CaptionButtonsView.cpp
    src/shell/Capture.cpp
    src/shell/CommandBarView.cpp
    src/shell/Compositor.cpp
    src/shell/FadedLayer.cpp
    src/shell/Favicons.cpp
    src/shell/FavoritesView.cpp
    src/shell/FrameClock.cpp
    src/shell/Keys.cpp
    src/shell/MainWindow.cpp
    src/shell/MemoryPressure.cpp
    src/shell/PerfLog.cpp
    src/shell/QuietRun.cpp
    src/shell/RelayedTooltips.cpp
    src/shell/Renderer.cpp
    src/shell/SidebarTopRowView.cpp
    src/shell/SidebarView.cpp
    src/shell/SpaceBarView.cpp
    src/shell/SpaceIconPainter.cpp
    src/shell/SpaceMenu.cpp
    src/shell/SpaceRenameField.cpp
    src/shell/SpaceTipView.cpp
    src/shell/TextEditing.cpp
    src/shell/TextLine.cpp
    src/shell/TouchpadInput.cpp
    resources/Version.rc
    ${KITE_SHADER_HEADERS}
  )
  set(KITE_SHELL_LIBRARIES KiteCoreWin user32 dwmapi shell32 ole32 uuid windowscodecs d3d11 dcomp d2d1 dxguid dwrite imm32 winhttp comctl32)

  # Chromium (CEF), from windows/scripts/fetch-cef.ps1. Without it (no download yet, or the
  # MinGW check, which can't link CEF's MSVC wrapper) Kite.exe builds without pages.
  set(KITE_CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/ThirdParty/cef" CACHE PATH "CEF binary distribution (fetch-cef.ps1)")
  if(MSVC AND EXISTS "${KITE_CEF_ROOT}/include/cef_version.h")
    message(STATUS "Chromium: CEF at ${KITE_CEF_ROOT}")
    # Chromium's sandbox (docs/windows.md, "Chromium's sandbox"): Kite's code is Kite.dll, and
    # Kite.exe is CEF's bootstrap.exe stamped with Kite's manifest, version and stack. The
    # wrapper comes from fetch-cef.ps1's build-sandbox-cfg-* folders, built for
    # CEF_API_VERSION_LAST and with /guard:cf, as Kite.dll is here; other checkouts sharing this
    # CEF folder keep their own wrapper folders, which are left alone.
    set(KITE_CEF_WRAPPER_DIR "${KITE_CEF_ROOT}/build-sandbox-cfg-$<IF:$<CONFIG:Debug>,debug,release>/libcef_dll_wrapper")
    set(KITE_CEF_WRAPPER "${KITE_CEF_WRAPPER_DIR}/libcef_dll_wrapper.lib")
    if(NOT EXISTS "${KITE_CEF_ROOT}/build-sandbox-cfg-release/libcef_dll_wrapper/libcef_dll_wrapper.lib")
      message(FATAL_ERROR "No sandboxed CEF wrapper in ${KITE_CEF_ROOT}/build-sandbox-cfg-release: run windows/scripts/fetch-cef.ps1")
    endif()
    if(NOT EXISTS "${KITE_CEF_ROOT}/Release/bootstrap.exe")
      message(FATAL_ERROR "No bootstrap.exe in ${KITE_CEF_ROOT}/Release: Kite.exe is made from it")
    endif()
    # Kite.exe, Kite.dll and Chromium's runtime go in one folder with kitecore.exe; the import
    # libraries, the tests and the build tools go elsewhere, so the folder is what ships.
    set(KITE_OUT "${CMAKE_CURRENT_BINARY_DIR}/$<CONFIG>")
    set(KITE_TOOLS_OUT "${CMAKE_CURRENT_BINARY_DIR}/tools/$<CONFIG>")
    add_library(Kite SHARED ${KITE_SHELL_SOURCES} src/shell/Chromium.cpp src/shell/Sandbox.cpp)
    # KITE_VERSION_DLL: Version.rc describes Kite.dll.
    target_compile_definitions(Kite PRIVATE KITE_HAS_CEF CEF_API_VERSION=CEF_API_VERSION_LAST KITE_VERSION_DLL)
    target_include_directories(Kite SYSTEM PRIVATE "${KITE_CEF_ROOT}")
    # The minimal distribution has Release binaries only; libcef.dll's C ABI serves either
    # configuration. The C++ wrapper is built per configuration for the matching static CRT.
    target_link_libraries(Kite PRIVATE ${KITE_SHELL_LIBRARIES} "${KITE_CEF_ROOT}/Release/libcef.lib" "${KITE_CEF_WRAPPER}"
      comctl32 rpcrt4 shlwapi ws2_32 delayimp)
    # Every helper maps Kite.dll, renderers under win32k lockdown, where user32 (or anything that
    # loads it) fails the process: everything but kernel32 and libcef.dll is delay-loaded, so only
    # the browser process loads it. Control Flow Guard and CET shadow stacks, as Chromium's own
    # binaries have. tests/KiteBinariesTest.cmake checks all three. comctl32 is for Delete Space's
    # task dialog and the top row's tooltips (made on the first hover over a button), gdi32 for
    # --space-menu's read-back: only the window's process calls them (user32 loads gdi32 for
    # itself, so delaying Kite's import of it is safe: no call of Kite's to it comes before the
    # window, or from a loader callback).
    target_compile_options(Kite PRIVATE /guard:cf)
    target_link_options(Kite PRIVATE /guard:cf /CETCOMPAT
      /DELAYLOAD:user32.dll /DELAYLOAD:dwmapi.dll /DELAYLOAD:shell32.dll /DELAYLOAD:ole32.dll /DELAYLOAD:advapi32.dll
      /DELAYLOAD:d3d11.dll /DELAYLOAD:dcomp.dll /DELAYLOAD:d2d1.dll /DELAYLOAD:dwrite.dll /DELAYLOAD:imm32.dll /DELAYLOAD:winhttp.dll
      /DELAYLOAD:comctl32.dll /DELAYLOAD:gdi32.dll)
    set_target_properties(Kite PROPERTIES
      RUNTIME_OUTPUT_DIRECTORY "${KITE_OUT}"
      ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/lib/$<CONFIG>"
      VS_DEBUGGER_COMMAND "${KITE_OUT}/Kite.exe")

    # The build tools (windows/tools/build): the stamp, and the version Kite.exe gets
    # (Version.rc describing Kite.exe, in a resource-only module).
    add_executable(stamp-bootstrap tools/build/StampBootstrap.cpp)
    target_link_libraries(stamp-bootstrap PRIVATE version)
    add_library(kite-exe-version MODULE resources/Version.rc)
    set_target_properties(kite-exe-version PROPERTIES LINKER_LANGUAGE CXX)
    target_link_options(kite-exe-version PRIVATE /NOENTRY)
    set_target_properties(stamp-bootstrap kite-exe-version PROPERTIES
      RUNTIME_OUTPUT_DIRECTORY "${KITE_TOOLS_OUT}" LIBRARY_OUTPUT_DIRECTORY "${KITE_TOOLS_OUT}")

    # Kite.exe, made again only when one of its inputs changes. Chromium's runtime goes beside
    # it, where Chromium looks for it. The folder grants read and execute to ALL RESTRICTED
    # APPLICATION PACKAGES (S-1-15-2-2), as CEF's SET_LPAC_ACLS does, for helpers Chromium runs
    # as a less privileged AppContainer.
    set(KITE_MANIFEST "${CMAKE_CURRENT_SOURCE_DIR}/resources/Kite.manifest")
    # Kite's app icon, as Kite.exe's first icon group, which Explorer, the taskbar and Alt+Tab
    # show (never CEF's). resources/Kite.ico comes with #372; until it's in the tree Kite.exe has
    # no icon. The glob is checked again on every build (CONFIGURE_DEPENDS), so an icon that lands
    # or goes re-configures the build. An icon asked for by path (-DKITE_ICON) must exist.
    set(KITE_DEFAULT_ICON "${CMAKE_CURRENT_SOURCE_DIR}/resources/Kite.ico")
    file(GLOB KITE_ICONS_IN_TREE CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/resources/*.ico")
    set(KITE_ICON "${KITE_DEFAULT_ICON}" CACHE FILEPATH "The .ico stamped into Kite.exe")
    set(KITE_ICON_ARGUMENT)
    if(EXISTS "${KITE_ICON}")
      message(STATUS "Kite.exe's icon: ${KITE_ICON}")
      set(KITE_ICON_ARGUMENT "${KITE_ICON}")
    elseif(KITE_ICON STREQUAL KITE_DEFAULT_ICON)
      message(STATUS "Kite.exe's icon: none yet (no ${KITE_ICON})")
    else()
      message(FATAL_ERROR "KITE_ICON is ${KITE_ICON}, which doesn't exist")
    endif()
    # The stamp reads the icon's path from this file rather than its command line: Visual Studio
    # builds with the commands it loaded before a re-configure, so an icon that just landed (or
    # went) would otherwise be stamped with the old command. The file changes only when the path
    # does, which makes Kite.exe again.
    file(CONFIGURE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/kite-exe-icon.txt" CONTENT "${KITE_ICON_ARGUMENT}" @ONLY)
    add_custom_command(OUTPUT "${KITE_OUT}/Kite.exe"
      COMMAND ${CMAKE_COMMAND} -DCEF_ROOT=${KITE_CEF_ROOT} -DDEST=${KITE_OUT} -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/CopyCef.cmake
      COMMAND stamp-bootstrap "${KITE_CEF_ROOT}/Release/bootstrap.exe" "${KITE_OUT}/Kite.exe" "${KITE_MANIFEST}"
              "$<TARGET_FILE:kite-exe-version>" "@${CMAKE_CURRENT_BINARY_DIR}/kite-exe-icon.txt"
      COMMAND icacls "${KITE_OUT}" /grant "*S-1-15-2-2:(OI)(CI)(RX)" /q
      DEPENDS Kite stamp-bootstrap kite-exe-version "${KITE_CEF_ROOT}/Release/bootstrap.exe" "${KITE_MANIFEST}"
              "${CMAKE_CURRENT_BINARY_DIR}/kite-exe-icon.txt" ${KITE_ICON_ARGUMENT}
              ${CMAKE_CURRENT_SOURCE_DIR}/cmake/CopyCef.cmake
      COMMENT "Making Kite.exe from CEF's bootstrap"
      VERBATIM)
    add_custom_target(KiteExe ALL DEPENDS "${KITE_OUT}/Kite.exe")
    set(KITE_BOOTSTRAPPED ON)
  else()
    message(STATUS "Chromium: no CEF at ${KITE_CEF_ROOT}, building without pages")
    add_executable(Kite WIN32 ${KITE_SHELL_SOURCES})
    target_link_libraries(Kite PRIVATE ${KITE_SHELL_LIBRARIES})
    # Kite.manifest (MSVC; MinGW's comes through Kite.rc, below).
    if(MSVC)
      target_sources(Kite PRIVATE resources/Kite.manifest)
      target_compile_options(Kite PRIVATE /guard:cf)
      target_link_options(Kite PRIVATE /guard:cf /CETCOMPAT)
    else()
      target_link_options(Kite PRIVATE -municode)
    endif()
  endif()
  target_include_directories(Kite PRIVATE "${KITE_SHADER_DIR}")
  if(KITE_FXC)
    message(STATUS "Shaders: precompiled with ${KITE_FXC}")
  else()
    # Only without MSVC (an MSVC build stops above without fxc), so never in Kite.dll, whose
    # helpers would otherwise load d3dcompiler with it.
    message(STATUS "Shaders: no fxc, compiled at startup (KITE_RUNTIME_SHADERS)")
    target_compile_definitions(Kite PRIVATE KITE_RUNTIME_SHADERS)
    target_link_libraries(Kite PRIVATE d3dcompiler)
  endif()
  target_link_libraries(kitecore PRIVATE shell32)
  # Kite (Kite.dll with Chromium, else Kite.exe) and kitecore get Kite.rc, with the app icon:
  # LoadAppIcon loads it from the module MainWindow.cpp is in, and Explorer shows it for
  # kitecore.exe (the stamp puts it in the bootstrapped Kite.exe too). Kite.manifest: per-monitor
  # DPI v2, the UTF-8 code page, long paths, Common Controls 6 (the task dialog). MSVC's linker
  # embeds the manifest (kitecore's here, the no-Chromium Kite.exe's above, the stamp Kite.exe's);
  # MinGW's has no manifest tool, so Kite.rc carries it there.
  target_sources(Kite PRIVATE resources/Kite.rc)
  target_sources(kitecore PRIVATE resources/Kite.rc)
  set_property(SOURCE resources/Kite.rc APPEND PROPERTY OBJECT_DEPENDS
               "${CMAKE_CURRENT_SOURCE_DIR}/resources/Kite.ico" "${CMAKE_CURRENT_SOURCE_DIR}/resources/Kite.manifest")
  if(MSVC)
    target_sources(kitecore PRIVATE resources/Kite.manifest)
  else()
    set_property(SOURCE resources/Kite.rc APPEND PROPERTY COMPILE_DEFINITIONS KITE_RC_MANIFEST)
  endif()
endif()

# Measurement tools (docs/windows-architecture.md, windows/tools): never linked into Kite.exe,
# never shipped. MSVC only, as they're Windows-only and measure the MSVC build.
if(MSVC)
  add_executable(kiteperf tools/perf/main.cpp tools/perf/LogReader.cpp tools/perf/PageServer.cpp tools/perf/Processes.cpp
                          tools/perf/Report.cpp resources/Kite.manifest)
  # Its session fixture and pages, read from the source tree.
  target_compile_definitions(kiteperf PRIVATE KITEPERF_ASSETS="${CMAKE_CURRENT_SOURCE_DIR}/tools/perf")
  target_link_libraries(kiteperf PRIVATE KiteCoreWin pdh psapi ws2_32 advapi32 user32 gdi32 dwmapi)
  # Out of the folder that ships (windows/build/<config>), with the build tools.
  set_target_properties(kiteperf PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/tools/$<CONFIG>")
endif()

enable_testing()
add_executable(KiteCoreTests
  tests/main.cpp
  tests/ArcHistoryImportTests.cpp
  tests/ArcImportTests.cpp
  tests/ArcImportFilesTests.cpp
  tests/CommandBarTests.cpp
  tests/CommandLineTests.cpp
  tests/FavoritesTests.cpp
  tests/HistoryTests.cpp
  tests/JsonTests.cpp
  tests/KeyBindingsTests.cpp
  tests/ModelTests.cpp
  tests/LiveTabPolicyTests.cpp
  tests/SessionSaveTests.cpp
  tests/SidebarTests.cpp
  tests/SidebarTopRowTests.cpp
  tests/SpaceBarTests.cpp
  tests/SpaceEditingTests.cpp
  tests/SpaceIconTests.cpp
  tests/PictureLoadsTests.cpp
  tests/SpaceSwipeTests.cpp
  tests/SpaceSwipeGestureTests.cpp
  tests/TouchpadPhasesTests.cpp
  tests/SymbolShapeTests.cpp
  tests/TabClosingTests.cpp
  tests/SupportDirectoryTests.cpp
  tests/ThemeBackdropTests.cpp
  tests/ThemeTests.cpp
  tests/TitleBarTests.cpp
  tests/UnicodeTests.cpp
  tests/URLInputTests.cpp
  tests/WorkerThreadTests.cpp
)
target_link_libraries(KiteCoreTests PRIVATE KiteCoreWin)
if(NOT MSVC)
  # GCC 15's -Wmaybe-uninitialized misfires inside std::variant copies of the tests' nested
  # json::Value initializer lists (where it lands moves with inlining); the core keeps it.
  target_compile_options(KiteCoreTests PRIVATE -Wno-maybe-uninitialized)
endif()
# The hand-made Arc for Windows folder Import from Arc's tests read (scripts/make-web-data.py
# writes its Web Data, scripts/make-history.py its History files), at the place Arc's package
# keeps it under %LOCALAPPDATA%.
set(KITE_ARC_FIXTURE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/arc-windows/Packages/TheBrowserCompany.Arc_kitetest0001/LocalCache/Local/Arc")
# What history costs (tests/HistoryBench.cpp): its own executable, since it counts every
# allocation with its own operator new. CTest runs a small one so it keeps building and running.
add_executable(history-bench tests/HistoryBench.cpp)
target_link_libraries(history-bench PRIVATE KiteCoreWin)
if(WIN32)
  target_link_libraries(history-bench PRIVATE psapi)
endif()
if(MSVC)
  # Out of the folder that ships (windows/build/<config>), as the build tools are.
  set_target_properties(KiteCoreTests history-bench PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/tests/$<CONFIG>")
  set_target_properties(KiteCoreWin PROPERTIES ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/lib/$<CONFIG>")
endif()
# Writes Tests/Fixtures/theme-backdrop.json (see the file); not run by the tests.
add_executable(gen-theme-golden EXCLUDE_FROM_ALL tests/GenThemeGolden.cpp)
target_link_libraries(gen-theme-golden PRIVATE KiteCoreWin)
# The session fixture shared with the Mac test suite.
target_compile_definitions(KiteCoreTests PRIVATE KITE_FIXTURES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../Tests/Fixtures"
                                               KITE_STATES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/helix/states"
                                               KITE_TEST_FIXTURES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
                                               KITE_ARC_FIXTURE_DIR="${KITE_ARC_FIXTURE_DIR}")
add_test(NAME KiteCoreTests COMMAND KiteCoreTests)
add_test(NAME chromium-ignores-kites-command-line
  COMMAND ${CMAKE_COMMAND} -DSOURCE=${CMAKE_CURRENT_SOURCE_DIR}/src/shell/Chromium.cpp -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/ChromiumSettingsCheck.cmake)
add_test(NAME history-bench COMMAND history-bench 300)
add_test(NAME kitecore-cli
  COMMAND ${CMAKE_COMMAND} -DKITECORE=$<TARGET_FILE:kitecore> -DWORK=${CMAKE_CURRENT_BINARY_DIR}/kitecore-cli-test
          -DARC_LOCAL_APP_DATA=${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/arc-windows
          -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/KitecoreCliTest.cmake)
if(KITE_BOOTSTRAPPED)
  # Kite.dll's load-time imports, both binaries' CFG and CET, and Kite.exe's manifest, version
  # and stack (tests/KiteBinariesTest.cmake), read from what the KiteExe target made.
  add_test(NAME kite-binaries
    COMMAND ${CMAKE_COMMAND} -DLINKER=${CMAKE_LINKER} -DDLL=$<TARGET_FILE:Kite> -DEXE=${KITE_OUT}/Kite.exe
            -DBOOTSTRAP=${KITE_CEF_ROOT}/Release/bootstrap.exe -DSTAMP=$<TARGET_FILE:stamp-bootstrap> -DMANIFEST=${KITE_MANIFEST}
            -DWRAPPER=${KITE_CEF_WRAPPER}
            "-DICON=${KITE_ICON_ARGUMENT}"
            -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/KiteBinariesTest.cmake)
endif()
