# Copies CEF's runtime next to Kite.exe: Release\ (libcef.dll, chrome_elf.dll, the V8
# snapshot, ANGLE, SwiftShader) without its import and sandbox libraries, and Resources\
# (icudtl.dat, the .pak files, locales\). Copies only what changed, so a rebuild is quick.
#   cmake -DCEF_ROOT=... -DDEST=... -P CopyCef.cmake
file(GLOB runtime LIST_DIRECTORIES false "${CEF_ROOT}/Release/*")
list(FILTER runtime EXCLUDE REGEX "\\.(lib|pdb)$")
foreach(file IN LISTS runtime)
  file(COPY "${file}" DESTINATION "${DEST}")
endforeach()
file(COPY "${CEF_ROOT}/Resources/" DESTINATION "${DEST}")
