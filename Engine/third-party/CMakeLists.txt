cmake_minimum_required(VERSION 3.20)
if(POLICY CMP0177)
    cmake_policy(SET CMP0177 NEW)
endif()
project(guava-third-party LANGUAGES C CXX)

# Keep locally-built artifacts compatible with Engine/Package.swift. Recent
# Xcode toolchains otherwise stamp the host SDK (for example macOS 26) into
# objects when no deployment target is supplied.
if(APPLE)
    set(GUAVA_MACOS_DEPLOYMENT_TARGET "13.0" CACHE STRING
        "Minimum macOS version for Guava native artifacts")
    set(CMAKE_OSX_DEPLOYMENT_TARGET "${GUAVA_MACOS_DEPLOYMENT_TARGET}"
        CACHE STRING "" FORCE)
    set(GUAVA_PLATFORM_CMAKE_ARGS
        -DCMAKE_OSX_DEPLOYMENT_TARGET=${GUAVA_MACOS_DEPLOYMENT_TARGET})
else()
    set(GUAVA_PLATFORM_CMAKE_ARGS "")
endif()

include(${CMAKE_SOURCE_DIR}/../../cmake/ArtifactBundleManifest.cmake)

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

message(STATUS "Guava third-party target triple: ${GUAVA_TRIPLE} (SPM: ${GUAVA_SPM_TRIPLE})")

set(GUAVA_VENDOR_DIR ${CMAKE_SOURCE_DIR}/../vendor)

# ============================================================================
# Wasmtime Component runtime (fixed official dynamic C API artifact on macOS)
# ============================================================================
include(${CMAKE_SOURCE_DIR}/cmake/FetchWasmtime.cmake)

# ============================================================================
# Static-only, minimal-dependency build profile
# ============================================================================
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build static libraries" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON CACHE BOOL "" FORCE)

# ============================================================================
# wgpu-native (downloaded at configure time — Rust project, can't be source-built here)
# ============================================================================
include(${CMAKE_SOURCE_DIR}/cmake/FetchWgpu.cmake)

# ============================================================================
# SDL3
# ============================================================================
include(${CMAKE_SOURCE_DIR}/cmake/BuildSDL3.cmake)

# ============================================================================
# OpenEXR + Imath
# ============================================================================
include(${CMAKE_SOURCE_DIR}/cmake/BuildOpenEXRStack.cmake)

# ============================================================================
# Jolt Physics
# ============================================================================
include(${CMAKE_SOURCE_DIR}/cmake/BuildJolt.cmake)

# ============================================================================
# Unified image decoding dependencies (SVG/WebP)
# ============================================================================
include(${CMAKE_SOURCE_DIR}/cmake/BuildImageDecode.cmake)
