# Kite for Windows: native C++20 on Win32. See docs/windows.md.
#
#   cmake -S windows -B windows/build -A x64      (newest Visual Studio)
#   cmake --build windows/build --config Release
#   ctest --test-dir windows/build -C Release
cmake_minimum_required(VERSION 3.24)
project(Kite LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(MSVC)
  # Static CRT, matching CEF's libcef_dll_wrapper, so Kite.exe needs no VC++ redistributable.
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  add_compile_options(/W4 /WX /permissive- /utf-8 /Zc:__cplusplus)
else()
  add_compile_options(-Wall -Wextra -Werror)
endif()
add_compile_definitions(UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0A00)

# The model (the Windows counterpart of KiteCore): no UI, unit-tested headless.
add_library(KiteCoreWin STATIC
  src/core/Json.cpp
  src/core/Models.cpp
  src/core/SessionStore.cpp
  src/core/SupportDirectory.cpp
  src/core/URLInput.cpp
  src/core/Url.cpp
  src/core/Uuid.cpp
)
target_include_directories(KiteCoreWin PUBLIC src)

add_executable(Kite WIN32
  src/main.cpp
  src/shell/MainWindow.cpp
  src/shell/SystemAppearance.cpp
)
if(MSVC)
  # Per-monitor DPI v2, Windows 10+ behaviour, UTF-8 code page, long paths.
  target_sources(Kite PRIVATE src/shell/Kite.manifest)
endif()
target_link_libraries(Kite PRIVATE KiteCoreWin user32 dwmapi advapi32)
if(MINGW)
  target_link_options(Kite PRIVATE -municode)
endif()

# Headless model CLI (the behaviour gate in docs/helix.md).
add_executable(kitecore src/cli/main.cpp)
target_link_libraries(kitecore PRIVATE KiteCoreWin)
if(MSVC)
  target_sources(kitecore PRIVATE src/shell/Kite.manifest)  # UTF-8 argv
endif()

enable_testing()
add_executable(KiteCoreTests
  tests/main.cpp
  tests/JsonTests.cpp
  tests/ModelTests.cpp
  tests/SupportDirectoryTests.cpp
  tests/URLInputTests.cpp
)
target_link_libraries(KiteCoreTests PRIVATE KiteCoreWin)
# The session fixture shared with the Mac test suite.
target_compile_definitions(KiteCoreTests PRIVATE KITE_FIXTURES_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../Tests/Fixtures")
add_test(NAME KiteCoreTests COMMAND KiteCoreTests)
add_test(NAME kitecore-cli
  COMMAND ${CMAKE_COMMAND} -DKITECORE=$<TARGET_FILE:kitecore> -DWORK=${CMAKE_CURRENT_BINARY_DIR}/kitecore-cli-test
          -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/KitecoreCliTest.cmake)
