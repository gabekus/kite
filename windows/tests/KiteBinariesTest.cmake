# Checks Kite.dll and Kite.exe as the Chromium build makes them (docs/windows.md, "Chromium's
# sandbox"):
# - Kite.dll imports only kernel32 and libcef.dll at load, the rest delay-loaded (renderers map
#   it under win32k lockdown, where user32 fails the process);
# - Kite.exe is the bootstrap, importing exactly what bootstrap.exe does;
# - both have Control Flow Guard and are CET compatible (they're mapped into every sandboxed
#   helper), and so was every object of CEF's wrapper linked into Kite.dll compiled (the linker
#   marks the DLL as guarded either way, so the DLL's headers can't tell);
# - Kite.exe carries Kite's manifest, version, icon (ICON, when the build has one) and 8 MiB
#   stack (stamp-bootstrap --check).
#   cmake -DLINKER=link.exe -DDLL=Kite.dll -DEXE=Kite.exe -DBOOTSTRAP=bootstrap.exe
#         -DSTAMP=stamp-bootstrap.exe -DMANIFEST=Kite.manifest -DWRAPPER=libcef_dll_wrapper.lib
#         [-DICON=Kite.ico] -P KiteBinariesTest.cmake

foreach(file IN ITEMS "${DLL}" "${EXE}")
  if(NOT EXISTS "${file}")
    message(FATAL_ERROR "${file} isn't there: build the KiteExe target")
  endif()
endforeach()

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

# Control Flow Guard (a DLL characteristic) and CET compatibility (an extended one).
function(check_hardening binary name)
  execute_process(COMMAND "${LINKER}" /dump /nologo /headers "${binary}" OUTPUT_VARIABLE headers RESULT_VARIABLE code)
  if(NOT code EQUAL 0)
    message(FATAL_ERROR "link /dump /headers ${binary} failed (${code})")
  endif()
  if(NOT headers MATCHES "Control Flow Guard")
    message(FATAL_ERROR "${name} has no Control Flow Guard (/guard:cf)")
  endif()
  if(NOT headers MATCHES "CET compatible")
    message(FATAL_ERROR "${name} isn't CET compatible (/CETCOMPAT)")
  endif()
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
check_hardening("${DLL}" Kite.dll)
check_hardening("${EXE}" Kite.exe)

# Every object in the wrapper was compiled with /guard:cf: its @feat.00 symbol has bit 0x800
# (and the objects have .gfids$y sections, the guarded functions' table).
execute_process(COMMAND "${LINKER}" /dump /nologo /symbols "${WRAPPER}" OUTPUT_VARIABLE symbols RESULT_VARIABLE code)
if(NOT code EQUAL 0)
  message(FATAL_ERROR "link /dump /symbols ${WRAPPER} failed (${code})")
endif()
string(REGEX MATCHALL "[ \t]([0-9A-Fa-f]+) ABS[^\n]*@feat\.00" features "${symbols}")
set(objects 0)
set(unguarded 0)
foreach(feature IN LISTS features)
  string(REGEX REPLACE "^[ \t]([0-9A-Fa-f]+) .*" "\\1" value "${feature}")
  math(EXPR guarded "0x${value} & 0x800")
  math(EXPR objects "${objects} + 1")
  if(guarded EQUAL 0)
    math(EXPR unguarded "${unguarded} + 1")
  endif()
endforeach()
if(objects EQUAL 0)
  message(FATAL_ERROR "found no objects in ${WRAPPER}")
endif()
if(NOT unguarded EQUAL 0)
  message(FATAL_ERROR "${unguarded} of the wrapper's ${objects} objects weren't compiled with /guard:cf (fetch-cef.ps1)")
endif()
execute_process(COMMAND "${LINKER}" /dump /nologo /headers "${WRAPPER}" OUTPUT_VARIABLE wrapperHeaders)
if(NOT wrapperHeaders MATCHES "\\.gfids")
  message(FATAL_ERROR "${WRAPPER} has no .gfids sections: it wasn't built with /guard:cf")
endif()

execute_process(COMMAND "${STAMP}" --check "${EXE}" "${MANIFEST}" ${ICON} ERROR_VARIABLE problems RESULT_VARIABLE code)
if(NOT code EQUAL 0)
  message(FATAL_ERROR "Kite.exe isn't stamped as Kite: ${problems}")
endif()
message(STATUS "Kite.dll loads ${dll}; Kite.exe is the bootstrap (${exe}), stamped (icon: ${ICON}); both have CFG and CET; all ${objects} wrapper objects are guarded")
