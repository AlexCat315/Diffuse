cmake_minimum_required(VERSION 3.20)
project(guava-third-party LANGUAGES C CXX)

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
