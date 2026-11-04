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
if(MINGW)
  enable_language(RC)
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
  src/core/ArcImport.cpp
  src/core/ArcImportController.cpp
  src/core/ArcImportFiles.cpp
  src/core/CommandBar.cpp
  src/core/Files.cpp
  src/core/History.cpp
  src/core/HistoryStore.cpp
  src/core/Json.cpp
  src/core/KeyBindings.cpp
  src/core/Models.cpp
  src/core/OKLab.cpp
  src/core/SessionBackups.cpp
  src/core/SessionSaveDelay.cpp
  src/core/SessionStore.cpp
  src/core/SessionWriter.cpp
  src/core/StoreFile.cpp
  src/core/SpaceBar.cpp
  src/core/SpaceIcon.cpp
  src/core/SymbolShape.cpp
  src/core/TextMatch.cpp
  src/core/PictureLoads.cpp
  src/core/Plist.cpp
  src/core/Profiles.cpp
  src/core/SiteSearch.cpp
  src/core/SQLiteReader.cpp
  src/core/SpaceSwipe.cpp
  src/core/LiveTabPolicy.cpp
  src/core/Sidebar.cpp
  src/core/TabClosing.cpp
  src/core/SupportDirectory.cpp
  src/core/ThemeBackdrop.cpp
  src/core/TitleBar.cpp
  src/core/Unicode.cpp
  src/core/URLInput.cpp
  src/core/Url.cpp
  src/core/Uuid.cpp
)
target_include_directories(KiteCoreWin PUBLIC src)
# SessionWriter's worker is a std::thread (pthreads off Windows).
find_package(Threads REQUIRED)
target_link_libraries(KiteCoreWin PUBLIC Threads::Threads)

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

  add_executable(Kite WIN32
    src/shell/main.cpp
    src/shell/BackdropTest.cpp
    src/shell/BrowserWindowController.cpp
    src/shell/BrowserWindowControllerArcImport.cpp
    src/shell/CaptionButtonsView.cpp
    src/shell/Capture.cpp
    src/shell/CommandBarView.cpp
    src/shell/Compositor.cpp
    src/shell/Favicons.cpp
    src/shell/FrameClock.cpp
    src/shell/Keys.cpp
    src/shell/MainWindow.cpp
    src/shell/MemoryPressure.cpp
    src/shell/Renderer.cpp
    src/shell/SidebarView.cpp
    src/shell/SpaceBarView.cpp
    src/shell/SpaceIconPainter.cpp
    src/shell/SpaceTipView.cpp
    ${KITE_SHADER_HEADERS}
  )
  target_include_directories(Kite PRIVATE "${KITE_SHADER_DIR}")
  target_link_libraries(Kite PRIVATE KiteCoreWin user32 dwmapi shell32 ole32 uuid windowscodecs d3d11 dcomp d2d1 dxguid dwrite imm32 winhttp)

  # Chromium (CEF), from windows/scripts/fetch-cef.ps1. Without it (no download yet, or the
  # MinGW check, which can't link CEF's MSVC wrapper) Kite.exe builds without pages.
  set(KITE_CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/ThirdParty/cef" CACHE PATH "CEF binary distribution (fetch-cef.ps1)")
  if(MSVC AND EXISTS "${KITE_CEF_ROOT}/include/cef_version.h")
    message(STATUS "Chromium: CEF at ${KITE_CEF_ROOT}")
    target_sources(Kite PRIVATE src/shell/Chromium.cpp)
    target_compile_definitions(Kite PRIVATE KITE_HAS_CEF)
    target_include_directories(Kite SYSTEM PRIVATE "${KITE_CEF_ROOT}")
    # The minimal distribution has Release binaries only; libcef.dll's C ABI serves either
    # configuration. The C++ wrapper is built per configuration for the matching static CRT.
    target_link_libraries(Kite PRIVATE
      "${KITE_CEF_ROOT}/Release/libcef.lib"
      "${KITE_CEF_ROOT}/build-$<IF:$<CONFIG:Debug>,debug,release>/libcef_dll_wrapper/libcef_dll_wrapper.lib"
      comctl32 rpcrt4 shlwapi ws2_32 delayimp)
    # Kite.exe is also Chromium's renderer, GPU and utility process. Like chrome.exe (and
    # CEF's own CEF_EXE_LINKER_FLAGS) it gets an 8 MiB main-thread stack, which deep pages
    # need, and loads the window's graphics DLLs only in the process that draws the window.
    target_link_options(Kite PRIVATE /STACK:0x800000
      /DELAYLOAD:d3d11.dll /DELAYLOAD:dcomp.dll /DELAYLOAD:dwmapi.dll /DELAYLOAD:d2d1.dll /DELAYLOAD:dwrite.dll /DELAYLOAD:imm32.dll /DELAYLOAD:winhttp.dll)
    # libcef.dll and its resources go next to Kite.exe, where Chromium looks for them.
    add_custom_command(TARGET Kite POST_BUILD
      COMMAND ${CMAKE_COMMAND} -DCEF_ROOT=${KITE_CEF_ROOT} -DDEST=$<TARGET_FILE_DIR:Kite>
              -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/CopyCef.cmake
      VERBATIM)
  else()
    message(STATUS "Chromium: no CEF at ${KITE_CEF_ROOT}, building without pages")
  endif()
  if(KITE_FXC)
    message(STATUS "Shaders: precompiled with ${KITE_FXC}")
  else()
    message(STATUS "Shaders: no fxc, compiled at startup (KITE_RUNTIME_SHADERS)")
    target_compile_definitions(Kite PRIVATE KITE_RUNTIME_SHADERS)
    target_link_libraries(Kite PRIVATE d3dcompiler)
  endif()
  target_link_libraries(kitecore PRIVATE shell32)
  # Both get Kite.manifest: per-monitor DPI v2, the UTF-8 code page, long paths.
  if(MSVC)
    target_sources(Kite PRIVATE resources/Kite.manifest)
    target_sources(kitecore PRIVATE resources/Kite.manifest)
  else()
    target_sources(Kite PRIVATE resources/Kite.rc)
    target_sources(kitecore PRIVATE resources/Kite.rc)
    target_link_options(Kite PRIVATE -municode)
  endif()
endif()

enable_testing()
add_executable(KiteCoreTests
  tests/main.cpp
  tests/ArcImportTests.cpp
  tests/ArcImportFilesTests.cpp
  tests/CommandBarTests.cpp
  tests/HistoryTests.cpp
  tests/JsonTests.cpp
  tests/KeyBindingsTests.cpp
  tests/ModelTests.cpp
  tests/LiveTabPolicyTests.cpp
  tests/SessionSaveTests.cpp
  tests/SidebarTests.cpp
  tests/SpaceBarTests.cpp
  tests/SpaceIconTests.cpp
  tests/PictureLoadsTests.cpp
  tests/SpaceSwipeTests.cpp
  tests/SymbolShapeTests.cpp
  tests/TabClosingTests.cpp
  tests/SupportDirectoryTests.cpp
  tests/ThemeBackdropTests.cpp
  tests/ThemeTests.cpp
  tests/TitleBarTests.cpp
  tests/UnicodeTests.cpp
  tests/URLInputTests.cpp
)
target_link_libraries(KiteCoreTests PRIVATE KiteCoreWin)
if(NOT MSVC)
  # GCC 15's -Wmaybe-uninitialized misfires inside std::variant copies of the tests' nested
  # json::Value initializer lists (where it lands moves with inlining); the core keeps it.
  target_compile_options(KiteCoreTests PRIVATE -Wno-maybe-uninitialized)
endif()
# The hand-made Arc for Windows folder Import from Arc's tests read (scripts/make-web-data.py
# writes its Web Data), at the place Arc's package keeps it under %LOCALAPPDATA%.
set(KITE_ARC_FIXTURE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/arc-windows/Packages/TheBrowserCompany.Arc_kitetest0001/LocalCache/Local/Arc")
# Writes Tests/Fixtures/theme-backdrop.json (see the file); not run by the tests.
add_executable(gen-theme-golden EXCLUDE_FROM_ALL tests/GenThemeGolden.cpp)
target_link_libraries(gen-theme-golden PRIVATE KiteCoreWin)
# The session fixture shared with the Mac test suite.
target_compile_definitions(KiteCoreTests PRIVATE KITE_FIXTURES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../Tests/Fixtures"
                                               KITE_STATES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/helix/states"
                                               KITE_TEST_FIXTURES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures"
                                               KITE_ARC_FIXTURE_DIR="${KITE_ARC_FIXTURE_DIR}")
add_test(NAME KiteCoreTests COMMAND KiteCoreTests)
add_test(NAME kitecore-cli
  COMMAND ${CMAKE_COMMAND} -DKITECORE=$<TARGET_FILE:kitecore> -DWORK=${CMAKE_CURRENT_BINARY_DIR}/kitecore-cli-test
          -DARC_LOCAL_APP_DATA=${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/arc-windows
          -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/KitecoreCliTest.cmake)
