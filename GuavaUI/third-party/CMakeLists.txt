cmake_minimum_required(VERSION 3.20)
project(guavaui-third-party LANGUAGES C CXX)

# ============================================================================
# Determine target triple for SPM artifact bundle layout
# ============================================================================
if(APPLE)
    if(CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64" OR CMAKE_OSX_ARCHITECTURES MATCHES "arm64")
        set(GUAVA_TRIPLE "macos-arm64")
        set(GUAVA_SPM_TRIPLE "arm64-apple-macosx")
    else()
        set(GUAVA_TRIPLE "macos-x86_64")
        set(GUAVA_SPM_TRIPLE "x86_64-apple-macosx")
    endif()
elseif(WIN32)
    set(GUAVA_TRIPLE "windows-x86_64")
    set(GUAVA_SPM_TRIPLE "x86_64-unknown-windows-msvc")
elseif(UNIX)
    if(CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64" OR CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64")
        set(GUAVA_TRIPLE "linux-aarch64")
        set(GUAVA_SPM_TRIPLE "aarch64-unknown-linux-gnu")
    else()
        set(GUAVA_TRIPLE "linux-x86_64")
        set(GUAVA_SPM_TRIPLE "x86_64-unknown-linux-gnu")
    endif()
endif()

message(STATUS "GuavaUI third-party target triple: ${GUAVA_TRIPLE} (SPM: ${GUAVA_SPM_TRIPLE})")

set(GUAVA_VENDOR_DIR ${CMAKE_SOURCE_DIR}/../vendor)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build static libraries" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON CACHE BOOL "" FORCE)

# Helper: emit info.json for a single-variant staticLibrary artifact bundle
function(write_artifactbundle_info BUNDLE_DIR ARTIFACT_NAME LIB_REL_PATH)
    install(CODE "
        file(WRITE ${BUNDLE_DIR}/info.json
\"{
  \\\"schemaVersion\\\": \\\"1.0\\\",
  \\\"artifacts\\\": {
    \\\"${ARTIFACT_NAME}\\\": {
      \\\"type\\\": \\\"staticLibrary\\\",
      \\\"version\\\": \\\"1.0.0\\\",
      \\\"variants\\\": [
        {
          \\\"path\\\": \\\"${LIB_REL_PATH}\\\",
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
endfunction()

include(${CMAKE_SOURCE_DIR}/cmake/BuildFreeType.cmake)
include(${CMAKE_SOURCE_DIR}/cmake/BuildHarfBuzz.cmake)
