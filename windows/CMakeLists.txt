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
  add_compile_options(-Wall -Wextra -Werror -ffp-contract=off)
endif()
if(WIN32)
  add_compile_definitions(UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0A00)
endif()

# The model (the Windows counterpart of KiteCore): standard C++ only, unit-tested headless.
add_library(KiteCoreWin STATIC
  src/core/CommandBar.cpp
  src/core/Json.cpp
  src/core/KeyBindings.cpp
  src/core/Models.cpp
  src/core/OKLab.cpp
  src/core/SessionStore.cpp
  src/core/SpaceBar.cpp
  src/core/SpaceIcon.cpp
  src/core/SymbolShape.cpp
  src/core/PictureLoads.cpp
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
    src/shell/CaptionButtonsView.cpp
    src/shell/Capture.cpp
    src/shell/CommandBarView.cpp
    src/shell/Compositor.cpp
    src/shell/Favicons.cpp
    src/shell/FrameClock.cpp
    src/shell/Keys.cpp
    src/shell/MainWindow.cpp
    src/shell/Renderer.cpp
    src/shell/SidebarView.cpp
    src/shell/SpaceBarView.cpp
    src/shell/SpaceIconPainter.cpp
    src/shell/SpaceTipView.cpp
    resources/Version.rc
    ${KITE_SHADER_HEADERS}
  )
  set(KITE_SHELL_LIBRARIES KiteCoreWin user32 dwmapi shell32 ole32 windowscodecs d3d11 dcomp d2d1 dxguid dwrite imm32 winhttp)

  # Chromium (CEF), from windows/scripts/fetch-cef.ps1. Without it (no download yet, or the
  # MinGW check, which can't link CEF's MSVC wrapper) Kite.exe builds without pages.
  set(KITE_CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/ThirdParty/cef" CACHE PATH "CEF binary distribution (fetch-cef.ps1)")
  if(MSVC AND EXISTS "${KITE_CEF_ROOT}/include/cef_version.h")
    message(STATUS "Chromium: CEF at ${KITE_CEF_ROOT}")
    # Chromium's sandbox (W6b): Kite.exe is CEF's bootstrap.exe, which enters the sandbox in
    # each helper before any of Kite's code runs and then calls RunWinMain in Kite.dll (main.cpp),
    # in the browser process too. The wrapper must be built for the bootstrap (USE_SANDBOX, which
    # pins it to CEF_API_VERSION_LAST, as Kite.dll is below), or the API hashes won't match.
    foreach(config release debug)
      set(cache "${KITE_CEF_ROOT}/build-${config}/CMakeCache.txt")
      if(EXISTS "${cache}")
        file(STRINGS "${cache}" sandbox REGEX "^USE_SANDBOX:BOOL=")
        file(STRINGS "${cache}" apiVersion REGEX "^api_version:")
        if(NOT sandbox STREQUAL "USE_SANDBOX:BOOL=ON" OR apiVersion)
          message(FATAL_ERROR "CEF's wrapper in ${KITE_CEF_ROOT}/build-${config} wasn't built for the sandbox: run windows/scripts/fetch-cef.ps1 again")
        endif()
      endif()
    endforeach()
    if(NOT EXISTS "${KITE_CEF_ROOT}/Release/bootstrap.exe")
      message(FATAL_ERROR "No bootstrap.exe in ${KITE_CEF_ROOT}/Release: Kite.exe is made from it")
    endif()
    add_library(Kite SHARED ${KITE_SHELL_SOURCES} src/shell/Chromium.cpp src/shell/Sandbox.cpp)
    target_compile_definitions(Kite PRIVATE KITE_HAS_CEF CEF_API_VERSION=CEF_API_VERSION_LAST)
    target_include_directories(Kite SYSTEM PRIVATE "${KITE_CEF_ROOT}")
    # The minimal distribution has Release binaries only; libcef.dll's C ABI serves either
    # configuration. The C++ wrapper is built per configuration for the matching static CRT.
    target_link_libraries(Kite PRIVATE ${KITE_SHELL_LIBRARIES}
      "${KITE_CEF_ROOT}/Release/libcef.lib"
      "${KITE_CEF_ROOT}/build-$<IF:$<CONFIG:Debug>,debug,release>/libcef_dll_wrapper/libcef_dll_wrapper.lib"
      comctl32 rpcrt4 shlwapi ws2_32 delayimp)
    # Every helper (renderer, GPU, utility) loads Kite.dll, renderers under win32k lockdown,
    # where loading user32.dll (or anything that loads it) fails the process. So everything but
    # kernel32 and libcef.dll is delay-loaded: only the browser process, which draws the window,
    # loads it, and each helper keeps less private memory. tests/KiteBinariesTest.cmake checks it.
    target_link_options(Kite PRIVATE
      /DELAYLOAD:user32.dll /DELAYLOAD:dwmapi.dll /DELAYLOAD:shell32.dll /DELAYLOAD:ole32.dll /DELAYLOAD:advapi32.dll
      /DELAYLOAD:d3d11.dll /DELAYLOAD:dcomp.dll /DELAYLOAD:d2d1.dll /DELAYLOAD:dwrite.dll /DELAYLOAD:imm32.dll /DELAYLOAD:winhttp.dll)
    set_target_properties(Kite PROPERTIES VS_DEBUGGER_COMMAND "$<TARGET_FILE_DIR:Kite>/Kite.exe")
    # Kite.exe: the bootstrap with Kite's manifest (per-monitor DPI v2, the UTF-8 code page,
    # long paths), version and stack (cmake/StampBootstrap.cpp).
    add_executable(stamp-bootstrap cmake/StampBootstrap.cpp)
    target_link_libraries(stamp-bootstrap PRIVATE imagehlp)
    add_dependencies(Kite stamp-bootstrap)
    # libcef.dll and its resources go next to Kite.exe, where Chromium looks for them. The
    # folder grants read and execute to ALL RESTRICTED APPLICATION PACKAGES (S-1-15-2-2), as
    # CEF's SET_LPAC_ACLS does: the helpers Chromium runs in a less privileged AppContainer
    # (LPAC) can't load Kite.dll or libcef.dll from it otherwise.
    add_custom_command(TARGET Kite POST_BUILD
      COMMAND ${CMAKE_COMMAND} -DCEF_ROOT=${KITE_CEF_ROOT} -DDEST=$<TARGET_FILE_DIR:Kite>
              -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/CopyCef.cmake
      COMMAND $<TARGET_FILE:stamp-bootstrap> "${KITE_CEF_ROOT}/Release/bootstrap.exe" "$<TARGET_FILE_DIR:Kite>/Kite.exe"
              "${CMAKE_CURRENT_SOURCE_DIR}/resources/Kite.manifest" "$<TARGET_FILE:Kite>"
      COMMAND icacls "$<TARGET_FILE_DIR:Kite>" /grant "*S-1-15-2-2:(OI)(CI)(RX)" /q
      VERBATIM)
    set(KITE_BOOTSTRAPPED ON)
  else()
    message(STATUS "Chromium: no CEF at ${KITE_CEF_ROOT}, building without pages")
    add_executable(Kite WIN32 ${KITE_SHELL_SOURCES})
    target_link_libraries(Kite PRIVATE ${KITE_SHELL_LIBRARIES})
    # Kite.manifest: per-monitor DPI v2, the UTF-8 code page, long paths.
    if(MSVC)
      target_sources(Kite PRIVATE resources/Kite.manifest)
    else()
      target_sources(Kite PRIVATE resources/Kite.rc)
      target_link_options(Kite PRIVATE -municode)
    endif()
  endif()
  target_include_directories(Kite PRIVATE "${KITE_SHADER_DIR}")
  if(KITE_FXC)
    message(STATUS "Shaders: precompiled with ${KITE_FXC}")
  else()
    message(STATUS "Shaders: no fxc, compiled at startup (KITE_RUNTIME_SHADERS)")
    target_compile_definitions(Kite PRIVATE KITE_RUNTIME_SHADERS)
    target_link_libraries(Kite PRIVATE d3dcompiler)
  endif()
  target_link_libraries(kitecore PRIVATE shell32)
  # kitecore gets Kite.manifest too, for the UTF-8 code page and long paths.
  if(MSVC)
    target_sources(kitecore PRIVATE resources/Kite.manifest)
  else()
    target_sources(kitecore PRIVATE resources/Kite.rc)
  endif()
endif()

enable_testing()
add_executable(KiteCoreTests
  tests/main.cpp
  tests/CommandBarTests.cpp
  tests/JsonTests.cpp
  tests/KeyBindingsTests.cpp
  tests/ModelTests.cpp
  tests/LiveTabPolicyTests.cpp
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
# Writes Tests/Fixtures/theme-backdrop.json (see the file); not run by the tests.
add_executable(gen-theme-golden EXCLUDE_FROM_ALL tests/GenThemeGolden.cpp)
target_link_libraries(gen-theme-golden PRIVATE KiteCoreWin)
# The session fixture shared with the Mac test suite.
target_compile_definitions(KiteCoreTests PRIVATE KITE_FIXTURES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../Tests/Fixtures"
                                               KITE_STATES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/helix/states")
add_test(NAME KiteCoreTests COMMAND KiteCoreTests)
add_test(NAME kitecore-cli
  COMMAND ${CMAKE_COMMAND} -DKITECORE=$<TARGET_FILE:kitecore> -DWORK=${CMAKE_CURRENT_BINARY_DIR}/kitecore-cli-test
          -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/KitecoreCliTest.cmake)
if(KITE_BOOTSTRAPPED)
  # Kite.dll's load-time imports and Kite.exe's make-up (tests/KiteBinariesTest.cmake).
  add_test(NAME kite-binaries
    COMMAND ${CMAKE_COMMAND} -DLINKER=${CMAKE_LINKER} -DDLL=$<TARGET_FILE:Kite> -DEXE=$<TARGET_FILE_DIR:Kite>/Kite.exe
            -DBOOTSTRAP=${KITE_CEF_ROOT}/Release/bootstrap.exe -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/KiteBinariesTest.cmake)
endif()
