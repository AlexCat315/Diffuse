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
          \\\"path\\\": \\\"${GUAVA_TRIPLE}/lib/libSDL3.a\\\",
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
