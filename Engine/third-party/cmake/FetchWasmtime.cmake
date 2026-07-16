# Downloads the fixed official Wasmtime Component C API dynamic library and
# packages it as an XCFramework. A dynamic artifact keeps Wasmtime's Rust
# runtime out of the final static link, where it would otherwise collide with
# wgpu-native's independent Rust runtime.

if(NOT APPLE)
    message(STATUS "Embedded Wasmtime PluginHost is currently unavailable on this host (fail closed)")
    return()
endif()

set(WASMTIME_VERSION "45.0.0")
set(WASMTIME_RELEASE_BASE
    "https://github.com/bytecodealliance/wasmtime/releases/download/v${WASMTIME_VERSION}")

if(GUAVA_TRIPLE STREQUAL "macos-arm64")
    set(WASMTIME_PLATFORM "aarch64-macos")
    set(WASMTIME_ARCHITECTURE "arm64")
    set(WASMTIME_ARCHIVE_SHA256
        "43cd87ec7d398f2e799e81c7d4e143d930e0139953d3c5d2a9c4055789f29851")
elseif(GUAVA_TRIPLE STREQUAL "macos-x86_64")
    set(WASMTIME_PLATFORM "x86_64-macos")
    set(WASMTIME_ARCHITECTURE "x86_64")
    set(WASMTIME_ARCHIVE_SHA256
        "92d6b32a31711127fde10acbf5b984fa37b94052cec783a4fca6edd0bb8cdd6f")
else()
    message(FATAL_ERROR "Unsupported Apple triple for Wasmtime: ${GUAVA_TRIPLE}")
endif()

find_program(XCODEBUILD_EXECUTABLE xcodebuild REQUIRED)

set(WASMTIME_ARCHIVE_NAME
    "wasmtime-v${WASMTIME_VERSION}-${WASMTIME_PLATFORM}-c-api.tar.xz")
set(WASMTIME_ARCHIVE_URL
    "${WASMTIME_RELEASE_BASE}/${WASMTIME_ARCHIVE_NAME}")
set(WASMTIME_DOWNLOAD_DIR "${CMAKE_BINARY_DIR}/wasmtime-download")
set(WASMTIME_ARCHIVE "${WASMTIME_DOWNLOAD_DIR}/${WASMTIME_ARCHIVE_NAME}")
set(WASMTIME_EXTRACT_DIR "${CMAKE_BINARY_DIR}/wasmtime-c-api")
set(WASMTIME_SOURCE_DIR
    "${WASMTIME_EXTRACT_DIR}/wasmtime-v${WASMTIME_VERSION}-${WASMTIME_PLATFORM}-c-api")

file(MAKE_DIRECTORY "${WASMTIME_DOWNLOAD_DIR}")
file(DOWNLOAD
    "${WASMTIME_ARCHIVE_URL}"
    "${WASMTIME_ARCHIVE}"
    EXPECTED_HASH "SHA256=${WASMTIME_ARCHIVE_SHA256}"
    TLS_VERIFY ON
    SHOW_PROGRESS
    STATUS WASMTIME_DOWNLOAD_STATUS
)
list(GET WASMTIME_DOWNLOAD_STATUS 0 WASMTIME_DOWNLOAD_RESULT)
list(GET WASMTIME_DOWNLOAD_STATUS 1 WASMTIME_DOWNLOAD_MESSAGE)
if(NOT WASMTIME_DOWNLOAD_RESULT EQUAL 0)
    message(FATAL_ERROR "Wasmtime download failed: ${WASMTIME_DOWNLOAD_MESSAGE}")
endif()

file(REMOVE_RECURSE "${WASMTIME_EXTRACT_DIR}")
file(MAKE_DIRECTORY "${WASMTIME_EXTRACT_DIR}")
execute_process(
    COMMAND ${CMAKE_COMMAND} -E tar xf "${WASMTIME_ARCHIVE}"
    WORKING_DIRECTORY "${WASMTIME_EXTRACT_DIR}"
    RESULT_VARIABLE WASMTIME_EXTRACT_RESULT
)
if(NOT WASMTIME_EXTRACT_RESULT EQUAL 0
   OR NOT EXISTS "${WASMTIME_SOURCE_DIR}/lib/libwasmtime.dylib"
   OR NOT EXISTS "${WASMTIME_SOURCE_DIR}/include/wasmtime.h")
    message(FATAL_ERROR "Official Wasmtime C API archive has an unexpected layout")
endif()

set(WASMTIME_XCFRAMEWORK "${GUAVA_VENDOR_DIR}/Wasmtime.xcframework")
set(WASMTIME_DYLIB
    "${WASMTIME_XCFRAMEWORK}/macos-${WASMTIME_ARCHITECTURE}/libwasmtime.dylib")
set(WASMTIME_MANIFEST "${GUAVA_VENDOR_DIR}/Wasmtime-build-manifest.json")
set(WASMTIME_LICENSE "${GUAVA_VENDOR_DIR}/Wasmtime-LICENSE")

add_custom_target(stage_wasmtime ALL
    BYPRODUCTS
        "${WASMTIME_XCFRAMEWORK}/Info.plist"
        "${WASMTIME_DYLIB}"
        "${WASMTIME_MANIFEST}"
        "${WASMTIME_LICENSE}"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${WASMTIME_XCFRAMEWORK}"
    COMMAND ${XCODEBUILD_EXECUTABLE} -create-xcframework
        -library "${WASMTIME_SOURCE_DIR}/lib/libwasmtime.dylib"
        -headers "${WASMTIME_SOURCE_DIR}/include"
        -output "${WASMTIME_XCFRAMEWORK}"
    COMMAND ${CMAKE_COMMAND} -E copy
        "${WASMTIME_SOURCE_DIR}/LICENSE"
        "${WASMTIME_LICENSE}"
    COMMAND ${CMAKE_COMMAND}
        -DOUTPUT_FILE=${WASMTIME_MANIFEST}
        -DLIBRARY_FILE=${WASMTIME_DYLIB}
        -DVERSION=${WASMTIME_VERSION}
        -DARCHITECTURE=${WASMTIME_ARCHITECTURE}
        -DARCHIVE_URL=${WASMTIME_ARCHIVE_URL}
        -DARCHIVE_SHA256=${WASMTIME_ARCHIVE_SHA256}
        -P "${CMAKE_CURRENT_LIST_DIR}/WriteWasmtimeManifest.cmake"
    COMMENT "Staging pinned Wasmtime ${WASMTIME_VERSION} Component runtime"
    VERBATIM
)

message(STATUS
    "Wasmtime ${WASMTIME_VERSION} official C API archive verified for ${WASMTIME_PLATFORM}")
