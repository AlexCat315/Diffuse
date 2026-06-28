# Builds wgpu-native from a fixed upstream tag using Cargo release mode and
# stages it into Engine/vendor/wgpu_native.artifactbundle/<triple>/.

include(ExternalProject)

set(WGPU_VERSION "v29.0.0.0")
set(WGPU_TAG_OBJECT "e514ece6ea64af1dcfb7af37d7beeff0f8c5807b")
set(WGPU_TAG_COMMIT "d2e3330ade4ae1bb238d76b485926f067e7ee64c")
set(WGPU_REPOSITORY "https://github.com/gfx-rs/wgpu-native.git")
set(WGPU_BUNDLE ${GUAVA_VENDOR_DIR}/wgpu_native.artifactbundle)
set(WGPU_VARIANT ${WGPU_BUNDLE}/${GUAVA_TRIPLE})
set(WGPU_SOURCE_DIR ${CMAKE_BINARY_DIR}/wgpu-native-src)
set(WGPU_CARGO_TARGET_DIR ${CMAKE_BINARY_DIR}/wgpu-native-target)

find_program(CARGO_EXECUTABLE cargo REQUIRED)
find_program(RUSTC_EXECUTABLE rustc REQUIRED)

execute_process(
    COMMAND ${RUSTC_EXECUTABLE} --version
    OUTPUT_VARIABLE WGPU_RUSTC_VERSION
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
)
execute_process(
    COMMAND ${CARGO_EXECUTABLE} --version
    OUTPUT_VARIABLE WGPU_CARGO_VERSION
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
)

if(GUAVA_TRIPLE STREQUAL "macos-arm64")
    set(WGPU_RUST_TARGET "aarch64-apple-darwin")
    set(WGPU_LIB "libwgpu_native.a")
elseif(GUAVA_TRIPLE STREQUAL "macos-x86_64")
    set(WGPU_RUST_TARGET "x86_64-apple-darwin")
    set(WGPU_LIB "libwgpu_native.a")
elseif(GUAVA_TRIPLE STREQUAL "linux-x86_64")
    set(WGPU_RUST_TARGET "x86_64-unknown-linux-gnu")
    set(WGPU_LIB "libwgpu_native.a")
elseif(GUAVA_TRIPLE STREQUAL "linux-aarch64")
    set(WGPU_RUST_TARGET "aarch64-unknown-linux-gnu")
    set(WGPU_LIB "libwgpu_native.a")
elseif(GUAVA_TRIPLE STREQUAL "windows-x86_64")
    set(WGPU_RUST_TARGET "x86_64-pc-windows-msvc")
    set(WGPU_LIB "wgpu_native.lib")
else()
    message(FATAL_ERROR "Unsupported triple for wgpu-native: ${GUAVA_TRIPLE}")
endif()

set(WGPU_BUILD_LIB ${WGPU_CARGO_TARGET_DIR}/${WGPU_RUST_TARGET}/release/${WGPU_LIB})

ExternalProject_Add(wgpu_native_ep
    GIT_REPOSITORY ${WGPU_REPOSITORY}
    GIT_TAG ${WGPU_VERSION}
    GIT_SHALLOW TRUE
    GIT_SUBMODULES ffi/webgpu-headers
    GIT_SUBMODULES_RECURSE TRUE
    SOURCE_DIR ${WGPU_SOURCE_DIR}
    PREFIX ${CMAKE_BINARY_DIR}/wgpu-native-ep
    CONFIGURE_COMMAND ""
    PATCH_COMMAND
        ${CMAKE_COMMAND}
            -DREPO_DIR=${WGPU_SOURCE_DIR}
            -DEXPECTED_REF=${WGPU_VERSION}
            -DEXPECTED_REVISION=${WGPU_TAG_COMMIT}
            -P ${CMAKE_SOURCE_DIR}/../../cmake/VerifyGitRevision.cmake
    BUILD_COMMAND
        ${CMAKE_COMMAND} -E env
            CARGO_TARGET_DIR=${WGPU_CARGO_TARGET_DIR}
            ${CARGO_EXECUTABLE} build
                --manifest-path ${WGPU_SOURCE_DIR}/Cargo.toml
                --release
                --target ${WGPU_RUST_TARGET}
    BUILD_BYPRODUCTS ${WGPU_BUILD_LIB}
    INSTALL_COMMAND ""
)

add_custom_target(stage_wgpu_native ALL
    DEPENDS wgpu_native_ep
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${WGPU_VARIANT}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${WGPU_VARIANT}/lib
    COMMAND ${CMAKE_COMMAND} -E make_directory ${WGPU_VARIANT}/include/webgpu
    COMMAND ${CMAKE_COMMAND} -E make_directory ${WGPU_VARIANT}/wgpu-native-meta
    COMMAND ${CMAKE_COMMAND} -E copy
        ${WGPU_BUILD_LIB}
        ${WGPU_VARIANT}/lib/${WGPU_LIB}
    COMMAND ${CMAKE_COMMAND} -E copy
        ${WGPU_SOURCE_DIR}/ffi/webgpu-headers/webgpu.h
        ${WGPU_VARIANT}/include/webgpu/webgpu.h
    COMMAND ${CMAKE_COMMAND} -E copy
        ${WGPU_SOURCE_DIR}/ffi/wgpu.h
        ${WGPU_VARIANT}/include/webgpu/wgpu.h
    COMMAND ${CMAKE_COMMAND} -E copy
        ${WGPU_SOURCE_DIR}/ffi/webgpu-headers/webgpu.yml
        ${WGPU_VARIANT}/wgpu-native-meta/webgpu.yml
    COMMAND ${CMAKE_COMMAND}
        -DOUTPUT_FILE=${WGPU_VARIANT}/wgpu-native-meta/wgpu-native-git-tag
        -DOUTPUT_VALUE=${WGPU_VERSION}
        -P ${CMAKE_SOURCE_DIR}/../../cmake/WriteTextFile.cmake
    COMMENT "Building and staging wgpu-native ${WGPU_VERSION} into ${WGPU_VARIANT}"
    VERBATIM
)

add_dependencies(stage_wgpu_native wgpu_native_ep)

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

guava_add_artifact_build_manifest(
    ARTIFACT_NAME "wgpu_native"
    VERSION "29.0.0.0"
    BUNDLE_DIR ${WGPU_BUNDLE}
    LIB_REL_PATH "${GUAVA_TRIPLE}/lib/${WGPU_LIB}"
    BUILD_SYSTEM "Cargo"
    SOURCE_KIND "git"
    SOURCE_URL ${WGPU_REPOSITORY}
    SOURCE_REF ${WGPU_VERSION}
    SOURCE_REVISION ${WGPU_TAG_COMMIT}
    RUSTC ${WGPU_RUSTC_VERSION}
    CARGO ${WGPU_CARGO_VERSION}
    RUST_FLAGS "--release --target ${WGPU_RUST_TARGET}"
    NOTES "tagObject=${WGPU_TAG_OBJECT}, built locally from fixed upstream tag"
    DEPENDS stage_wgpu_native
)

message(STATUS "wgpu-native ${WGPU_VERSION} will be built locally for ${WGPU_RUST_TARGET}")
