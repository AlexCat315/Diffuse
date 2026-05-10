# Downloads wgpu-native pre-built static library from gfx-rs/wgpu-native
# (Rust project, can't be source-built via SPM/CMake) and stages it into
# Engine/vendor/wgpu_native.artifactbundle/<triple>/.

set(WGPU_VERSION "v29.0.0.0")
set(WGPU_BUNDLE ${GUAVA_VENDOR_DIR}/wgpu_native.artifactbundle)
set(WGPU_VARIANT ${WGPU_BUNDLE}/${GUAVA_TRIPLE})

# Map triple to upstream archive filename
if(GUAVA_TRIPLE STREQUAL "macos-arm64")
    set(WGPU_ARCHIVE "wgpu-macos-aarch64-release.zip")
    set(WGPU_LIB "libwgpu_native.a")
elseif(GUAVA_TRIPLE STREQUAL "macos-x86_64")
    set(WGPU_ARCHIVE "wgpu-macos-x86_64-release.zip")
    set(WGPU_LIB "libwgpu_native.a")
elseif(GUAVA_TRIPLE STREQUAL "linux-x86_64")
    set(WGPU_ARCHIVE "wgpu-linux-x86_64-release.zip")
    set(WGPU_LIB "libwgpu_native.a")
elseif(GUAVA_TRIPLE STREQUAL "linux-aarch64")
    set(WGPU_ARCHIVE "wgpu-linux-aarch64-release.zip")
    set(WGPU_LIB "libwgpu_native.a")
elseif(GUAVA_TRIPLE STREQUAL "windows-x86_64")
    set(WGPU_ARCHIVE "wgpu-windows-x86_64-msvc-release.zip")
    set(WGPU_LIB "wgpu_native.lib")
else()
    message(FATAL_ERROR "Unsupported triple for wgpu-native: ${GUAVA_TRIPLE}")
endif()

set(WGPU_URL "https://github.com/gfx-rs/wgpu-native/releases/download/${WGPU_VERSION}/${WGPU_ARCHIVE}")
set(WGPU_DOWNLOAD_DIR ${CMAKE_BINARY_DIR}/wgpu-download)
set(WGPU_ZIP ${WGPU_DOWNLOAD_DIR}/${WGPU_ARCHIVE})

# Skip if already staged
if(NOT EXISTS ${WGPU_VARIANT}/lib/${WGPU_LIB})
    file(MAKE_DIRECTORY ${WGPU_DOWNLOAD_DIR})
    if(NOT EXISTS ${WGPU_ZIP})
        message(STATUS "Downloading wgpu-native ${WGPU_VERSION} for ${GUAVA_TRIPLE}")
        file(DOWNLOAD ${WGPU_URL} ${WGPU_ZIP}
            STATUS DL_STATUS
            SHOW_PROGRESS
        )
        list(GET DL_STATUS 0 DL_CODE)
        if(NOT DL_CODE EQUAL 0)
            message(FATAL_ERROR "wgpu-native download failed: ${DL_STATUS}")
        endif()
    endif()
    set(WGPU_EXTRACT_DIR ${CMAKE_BINARY_DIR}/wgpu-extract-${GUAVA_TRIPLE})
    file(REMOVE_RECURSE ${WGPU_EXTRACT_DIR})
    file(MAKE_DIRECTORY ${WGPU_EXTRACT_DIR})
    file(ARCHIVE_EXTRACT INPUT ${WGPU_ZIP} DESTINATION ${WGPU_EXTRACT_DIR})
    file(MAKE_DIRECTORY ${WGPU_VARIANT}/include/webgpu)
    file(MAKE_DIRECTORY ${WGPU_VARIANT}/lib)
    file(GLOB WGPU_HEADERS "${WGPU_EXTRACT_DIR}/include/webgpu/*.h")
    foreach(hdr ${WGPU_HEADERS})
        file(COPY ${hdr} DESTINATION ${WGPU_VARIANT}/include/webgpu)
    endforeach()
    file(COPY ${WGPU_EXTRACT_DIR}/lib/${WGPU_LIB} DESTINATION ${WGPU_VARIANT}/lib)
endif()

# Generate info.json (only contains the variant for the current platform)
file(WRITE ${WGPU_BUNDLE}/info.json "{
    \"schemaVersion\": \"1.0\",
    \"artifacts\": {
        \"wgpu_native\": {
            \"type\": \"staticLibrary\",
            \"version\": \"29.0.0.0\",
            \"variants\": [
                {
                    \"path\": \"${GUAVA_TRIPLE}/lib/${WGPU_LIB}\",
                    \"supportedTriples\": [\"${GUAVA_SPM_TRIPLE}\"],
                    \"staticLibraryMetadata\": {
                        \"headerPaths\": [\"${GUAVA_TRIPLE}/include\"]
                    }
                }
            ]
        }
    }
}
")

message(STATUS "wgpu-native ${WGPU_VERSION} ready at ${WGPU_VARIANT}")
