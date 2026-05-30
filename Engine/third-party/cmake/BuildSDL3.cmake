# Builds SDL3 as a static library and installs into the SDL3.artifactbundle layout.
# Requires GUAVA_TRIPLE / GUAVA_SPM_TRIPLE / GUAVA_VENDOR_DIR set in parent scope.

# SDL3 build options — static, minimal
set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_TESTS OFF CACHE BOOL "" FORCE)
set(SDL_INSTALL OFF CACHE BOOL "" FORCE)
set(SDL_INSTALL_TESTS OFF CACHE BOOL "" FORCE)
set(SDL_DISABLE_INSTALL_DOCS ON CACHE BOOL "" FORCE)
set(SDL_DISABLE_INSTALL_CPACK ON CACHE BOOL "" FORCE)

if(WIN32)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL" CACHE STRING "" FORCE)
endif()

add_subdirectory(${CMAKE_SOURCE_DIR}/sdl3 sdl3-build EXCLUDE_FROM_ALL)

set(SDL3_BUNDLE ${GUAVA_VENDOR_DIR}/SDL3.artifactbundle)
set(SDL3_VARIANT ${SDL3_BUNDLE}/${GUAVA_TRIPLE})

# Install static archive
install(TARGETS SDL3-static
    ARCHIVE DESTINATION ${SDL3_VARIANT}/lib
    LIBRARY DESTINATION ${SDL3_VARIANT}/lib
    RUNTIME DESTINATION ${SDL3_VARIANT}/lib
)

# Install public headers (source tree)
install(DIRECTORY ${CMAKE_SOURCE_DIR}/sdl3/include/SDL3
    DESTINATION ${SDL3_VARIANT}/include
    FILES_MATCHING
    PATTERN "*.h"
)

# Install generated headers (SDL_build_config.h, etc.) — discovered after configure
install(CODE "
    file(GLOB_RECURSE SDL3_GENERATED
        \"${CMAKE_BINARY_DIR}/sdl3-build/include/build_config/SDL3/*.h\"
        \"${CMAKE_BINARY_DIR}/sdl3-build/include-config-*/build_config/SDL3/*.h\"
    )
    foreach(hdr \${SDL3_GENERATED})
        file(COPY \${hdr} DESTINATION ${SDL3_VARIANT}/include/SDL3)
    endforeach()
")

# Determine platform-specific static library filename
if(WIN32)
    set(SDL3_LIB_FILENAME "SDL3-static.lib")
else()
    set(SDL3_LIB_FILENAME "libSDL3.a")
endif()

# Generate info.json for the artifactbundle (at install time so it persists with binaries)
install(CODE "
    file(WRITE ${SDL3_BUNDLE}/info.json
\"{
  \\\"schemaVersion\\\": \\\"1.0\\\",
  \\\"artifacts\\\": {
    \\\"SDL3\\\": {
      \\\"type\\\": \\\"staticLibrary\\\",
      \\\"version\\\": \\\"3.4.8\\\",
      \\\"variants\\\": [
        {
          \\\"path\\\": \\\"${GUAVA_TRIPLE}/lib/${SDL3_LIB_FILENAME}\\\",
          \\\"supportedTriples\\\": [\\\"${GUAVA_SPM_TRIPLE}\\\"],
          \\\"staticLibraryMetadata\\\": {
            \\\"headerPaths\\\": [\\\"${GUAVA_TRIPLE}/include\\\"]
          }
        }
      ]
    }
  }
}
\")
")

# SDL3-static is EXCLUDE_FROM_ALL and lives in the `sdl3-build` subdirectory.
# The blanket `cmake --build` (bootstrap) skips EXCLUDE_FROM_ALL targets, and the
# Visual Studio generator cannot build a subdirectory target via
# `cmake --build --target SDL3-static` (it looks for SDL3-static.vcxproj in the
# build root → MSB1009). A top-level ALL custom target that depends on it fixes
# both: the default build pulls SDL3-static in, and `--target stage_sdl3`
# resolves at the build root on every generator (mirrors stage_jolt /
# stage_ocio_openexr). The install() rules above then copy it into the bundle.
add_custom_target(stage_sdl3 ALL COMMENT "Building SDL3-static")
add_dependencies(stage_sdl3 SDL3-static)
