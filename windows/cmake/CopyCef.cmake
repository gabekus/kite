# Copies CEF's runtime next to Kite.exe: Release\ (libcef.dll, chrome_elf.dll, the V8
# snapshot, ANGLE, SwiftShader) without its import libraries or its bootstrap (which is Kite.exe
# under Kite's name: tools/build/StampBootstrap.cpp), and Resources\ (icudtl.dat, the .pak files, locales\).
# Copies only what changed, so a rebuild is quick.
#   cmake -DCEF_ROOT=... -DDEST=... -P CopyCef.cmake
file(GLOB runtime LIST_DIRECTORIES false "${CEF_ROOT}/Release/*")
list(FILTER runtime EXCLUDE REGEX "\\.(lib|pdb)$")
# The bootstrap goes in as Kite.exe (tools/build/StampBootstrap.cpp); the console one isn't used.
list(FILTER runtime EXCLUDE REGEX "/bootstrapc?\\.exe$")
foreach(file IN LISTS runtime)
  file(COPY "${file}" DESTINATION "${DEST}")
endforeach()
file(COPY "${CEF_ROOT}/Resources/" DESTINATION "${DEST}")
# Left by builds from before they were excluded.
file(REMOVE "${DEST}/bootstrap.exe" "${DEST}/bootstrapc.exe")
