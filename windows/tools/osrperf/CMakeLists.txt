# osrperf: the W10 spike's measurement tool (docs/windows-osr-spike.md). Standalone, not part
# of Kite's build, never shipped.
#
#   cmake -S windows/tools/osrperf -B windows/tools/osrperf/build -A x64
#   cmake --build windows/tools/osrperf/build --config Release
cmake_minimum_required(VERSION 3.24)
project(osrperf LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_executable(osrperf osrperf.cpp)
target_compile_definitions(osrperf PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_compile_options(osrperf PRIVATE /W4 /permissive- /utf-8 /EHsc)
target_link_libraries(osrperf PRIVATE d3d11 dxgi pdh windowscodecs ole32 windowsapp dwmapi dcomp)
