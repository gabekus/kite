# Checks Kite.dll and Kite.exe as the Chromium build makes them (W6b, docs/windows.md):
# - Kite.dll imports only kernel32 and libcef.dll at load, the rest delay-loaded: every helper
#   loads it, renderers under win32k lockdown, where user32 (or anything that brings it in)
#   fails the process, and every other DLL is private memory in each helper;
# - Kite.exe is the bootstrap, importing what bootstrap.exe does and nothing of Kite's, with
#   the 8 MiB main-thread stack cmake/StampBootstrap.cpp gives it.
#   cmake -DLINKER=link.exe -DDLL=Kite.dll -DEXE=Kite.exe -DBOOTSTRAP=bootstrap.exe -P KiteBinariesTest.cmake

# The load-time imports `dump /dependents` lists, lowercased, without the delay-loaded ones.
function(load_time_imports binary out)
  execute_process(COMMAND "${LINKER}" /dump /nologo /dependents "${binary}" OUTPUT_VARIABLE text RESULT_VARIABLE code)
  if(NOT code EQUAL 0)
    message(FATAL_ERROR "link /dump /dependents ${binary} failed (${code})")
  endif()
  string(REPLACE "\r" "" text "${text}")
  string(REPLACE "\n" ";" lines "${text}")
  set(imports)
  set(reading OFF)
  foreach(line IN LISTS lines)
    string(STRIP "${line}" line)
    if(line STREQUAL "Image has the following dependencies:")
      set(reading ON)
    elseif(line MATCHES "^Image has the following delay load dependencies:" OR line STREQUAL "Summary")
      set(reading OFF)
    elseif(reading AND NOT line STREQUAL "")
      string(TOLOWER "${line}" line)
      list(APPEND imports "${line}")
    endif()
  endforeach()
  list(SORT imports)
  set(${out} "${imports}" PARENT_SCOPE)
endfunction()

load_time_imports("${DLL}" dll)
if(NOT dll STREQUAL "kernel32.dll;libcef.dll")
  message(FATAL_ERROR "Kite.dll loads ${dll} with it; everything but kernel32.dll and libcef.dll must be delay-loaded (windows/CMakeLists.txt)")
endif()

load_time_imports("${EXE}" exe)
load_time_imports("${BOOTSTRAP}" bootstrap)
if(NOT exe STREQUAL bootstrap)
  message(FATAL_ERROR "Kite.exe imports ${exe}, CEF's bootstrap.exe ${bootstrap}: Kite.exe isn't the bootstrap")
endif()

execute_process(COMMAND "${LINKER}" /dump /nologo /headers "${EXE}" OUTPUT_VARIABLE headers RESULT_VARIABLE code)
if(NOT code EQUAL 0 OR NOT headers MATCHES "[ \t]800000 size of stack reserve")
  message(FATAL_ERROR "Kite.exe doesn't reserve the 8 MiB main-thread stack (cmake/StampBootstrap.cpp)")
endif()
message(STATUS "Kite.dll loads ${dll}; Kite.exe is the bootstrap (${exe}) with an 8 MiB stack")
