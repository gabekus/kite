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
  src/core/Json.cpp
  src/core/Models.cpp
  src/core/OKLab.cpp
  src/core/SessionStore.cpp
  src/core/SupportDirectory.cpp
  src/core/ThemeBackdrop.cpp
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

  add_executable(Kite WIN32
    src/shell/main.cpp
    src/shell/BackdropTest.cpp
    src/shell/Capture.cpp
    src/shell/Compositor.cpp
    src/shell/MainWindow.cpp
    src/shell/Renderer.cpp
    ${KITE_SHADER_HEADERS}
  )
  target_include_directories(Kite PRIVATE "${KITE_SHADER_DIR}")
  target_link_libraries(Kite PRIVATE KiteCoreWin user32 dwmapi shell32 ole32 windowscodecs d3d11 dcomp)

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
      /DELAYLOAD:d3d11.dll /DELAYLOAD:dcomp.dll /DELAYLOAD:dwmapi.dll)
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
  tests/JsonTests.cpp
  tests/ModelTests.cpp
  tests/SupportDirectoryTests.cpp
  tests/ThemeBackdropTests.cpp
  tests/ThemeTests.cpp
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
