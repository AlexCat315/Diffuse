cmake_minimum_required(VERSION 3.20)
if(POLICY CMP0177)
    cmake_policy(SET CMP0177 NEW)
endif()
project(guava-third-party LANGUAGES C CXX)

set(GUAVA_SDK_ROOT "$ENV{GUAVA_SDK_ROOT}" CACHE PATH "Guava SDK checkout")
if(NOT GUAVA_SDK_ROOT)
    set(GUAVA_SDK_ROOT "${CMAKE_SOURCE_DIR}/../../GuavaUI")
endif()
include("${GUAVA_SDK_ROOT}/cmake/NativePlatform.cmake")
include("${GUAVA_SDK_ROOT}/cmake/ArtifactBundleManifest.cmake")

message(STATUS "Guava third-party target triple: ${GUAVA_TRIPLE} (SPM: ${GUAVA_SPM_TRIPLE})")

set(GUAVA_VENDOR_DIR ${CMAKE_SOURCE_DIR}/../vendor CACHE PATH "Native artifact output directory")

# ============================================================================
# Wasmtime Component runtime (pinned static C API artifacts and iOS Pulley source build)
# ============================================================================
option(GUAVA_STAGE_WASMTIME "Stage the plugin runtime" ON)
if(GUAVA_STAGE_WASMTIME)
    include(${CMAKE_SOURCE_DIR}/cmake/FetchWasmtime.cmake)
endif()

# ============================================================================
# Static-only, minimal-dependency build profile
# ============================================================================
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build static libraries" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON CACHE BOOL "" FORCE)

# ============================================================================
# SDL3
# ============================================================================

# ============================================================================
# OpenEXR + Imath
# ============================================================================
option(GUAVA_BUILD_OPENEXR "Build the desktop EXR import/export stack" ON)
if(GUAVA_BUILD_OPENEXR)
    include(${CMAKE_SOURCE_DIR}/cmake/BuildOpenEXRStack.cmake)
endif()

# ============================================================================
# Jolt Physics
# ============================================================================
include(${CMAKE_SOURCE_DIR}/cmake/BuildJolt.cmake)

# ============================================================================
# Unified image decoding dependencies (SVG/WebP)
# ============================================================================
